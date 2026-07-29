#!/usr/bin/env python3
"""Nose Guard daemon — webcam nose-touch detector (AVFoundation + Apple Vision).

Runs headless (no window). When a fingertip rests on the nose zone for
HOLD_S seconds it fires the Hammerspoon urlevent `hammerspoon://noseguard`,
which draws the disruptive overlay + alarm. Detection keeps running regardless
of which app is focused — that's the whole point vs the browser version.

Capture: a native AVCaptureSession driven at ~5 fps (activeVideoMinFrameDuration),
delivering CVPixelBuffers straight to Vision — no OpenCV, no per-frame colour
convert or byte copy. Detection: VNDetectFaceLandmarksRequest +
VNDetectHumanHandPoseRequest run on the GPU + Neural Engine. This keeps CPU low:
the camera physically runs at 5 fps instead of OpenCV's fixed 30 fps decode.
(MediaPipe's Metal GPU delegate aborts on macOS — see project_noseguard_gpu_crash.)

What counts as a touch (see nose_geom.py for the geometry):
  * only the *nose* landmarks are targets — lips, chin and the face median line
    used to be in the zone too, which is why eating and stroking a beard fired
  * the contact radius scales with your interpupillary distance, not with the
    frame, so leaning back no longer stretches the zone across half your face
  * contact has to hold still relative to the nose for several frames; a hand
    crossing the nose on its way somewhere else clips the zone but never rests
  * a hand whose apparent palm dwarfs your IPD is up against the lens, not your
    face, and is dropped (a coarse ceiling only — see nose_geom.PALM_RATIO_MAX
    for why measurement ruled out a real depth test)
  * only the largest face in frame is used (a face on a monitor behind you was
    contributing landmarks)

Env knobs (set by the Hammerspoon launcher, all optional):
  NG_SENS      0..100  contact radius, as a fraction of your IPD (default 55
               ≈ 17 mm of slack around the nose outline)
  NG_HOLD      seconds contact must persist before alerting     (default 0.5)
  NG_FRAMES    consecutive contact frames required              (default 3)
  NG_MAX_SPEED max fingertip drift vs the nose, IPD/s           (default 3.0)
  NG_HAND_HI   max apparent palm/IPD ratio (hand at the lens)   (default 4.0)
  NG_MIN_CONF  min fingertip confidence                         (default 0.3)
  NG_PALM_CONF min palm-joint confidence, for the depth cue     (default 0.2)
  NG_DEBUG     1 → log per-second distance/ratio/speed diagnostics
  NG_CAM       camera index (fallback only)                     (default 0)
  NG_CAM_ID    AVFoundation uniqueID — stable, preferred over NG_CAM
  NG_FPS       capture frames per second                        (default 5)

Run `python noseguard.py list` to print discovered cameras as JSON
(uniqueID, name, builtin, connected) — used by the Hammerspoon menu so the
menu and the daemon share one device list (index drift breaks otherwise, e.g.
the iPhone Continuity Camera appearing/disappearing).
"""
import os
import time
import subprocess
import sys

import objc
import AVFoundation as AV
import CoreMedia
import Quartz
import Vision
import Foundation
import libdispatch

import nose_geom as ng

SENS = float(os.environ.get("NG_SENS", "55"))
HOLD_S = float(os.environ.get("NG_HOLD", "0.5"))
FRAMES = int(os.environ.get("NG_FRAMES", "3"))
MAX_SPEED = float(os.environ.get("NG_MAX_SPEED", str(ng.MAX_SPEED)))
HAND_HI = float(os.environ.get("NG_HAND_HI", str(ng.PALM_RATIO_MAX)))
# Vision's hand-pose confidences sit around 0.4-0.8 even on a clean, well-lit
# hand — an index fingertip averages ~0.5 and dips to 0.13. Anything stricter
# than this drops the very finger people pick their nose with. Phantom tips are
# no longer dangerous now that the zone is nose-sized and has to be held still.
MIN_CONF = float(os.environ.get("NG_MIN_CONF", "0.3"))
# Structural palm joints only feed a coarse size ratio, so a noisy one is fine.
PALM_CONF = float(os.environ.get("NG_PALM_CONF", "0.2"))
DEBUG = os.environ.get("NG_DEBUG", "") not in ("", "0", "false", "no")
CAM = int(os.environ.get("NG_CAM", "0"))
CAM_ID = os.environ.get("NG_CAM_ID", "").strip()
FPS = int(os.environ.get("NG_FPS", "5"))

COOLDOWN_S = 1.5  # min gap between fired alerts

FINGERTIP_JOINTS = [
    Vision.VNHumanHandPoseObservationJointNameThumbTip,
    Vision.VNHumanHandPoseObservationJointNameIndexTip,
    Vision.VNHumanHandPoseObservationJointNameMiddleTip,
    Vision.VNHumanHandPoseObservationJointNameRingTip,
    Vision.VNHumanHandPoseObservationJointNameLittleTip,
]
# Palm skeleton, for the depth cue. Keys match nose_geom.PALM_BASELINES.
PALM_JOINTS = {
    "Wrist": Vision.VNHumanHandPoseObservationJointNameWrist,
    "IndexMCP": Vision.VNHumanHandPoseObservationJointNameIndexMCP,
    "MiddleMCP": Vision.VNHumanHandPoseObservationJointNameMiddleMCP,
    "RingMCP": Vision.VNHumanHandPoseObservationJointNameRingMCP,
    "LittleMCP": Vision.VNHumanHandPoseObservationJointNameLittleMCP,
}

# Nose only. `medianLine` runs forehead-to-chin and the lip regions cover the
# mouth, so including them made every beard scratch and every bite a "touch".
NOSE_REGIONS = ("nose", "noseCrest")
PUPIL_REGIONS = ("leftPupil", "rightPupil")
UNIT = Foundation.NSMakeSize(1.0, 1.0)  # → points in normalized image coords


def fire(event):
    # -g = don't bring an app to foreground / steal focus
    subprocess.Popen(["open", "-g", f"hammerspoon://noseguard?event={event}"])


def _region_points(lm, name):
    """Normalized image points of one landmark region ([] when absent)."""
    try:
        region = getattr(lm, name)()
        if region is None:
            return []
        arr = region.pointsInImageOfSize_(UNIT)
        return [(arr[i].x, arr[i].y) for i in range(region.pointCount())]
    except Exception as e:
        print(f"noseguard: face region {name} extract failed: {e}", flush=True)
        return []


def face_geometry(face_req, aspect):
    """Nose cloud + centre + IPD scale for the largest face in frame.

    Largest only: merging every observation dragged in faces on a monitor
    behind you, and each extra nose widened the zone.
    """
    obs, best = None, -1.0
    for o in (face_req.results() or []):
        box = o.boundingBox()
        area = box.size.width * box.size.height
        if area > best:
            obs, best = o, area
    if obs is None:
        return None
    lm = obs.landmarks()
    if lm is None:
        return None

    raw = []
    for name in NOSE_REGIONS:
        raw.extend(_region_points(lm, name))
    if not raw:
        return None
    nose = ng.iso_all(raw, aspect)

    pupils = []
    for name in PUPIL_REGIONS:
        pupils.extend(_region_points(lm, name))
    scale = ng.face_scale(ng.iso_all(pupils, aspect),
                          obs.boundingBox().size.width * aspect)
    if not scale:
        return None
    return ng.Face(nose=nose, center=ng.centroid(nose), scale=scale)


def _joint(obs, name, aspect, min_conf):
    try:
        pt, err = obs.recognizedPointForJointName_error_(name, None)
    except Exception as e:
        print(f"noseguard: hand joint extract failed: {e}", flush=True)
        return None
    if pt is None or pt.confidence() < min_conf:
        return None
    return ng.iso((pt.x(), pt.y()), aspect)


def hands(hand_req, aspect):
    """Per-hand fingertips plus apparent palm length (the depth cue)."""
    out = []
    for obs in (hand_req.results() or []):
        tips = [t for t in (_joint(obs, j, aspect, MIN_CONF) for j in FINGERTIP_JOINTS) if t]
        if not tips:
            continue
        palm_pts = {}
        for short, name in PALM_JOINTS.items():
            pt = _joint(obs, name, aspect, PALM_CONF)
            if pt:
                palm_pts[short] = pt
        out.append(ng.Hand(tips=tips, palm=ng.palm_length(palm_pts)))
    return out


class NoseGuardDelegate(Foundation.NSObject):
    def init(self):
        self = objc.super(NoseGuardDelegate, self).init()
        if self is None:
            return None
        self.face_req = Vision.VNDetectFaceLandmarksRequest.alloc().init()
        self.hand_req = Vision.VNDetectHumanHandPoseRequest.alloc().init()
        self.hand_req.setMaximumHandCount_(2)
        self.gate = ng.TouchGate(hold_s=HOLD_S, min_frames=FRAMES,
                                 cooldown_s=COOLDOWN_S, max_speed=MAX_SPEED)
        self.announced = False
        self.interval = 1.0 / FPS   # wall-clock gate: cameras ignore low fps requests
        self.face_skip = 2          # re-run face detection every Nth processed frame
        self._last = 0.0
        self._vn = 0
        self._dbg = 0.0
        self.face = None            # cached nose geometry (the head moves slowly)
        return self

    def captureOutput_didOutputSampleBuffer_fromConnection_(self, output, sbuf, conn):
        # The camera delivers ~28fps regardless of frame-duration requests, so
        # gate on wall-clock to actually run Vision at ~FPS. The check is cheap;
        # dropped frames cost only one callback dispatch.
        now = time.time()
        if now - self._last < self.interval:
            return
        self._last = now
        pixbuf = CoreMedia.CMSampleBufferGetImageBuffer(sbuf)
        if pixbuf is None:
            return
        if not self.announced:
            self.announced = True
            fire("ready")
            print(f"noseguard: running (AVFoundation {FPS}fps / Vision GPU) "
                  f"sens={SENS:.0f} radius={ng.touch_radius(SENS, 1.0):.2f}xIPD "
                  f"hold={HOLD_S}s/{FRAMES}f", flush=True)

        # Normalized coords are anisotropic on a wide frame; correct x so
        # "distance" means the same thing horizontally and vertically.
        aspect = ng.aspect_of(Quartz.CVPixelBufferGetWidth(pixbuf),
                              Quartz.CVPixelBufferGetHeight(pixbuf))

        # Hand every frame (it's what moves); face occasionally (it's near-static).
        self._vn += 1
        do_face = self.face is None or (self._vn % self.face_skip == 0)
        reqs = [self.hand_req] + ([self.face_req] if do_face else [])

        handler = Vision.VNImageRequestHandler.alloc().initWithCVPixelBuffer_orientation_options_(
            pixbuf, 1, {})
        ok, err = handler.performRequests_error_(reqs, None)
        if not ok:
            return

        if do_face:
            self.face = face_geometry(self.face_req, aspect)
        hand_list = hands(self.hand_req, aspect)
        if self.face is None or not hand_list:
            self.gate.update(time.time(), None)
            return

        radius = ng.touch_radius(SENS, self.face.scale)
        off = ng.best_contact(self.face, hand_list, radius, HAND_HI)
        if off is not None and not do_face:
            # Confirm against fresh landmarks before believing it. Cached nose
            # coords are up to face_skip frames old, and a head that moved in
            # the meantime can drift onto a hand that never came near it.
            if handler.performRequests_error_([self.face_req], None)[0]:
                self.face = face_geometry(self.face_req, aspect) or self.face
                radius = ng.touch_radius(SENS, self.face.scale)
                off = ng.best_contact(self.face, hand_list, radius, HAND_HI)

        now = time.time()
        if DEBUG and now - self._dbg >= 1.0:
            self._dbg = now
            near = min((ng.nearest_dist(t, self.face.nose)
                        for h in hand_list for t in h.tips), default=float("inf"))
            ratios = [ng.palm_ratio(h.palm, self.face.scale) for h in hand_list]
            print(f"noseguard: near={near / radius:.2f}xR "
                  f"palm={[round(r, 2) for r in ratios if r is not None]} "
                  f"speed={self.gate.speed:.2f} frames={self.gate.frames}", flush=True)

        if self.gate.update(now, off):
            fire("touch")
            print("noseguard: TOUCH", flush=True)


def _device_types():
    """All video device types this macOS exposes (Continuity may be absent)."""
    types = [AV.AVCaptureDeviceTypeBuiltInWideAngleCamera,
             AV.AVCaptureDeviceTypeExternalUnknown]
    for name in ("AVCaptureDeviceTypeExternal",
                 "AVCaptureDeviceTypeContinuityCamera",
                 "AVCaptureDeviceTypeDeskViewCamera"):
        t = getattr(AV, name, None)
        if t is not None:
            types.append(t)
    return types


def discover_devices():
    """Stable ordered device list via discovery session, built-ins first."""
    sess = AV.AVCaptureDeviceDiscoverySession.discoverySessionWithDeviceTypes_mediaType_position_(
        _device_types(), AV.AVMediaTypeVideo, 0)  # 0 = unspecified position
    devs = list(sess.devices() or [])
    if not devs:  # fallback for older macOS
        devs = list(AV.AVCaptureDevice.devicesWithMediaType_(AV.AVMediaTypeVideo) or [])
    builtin = AV.AVCaptureDeviceTypeBuiltInWideAngleCamera
    # Built-in webcam(s) first so a missing iPhone never shifts the default.
    devs.sort(key=lambda d: 0 if d.deviceType() == builtin else 1)
    return devs


def is_builtin(d):
    return d.deviceType() == AV.AVCaptureDeviceTypeBuiltInWideAngleCamera


def list_devices():
    import json
    out = []
    for i, d in enumerate(discover_devices()):
        out.append({
            "index": i,
            "id": d.uniqueID(),
            "name": d.localizedName(),
            "builtin": bool(is_builtin(d)),
            "connected": bool(d.isConnected()),
        })
    print(json.dumps(out))


def pick_device():
    devs = discover_devices()
    if not devs:
        return AV.AVCaptureDevice.defaultDeviceWithMediaType_(AV.AVMediaTypeVideo)
    # 1. Prefer the stable uniqueID, but only if it's actually connected.
    if CAM_ID:
        for d in devs:
            if d.uniqueID() == CAM_ID and d.isConnected():
                return d
        print(f"noseguard: NG_CAM_ID {CAM_ID} not connected; falling back", flush=True)
    # 2. Index fallback over the same ordered, connected-only list.
    connected = [d for d in devs if d.isConnected()]
    if connected and 0 <= CAM < len(connected):
        return connected[CAM]
    # 3. First connected built-in, else first connected, else anything.
    for d in connected:
        if is_builtin(d):
            return d
    return connected[0] if connected else devs[0]


def ensure_camera_access():
    status = AV.AVCaptureDevice.authorizationStatusForMediaType_(AV.AVMediaTypeVideo)
    if status == 3:  # authorized
        return True
    if status in (1, 2):  # restricted / denied
        return False
    # notDetermined → request and wait (prompt attributed to Hammerspoon)
    box = {"granted": None}
    def handler(granted):
        box["granted"] = bool(granted)
    AV.AVCaptureDevice.requestAccessForMediaType_completionHandler_(AV.AVMediaTypeVideo, handler)
    for _ in range(300):  # up to ~30s
        if box["granted"] is not None:
            break
        time.sleep(0.1)
    return AV.AVCaptureDevice.authorizationStatusForMediaType_(AV.AVMediaTypeVideo) == 3


def main():
    if not ensure_camera_access():
        print("noseguard: camera access denied", file=sys.stderr)
        fire("error")
        return

    device = pick_device()
    if device is None:
        print("noseguard: no camera device", file=sys.stderr)
        fire("error")
        return

    session = AV.AVCaptureSession.alloc().init()

    inp, err = AV.AVCaptureDeviceInput.deviceInputWithDevice_error_(device, None)
    if inp is None or not session.canAddInput_(inp):
        print(f"noseguard: cannot add camera input: {err}", file=sys.stderr)
        fire("error")
        return
    session.addInput_(inp)

    delegate = NoseGuardDelegate.alloc().init()
    # Face landmarks a few times a second, hands every processed frame. Staler
    # than that and the nose the stillness test measures against lags the head.
    delegate.face_skip = max(1, int(os.environ.get("NG_FACE_SKIP", "0")) or FPS // 2 or 1)
    output = AV.AVCaptureVideoDataOutput.alloc().init()
    output.setAlwaysDiscardsLateVideoFrames_(True)
    # No videoSettings → camera-native pixel format (YUV). Vision consumes it
    # directly, so we avoid a 32BGRA colour-convert on every delivered frame.
    queue = libdispatch.dispatch_queue_create(b"com.noseguard.camera", None)
    output.setSampleBufferDelegate_queue_(delegate, queue)
    if not session.canAddOutput_(output):
        print("noseguard: cannot add video output", file=sys.stderr)
        fire("error")
        return
    session.addOutput_(output)

    # Pick the smallest format that supports a low frame rate; setting activeFormat
    # puts the session in input-priority mode so the frame-duration request is
    # honoured where the camera allows it (many built-ins floor at ~28fps anyway —
    # the wall-clock gate in the delegate is what guarantees ~FPS processing).
    try:
        best, best_px = None, None
        for f in device.formats():
            dims = CoreMedia.CMVideoFormatDescriptionGetDimensions(f.formatDescription())
            px = dims.width * dims.height
            lowest = min((r.minFrameRate() for r in f.videoSupportedFrameRateRanges()),
                         default=99.0)
            if lowest <= 15.0 and px >= 640 * 360 and (best_px is None or px < best_px):
                best, best_px = f, px
        session.beginConfiguration()
        if device.lockForConfiguration_(None)[0]:
            if best is not None:
                device.setActiveFormat_(best)
            dur = CoreMedia.CMTimeMake(1, 15)
            try:
                device.setActiveVideoMinFrameDuration_(dur)
                device.setActiveVideoMaxFrameDuration_(dur)
            except Exception as e:
                print(f"noseguard: frame-duration set skipped: {e}", flush=True)
            device.unlockForConfiguration()
        session.commitConfiguration()
    except Exception as e:
        print(f"noseguard: format select failed: {e}", flush=True)

    print(f"noseguard: target {FPS}fps (wall-clock gated), face every {delegate.face_skip}",
          flush=True)
    session.startRunning()
    print("noseguard: session started", flush=True)

    # Keep the process alive; frames arrive on the dispatch queue.
    Foundation.NSRunLoop.currentRunLoop().run()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "list":
        list_devices()
    else:
        main()

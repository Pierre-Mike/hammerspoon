#!/usr/bin/env python3
"""Nose Guard daemon — webcam hand-to-face detector (AVFoundation + Apple Vision).

Runs headless (no window). When a fingertip lingers near the face zone for
HOLD_S seconds it fires the Hammerspoon urlevent `hammerspoon://noseguard`,
which draws the disruptive overlay + alarm. Detection keeps running regardless
of which app is focused — that's the whole point vs the browser version.

Capture: a native AVCaptureSession driven at ~5 fps (activeVideoMinFrameDuration),
delivering CVPixelBuffers straight to Vision — no OpenCV, no per-frame colour
convert or byte copy. Detection: VNDetectFaceLandmarksRequest +
VNDetectHumanHandPoseRequest run on the GPU + Neural Engine. This keeps CPU low:
the camera physically runs at 5 fps instead of OpenCV's fixed 30 fps decode.
(MediaPipe's Metal GPU delegate aborts on macOS — see project_noseguard_gpu_crash.)

Env knobs (set by the Hammerspoon launcher, all optional):
  NG_SENS   0..100  sensitivity, higher = triggers from further away (default 55)
  NG_HOLD   seconds touch must persist before alerting       (default 0.4)
  NG_CAM    camera index (fallback only)                     (default 0)
  NG_CAM_ID AVFoundation uniqueID — stable, preferred over NG_CAM
  NG_FPS    capture frames per second                        (default 5)

Run `python noseguard.py list` to print discovered cameras as JSON
(uniqueID, name, builtin, connected) — used by the Hammerspoon menu so the
menu and the daemon share one device list (index drift breaks otherwise, e.g.
the iPhone Continuity Camera appearing/disappearing).
"""
import os
import math
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

SENS = float(os.environ.get("NG_SENS", "55"))
HOLD_S = float(os.environ.get("NG_HOLD", "0.4"))
CAM = int(os.environ.get("NG_CAM", "0"))
CAM_ID = os.environ.get("NG_CAM_ID", "").strip()
FPS = int(os.environ.get("NG_FPS", "5"))

# normalized-distance threshold: high sensitivity -> larger threshold
THR = 0.045 + (100.0 - SENS) / 100.0 * 0.11
COOLDOWN_S = 1.5  # min gap between fired alerts
MIN_CONF = 0.3    # min fingertip confidence

FINGERTIP_JOINTS = [
    Vision.VNHumanHandPoseObservationJointNameThumbTip,
    Vision.VNHumanHandPoseObservationJointNameIndexTip,
    Vision.VNHumanHandPoseObservationJointNameMiddleTip,
    Vision.VNHumanHandPoseObservationJointNameRingTip,
    Vision.VNHumanHandPoseObservationJointNameLittleTip,
]
FACE_REGIONS = ("nose", "noseCrest", "medianLine", "innerLips", "outerLips")
UNIT = Foundation.NSMakeSize(1.0, 1.0)  # → points in normalized image coords


def fire(event):
    # -g = don't bring an app to foreground / steal focus
    subprocess.Popen(["open", "-g", f"hammerspoon://noseguard?event={event}"])


def face_targets(face_req):
    """List of (x, y) normalized image points across the face zone."""
    pts = []
    for obs in (face_req.results() or []):
        lm = obs.landmarks()
        if lm is None:
            continue
        for name in FACE_REGIONS:
            try:
                region = getattr(lm, name)()
                if region is None:
                    continue
                arr = region.pointsInImageOfSize_(UNIT)
                for i in range(region.pointCount()):
                    p = arr[i]
                    pts.append((p.x, p.y))
            except Exception as e:
                print(f"noseguard: face region {name} extract failed: {e}", flush=True)
    return pts


def hand_tips(hand_req):
    """List of (x, y) normalized image fingertip points."""
    tips = []
    for obs in (hand_req.results() or []):
        for joint in FINGERTIP_JOINTS:
            try:
                pt, err = obs.recognizedPointForJointName_error_(joint, None)
                if pt is not None and pt.confidence() >= MIN_CONF:
                    tips.append((pt.x(), pt.y()))
            except Exception as e:
                print(f"noseguard: hand joint extract failed: {e}", flush=True)
    return tips


class NoseGuardDelegate(Foundation.NSObject):
    def init(self):
        self = objc.super(NoseGuardDelegate, self).init()
        if self is None:
            return None
        self.face_req = Vision.VNDetectFaceLandmarksRequest.alloc().init()
        self.hand_req = Vision.VNDetectHumanHandPoseRequest.alloc().init()
        self.hand_req.setMaximumHandCount_(2)
        self.touch_start = None
        self.last_alert = 0.0
        self.announced = False
        self.interval = 1.0 / FPS   # wall-clock gate: cameras ignore low fps requests
        self.face_skip = 5          # re-run face detection every Nth processed frame
        self._last = 0.0
        self._vn = 0
        self.targets = None         # cached face points (face moves slowly)
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
            print(f"noseguard: running (AVFoundation {FPS}fps / Vision GPU) thr={THR:.3f}", flush=True)

        # Hand every frame (it's what moves); face occasionally (it's near-static).
        self._vn += 1
        do_face = self.targets is None or (self._vn % self.face_skip == 0)
        reqs = [self.hand_req] + ([self.face_req] if do_face else [])

        handler = Vision.VNImageRequestHandler.alloc().initWithCVPixelBuffer_orientation_options_(
            pixbuf, 1, {})
        ok, err = handler.performRequests_error_(reqs, None)
        if not ok:
            return

        if do_face:
            self.targets = face_targets(self.face_req)
        targets = self.targets or []
        tips = hand_tips(self.hand_req)

        touching = False
        if targets and tips:
            for (fx, fy) in tips:
                for (px, py) in targets:
                    if math.hypot(fx - px, fy - py) < THR:
                        touching = True
                        break
                if touching:
                    break

        now = time.time()
        if touching:
            if self.touch_start is None:
                self.touch_start = now
            elif now - self.touch_start >= HOLD_S and now - self.last_alert >= COOLDOWN_S:
                fire("touch")
                self.last_alert = now
                print("noseguard: TOUCH", flush=True)
        else:
            self.touch_start = None


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
    delegate.face_skip = max(1, FPS)  # re-detect face ~1x/sec; hand every processed frame
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

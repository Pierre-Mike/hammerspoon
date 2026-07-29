"""Pure geometry + debounce behind Nose Guard's nose-only contact test.

Imports nothing from Vision/AVFoundation on purpose, so the entire decision
path is unit-testable with plain python3 (see tests/test_nose_geom.py).

Coordinate space
----------------
Vision hands back normalized image coordinates (0..1, origin bottom-left).
Those are *anisotropic* on a non-square frame: 0.1 in x spans 128 px of a
1280x720 buffer but only 72 px in y. So every distance below is in "iso
units" — x pre-multiplied by the frame aspect ratio, making one unit the same
physical length on both axes (one frame height).

Scale
-----
Thresholds are multiples of the interpupillary distance (IPD, ~63 mm on
almost every adult face) instead of fractions of the frame. The guard then
behaves the same whether you lean into the camera or sit back; a fixed
frame-relative radius quietly grows to cover half the face as the face
shrinks, which is what made the old version fire at anything near the head.
"""
import collections
import math

# Nose point cloud, its centre, and the IPD scale — all in iso units.
Face = collections.namedtuple("Face", "nose center scale")
# One hand's fingertips (iso units) plus its apparent palm length, which only
# feeds the lens-proximity ceiling below.
Hand = collections.namedtuple("Hand", "tips palm")

# Contact radius as a fraction of IPD, at sensitivity 0 and 100.
# IPD ≈ 63 mm, so this spans roughly 6 mm .. 25 mm of slack around the nose
# outline. Medium (55) lands near 17 mm — close enough to be a real touch,
# loose enough to survive landmark jitter.
RADIUS_MIN = 0.10
RADIUS_MAX = 0.40

# Apparent palm length over IPD — a *one-sided* lens-proximity backstop, not a
# depth test. The tempting version of this idea (palm and IPD are both fixed
# anatomy, so the ratio should betray a hand nearer the lens than the face) does
# not survive measurement. Across a minute of webcam capture the ratio ranged
# 0.39 .. 2.21, and both ends of that were seen on frames with a fingertip
# genuinely inside the nose zone — a 5.7x spread with no separation between
# "on the nose" and "somewhere else in frame". Hand *orientation* foreshortens
# the palm at least as much as depth scales it: a hand up at the face angles
# its palm away and measures short. Hence no floor at all (it would veto real
# touches) and a ceiling well clear of everything observed, catching only a hand
# shoved at the camera. The precision this guard actually needs comes from the
# nose-sized zone and the hold, not from here.
PALM_RATIO_MAX = 4.00

# Long, pose-stable baselines across the palm skeleton, as multiples of the
# wrist→middle-knuckle length. Knuckle-to-adjacent-knuckle spans are excluded
# on purpose: landmark noise swamps a 20 mm baseline.
PALM_BASELINES = (
    ("Wrist", "MiddleMCP", 1.00),
    ("Wrist", "IndexMCP", 0.95),
    ("Wrist", "RingMCP", 0.95),
    ("Wrist", "LittleMCP", 0.90),
    ("IndexMCP", "LittleMCP", 0.84),
)

# Max drift of the fingertip *relative to the nose*, in IPD units per second.
# Loose on purpose: scratching or rubbing your nose is a nose touch and it
# moves, and at 5 fps a single frame of landmark jitter already reads as ~1.
# Observed live: 0.0 while a finger rested, 1.2-1.4 while it worked at the
# nose, 2.6 on a hand crossing frame. The real discriminator for a transit is
# the hold below — nothing sweeps past and stays in a 17 mm zone for half a
# second — so this only has to catch the blatant sweeps.
MAX_SPEED = 3.0

IPD_OVER_FACE_WIDTH = 0.42  # fallback when pupils aren't reported
# A pupil pair this far off the face box is a bad landmark, not a face.
IPD_BOX_MIN = 0.25
IPD_BOX_MAX = 0.65


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def aspect_of(width, height):
    """Frame aspect ratio, or 1.0 when the dimensions are unusable."""
    if not width or not height:
        return 1.0
    return float(width) / float(height)


def iso(pt, aspect):
    """Normalized image point → isotropic units."""
    return (pt[0] * aspect, pt[1])


def iso_all(pts, aspect):
    return [(x * aspect, y) for (x, y) in pts]


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def centroid(pts):
    if not pts:
        return None
    return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))


def nearest_dist(pt, pts):
    """Distance from pt to the closest of pts (inf when pts is empty)."""
    best = float("inf")
    for p in pts:
        d = dist(pt, p)
        if d < best:
            best = d
    return best


def touch_radius(sens, scale):
    """Contact radius in iso units for a 0..100 sensitivity and an IPD scale."""
    frac = RADIUS_MIN + clamp(float(sens), 0.0, 100.0) / 100.0 * (RADIUS_MAX - RADIUS_MIN)
    return frac * scale


def face_scale(pupils, box_width):
    """IPD in iso units — measured between pupils, else inferred from the box.

    Yaw squashes both measures the same way, so either one keeps thresholds
    proportional to the actual head in frame. A pupil pair that doesn't sit
    sanely inside the face box is discarded: one stray landmark would otherwise
    inflate the scale and, with it, the contact radius.
    """
    box = box_width if (box_width and box_width > 0) else None
    if pupils and len(pupils) == 2:
        d = dist(pupils[0], pupils[1])
        if d > 0 and (box is None or IPD_BOX_MIN * box <= d <= IPD_BOX_MAX * box):
            return d
    if box is not None:
        return box * IPD_OVER_FACE_WIDTH
    return None


def palm_length(joints):
    """Apparent wrist→middle-knuckle length, from whatever palm joints landed.

    `joints` maps joint name → iso point; missing names are fine. Vision's
    per-joint confidence on a hand held near the face hovers around 0.5, so
    insisting on one specific pair leaves the depth cue unavailable half the
    time. Instead every baseline that came through is divided by its anatomical
    ratio, so they all express the same length, and the median is taken — one
    stray landmark moves a median far less than a mean or a max.
    """
    est = []
    for a, b, ratio in PALM_BASELINES:
        pa, pb = joints.get(a), joints.get(b)
        if pa and pb:
            est.append(dist(pa, pb) / ratio)
    if not est:
        return None
    est.sort()
    mid = len(est) // 2
    return est[mid] if len(est) % 2 else 0.5 * (est[mid - 1] + est[mid])


def palm_ratio(palm_len, scale):
    """Apparent palm length over IPD — a crude but real depth cue."""
    if not palm_len or not scale or scale <= 0:
        return None
    return palm_len / scale


def depth_plausible(ratio, hi=PALM_RATIO_MAX):
    """False only when the hand is so large it must be up against the lens.

    An unknown ratio passes: a partly-occluded palm shouldn't veto a contact
    the zone test already agrees with. See PALM_RATIO_MAX for why there's no
    lower bound.
    """
    if ratio is None:
        return True
    return ratio <= hi


def contact_offset(tip, nose_pts, nose_center, radius, scale):
    """Offset of tip from the nose centre in IPD units, or None if not touching.

    Proximity is measured against the nose point cloud (so the zone hugs the
    nose's actual shape and tilts with the head), while the returned offset is
    relative to its centre — a frame-independent handle the debounce can watch
    for stillness even as the head moves.
    """
    if not nose_pts or nose_center is None or not scale or scale <= 0:
        return None
    if nearest_dist(tip, nose_pts) > radius:
        return None
    return ((tip[0] - nose_center[0]) / scale, (tip[1] - nose_center[1]) / scale)


def best_contact(face, hands, radius, hi=PALM_RATIO_MAX):
    """Tightest nose contact across every hand in frame, or None."""
    if face is None or not hands:
        return None
    best = None
    for hand in hands:
        if not depth_plausible(palm_ratio(hand.palm, face.scale), hi):
            continue  # hand is at the lens, not at the face
        for tip in hand.tips:
            off = contact_offset(tip, face.nose, face.center, radius, face.scale)
            if off is None:
                continue
            if best is None or _mag2(off) < _mag2(best):
                best = off
    return best


def _mag2(pt):
    return pt[0] * pt[0] + pt[1] * pt[1]


class TouchGate:
    """Sustained-contact debounce.

    A frame is a *candidate* when a fingertip sits inside the nose zone and the
    hand's apparent size puts it in the face's depth plane. Firing on top of
    that needs the contact to hold still: a hand crossing the nose en route to
    your mouth passes the zone test for a frame or two but never the stillness
    one. One missing frame is forgiven (`miss_grace`) so a dropped hand
    detection mid-touch doesn't restart the hold.
    """

    def __init__(self, hold_s=0.4, min_frames=3, cooldown_s=1.5,
                 max_speed=MAX_SPEED, miss_grace=1):
        self.hold_s = hold_s
        self.min_frames = max(1, int(min_frames))
        self.cooldown_s = cooldown_s
        self.max_speed = max_speed
        self.miss_grace = max(0, int(miss_grace))
        self.last_fire = None  # None, not 0.0 — else the cooldown eats the first alert
        self.speed = 0.0  # most recent relative speed, for debug logging
        self._clear()

    def _clear(self):
        self.start = None
        self.frames = 0
        self.misses = 0
        self.prev = None
        self.prev_t = None

    def reset(self):
        self._clear()

    def update(self, now, offset):
        """Feed one frame. `offset` is contact_offset() or None. True → fire."""
        if offset is None:
            self.misses += 1
            self.speed = 0.0
            if self.misses > self.miss_grace:
                self._clear()
            return False

        self.misses = 0
        if self.prev is not None and self.prev_t is not None and now > self.prev_t:
            self.speed = dist(offset, self.prev) / (now - self.prev_t)
            if self.speed > self.max_speed:
                # Sweeping past, not resting on. Drop the hold but keep this
                # sample as the baseline so a hand settling in can build a
                # fresh streak from here.
                self._clear()
                self.prev, self.prev_t = offset, now
                return False
        else:
            self.speed = 0.0

        self.prev, self.prev_t = offset, now
        if self.start is None:
            self.start = now
        self.frames += 1

        cool = self.last_fire is None or now - self.last_fire >= self.cooldown_s
        if self.frames >= self.min_frames and now - self.start >= self.hold_s and cool:
            self.last_fire = now
            return True
        return False

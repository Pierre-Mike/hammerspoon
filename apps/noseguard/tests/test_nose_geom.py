"""Unit tests for the pure part of Nose Guard's contact test.

Run with the noseguard venv (or any python3 — nose_geom has no deps):
    apps/noseguard/.venv/bin/python -m unittest discover apps/noseguard/tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import nose_geom as g  # noqa: E402


# A synthetic face, in normalized image coords on a 16:9 frame. IPD is 0.06 in
# x, which the aspect correction turns into 0.1067 iso units.
ASPECT = g.aspect_of(1280, 720)
PUPIL_L = (0.47, 0.62)
PUPIL_R = (0.53, 0.62)
# Nose outline: bridge down to the tip, nostril wings either side.
NOSE = [(0.50, 0.58), (0.50, 0.55), (0.50, 0.52), (0.485, 0.525), (0.515, 0.525)]
MOUTH = (0.50, 0.47)     # ~1.5 cm below the nose tip in this geometry
CHIN = (0.50, 0.42)
CHEEK = (0.455, 0.53)


def scene(sens=55):
    pupils = g.iso_all([PUPIL_L, PUPIL_R], ASPECT)
    nose = g.iso_all(NOSE, ASPECT)
    scale = g.face_scale(pupils, None)
    return nose, g.centroid(nose), g.touch_radius(sens, scale), scale


def offset_for(pt, sens=55):
    nose, center, radius, scale = scene(sens)
    return g.contact_offset(g.iso(pt, ASPECT), nose, center, radius, scale)


class TestScale(unittest.TestCase):
    def test_aspect_makes_x_and_y_comparable(self):
        self.assertAlmostEqual(ASPECT, 16 / 9, places=6)
        self.assertEqual(g.aspect_of(0, 720), 1.0)
        self.assertEqual(g.aspect_of(1280, 0), 1.0)

    def test_ipd_measured_between_pupils(self):
        pupils = g.iso_all([PUPIL_L, PUPIL_R], ASPECT)
        self.assertAlmostEqual(g.face_scale(pupils, None), 0.06 * ASPECT, places=6)

    def test_ipd_falls_back_to_box_width(self):
        self.assertAlmostEqual(g.face_scale(None, 0.2), 0.2 * g.IPD_OVER_FACE_WIDTH,
                               places=6)

    def test_no_scale_without_either_source(self):
        self.assertIsNone(g.face_scale(None, None))
        self.assertIsNone(g.face_scale([(0.5, 0.5), (0.5, 0.5)], 0))

    def test_implausible_pupil_pair_falls_back_to_the_box(self):
        # A stray "pupil" halfway across the frame must not inflate the scale.
        box = 0.2
        bogus = [(0.1, 0.6), (0.9, 0.6)]
        self.assertAlmostEqual(g.face_scale(bogus, box), box * g.IPD_OVER_FACE_WIDTH,
                               places=6)

    def test_radius_scales_with_the_face_not_the_frame(self):
        # Same person twice as far away → half the pixels, half the radius.
        near = g.touch_radius(55, 0.12)
        far = g.touch_radius(55, 0.06)
        self.assertAlmostEqual(near, 2 * far, places=6)

    def test_radius_tracks_sensitivity(self):
        self.assertLess(g.touch_radius(35, 0.1), g.touch_radius(55, 0.1))
        self.assertLess(g.touch_radius(55, 0.1), g.touch_radius(75, 0.1))
        # Even wide open, the zone stays a fraction of the IPD.
        self.assertLessEqual(g.touch_radius(100, 0.1), g.RADIUS_MAX * 0.1)

    def test_radius_clamps_out_of_range_sensitivity(self):
        self.assertEqual(g.touch_radius(-20, 0.1), g.touch_radius(0, 0.1))
        self.assertEqual(g.touch_radius(999, 0.1), g.touch_radius(100, 0.1))


class TestContactZone(unittest.TestCase):
    def test_finger_on_the_nose_tip_is_contact(self):
        self.assertIsNotNone(offset_for((0.50, 0.52)))

    def test_finger_on_the_nose_bridge_is_contact(self):
        self.assertIsNotNone(offset_for((0.50, 0.58)))

    def test_finger_on_the_mouth_is_not_contact(self):
        self.assertIsNone(offset_for(MOUTH))

    def test_finger_on_the_chin_or_beard_is_not_contact(self):
        self.assertIsNone(offset_for(CHIN))

    def test_finger_on_the_cheek_is_not_contact(self):
        self.assertIsNone(offset_for(CHEEK))

    def test_high_sensitivity_still_excludes_the_beard(self):
        self.assertIsNone(offset_for(CHIN, sens=100))

    def test_offset_is_relative_to_the_nose_centre_in_ipd_units(self):
        nose, center, radius, scale = scene()
        tip = g.iso((0.50, 0.55), ASPECT)
        off = g.contact_offset(tip, nose, center, radius, scale)
        self.assertAlmostEqual(off[0], (tip[0] - center[0]) / scale, places=9)
        self.assertAlmostEqual(off[1], (tip[1] - center[1]) / scale, places=9)

    def test_missing_inputs_are_not_contact(self):
        nose, center, radius, scale = scene()
        self.assertIsNone(g.contact_offset((0.5, 0.5), [], center, radius, scale))
        self.assertIsNone(g.contact_offset((0.5, 0.5), nose, None, radius, scale))
        self.assertIsNone(g.contact_offset((0.5, 0.5), nose, center, radius, None))


# Wrist at the origin, knuckles fanned across the palm arc so that every
# PALM_BASELINES pair, divided by its anatomical ratio, comes back to 1.0.
PALM_UNIT = {
    "Wrist": (0.0, 0.0),
    "IndexMCP": (-0.4090, 0.8575),
    "MiddleMCP": (0.0, 1.0000),
    "RingMCP": (0.2936, 0.9035),
    "LittleMCP": (0.4295, 0.7909),
}


def palm_joints(length=0.095, scale=1.0):
    """Wrist + 4 knuckles sized so every baseline measures `length`."""
    r = length * scale
    return {k: (x * r, y * r) for k, (x, y) in PALM_UNIT.items()}


class TestPalmLength(unittest.TestCase):
    def test_agreeing_baselines_recover_the_palm_length(self):
        est = g.palm_length(palm_joints(0.095))
        self.assertAlmostEqual(est, 0.095, delta=0.001)

    def test_wrist_alone_yields_nothing(self):
        self.assertIsNone(g.palm_length({"Wrist": (0.0, 0.0)}))
        self.assertIsNone(g.palm_length({}))

    def test_a_single_baseline_is_enough(self):
        est = g.palm_length({"Wrist": (0.0, 0.0), "MiddleMCP": (0.0, 0.095)})
        self.assertAlmostEqual(est, 0.095, places=6)

    def test_short_knuckle_spans_are_not_used_as_baselines(self):
        # Adjacent knuckles only: too short to measure, so no estimate at all.
        self.assertIsNone(g.palm_length({"MiddleMCP": (0.0, 0.1),
                                         "RingMCP": (0.02, 0.1)}))

    def test_one_stray_landmark_does_not_move_the_median(self):
        # A blown-out knuckle corrupts both baselines it sits on, so 2 of the 5
        # estimates go wild — the median still lands on a good one.
        joints = palm_joints(0.095)
        joints["LittleMCP"] = (0.9, 0.9)
        self.assertAlmostEqual(g.palm_length(joints), 0.095, delta=0.001)

    def test_estimate_scales_with_apparent_size(self):
        near = g.palm_length(palm_joints(0.095, scale=2.0))
        far = g.palm_length(palm_joints(0.095, scale=1.0))
        self.assertAlmostEqual(near, 2 * far, places=6)


class TestDepthCeiling(unittest.TestCase):
    """The palm/IPD ratio is a lens-proximity ceiling, nothing finer.

    The bounds here are the ones actually measured off the webcam (see
    nose_geom.PALM_RATIO_MAX), not anatomy-book figures.
    """

    # Ratios recorded live, from frames where a fingertip was genuinely inside
    # the nose zone. The spread is the whole point: it's why there is no floor.
    OBSERVED_AT_CONTACT = (0.53, 1.19, 1.43, 2.21)
    OBSERVED_HAND_ELSEWHERE = (0.39, 0.65, 1.10, 1.52, 1.53)

    def observed(self):
        return self.OBSERVED_AT_CONTACT + self.OBSERVED_HAND_ELSEWHERE

    def test_no_observed_real_contact_is_rejected(self):
        for r in self.OBSERVED_AT_CONTACT:
            self.assertTrue(g.depth_plausible(r), f"ratio {r} was a real touch")

    def test_no_lower_bound_exists(self):
        # The low tail of real contacts (0.53) is why: a floor anywhere near
        # the "expected" 1.5 would veto genuine nose touches.
        self.assertTrue(g.depth_plausible(0.01))

    def test_hand_shoved_at_the_lens_is_rejected(self):
        self.assertFalse(g.depth_plausible(max(self.observed()) * 2.5))

    def test_ceiling_clears_everything_ever_observed(self):
        self.assertGreater(g.PALM_RATIO_MAX, max(self.observed()) * 1.5)

    def test_ratio_is_palm_over_scale(self):
        self.assertAlmostEqual(g.palm_ratio(0.095, 0.063), 0.095 / 0.063, places=9)

    def test_unknown_ratio_does_not_veto(self):
        self.assertIsNone(g.palm_ratio(None, 0.063))
        self.assertIsNone(g.palm_ratio(0.095, 0))
        self.assertTrue(g.depth_plausible(None))


class TestBestContact(unittest.TestCase):
    """The whole per-frame decision: zone + depth gate across both hands."""

    def face(self):
        nose, center, _, scale = scene()
        return g.Face(nose=nose, center=center, scale=scale)

    def hand(self, tip, ratio=1.2):
        """A hand with one fingertip. `ratio` is palm/IPD — 1.2 is the median
        measured while a fingertip was actually on the nose."""
        face = self.face()
        return g.Hand(tips=[g.iso(tip, ASPECT)], palm=ratio * face.scale)

    def call(self, hands, sens=55):
        face = self.face()
        return g.best_contact(face, hands, g.touch_radius(sens, face.scale))

    def test_finger_resting_on_the_nose_is_a_contact(self):
        self.assertIsNotNone(self.call([self.hand((0.50, 0.53))]))

    def test_contact_survives_the_low_tail_of_measured_palm_ratios(self):
        self.assertIsNotNone(self.call([self.hand((0.50, 0.53), ratio=0.53)]))

    def test_hand_up_against_the_lens_is_not_a_contact(self):
        # Projects right onto the nose, but reads far too big to be there.
        self.assertIsNone(self.call([self.hand((0.50, 0.53), ratio=6.0)]))

    def test_beard_and_mouth_are_not_contacts_at_the_right_depth(self):
        self.assertIsNone(self.call([self.hand(CHIN), self.hand(MOUTH)]))

    def test_the_closer_of_two_hands_wins(self):
        near = self.hand((0.50, 0.54))
        far = self.hand((0.50, 0.565))
        off = self.call([far, near])
        self.assertIsNotNone(off)
        self.assertLess(g.dist(off, (0, 0)),
                        g.dist(self.call([far]), (0, 0)))

    def test_no_face_or_no_hands_is_no_contact(self):
        self.assertIsNone(g.best_contact(None, [self.hand((0.5, 0.53))], 0.05))
        self.assertIsNone(g.best_contact(self.face(), [], 0.05))


class TestTouchGate(unittest.TestCase):
    def gate(self, **kw):
        kw.setdefault("hold_s", 0.4)
        kw.setdefault("min_frames", 3)
        return g.TouchGate(**kw)

    def test_resting_finger_fires_once_the_hold_elapses(self):
        gate = self.gate()
        fired = [gate.update(t / 10.0, (0.0, 0.0)) for t in range(0, 8)]
        self.assertTrue(any(fired))
        self.assertEqual(fired.index(True), 4)  # 5 frames = 0.4 s at 10 fps

    def test_hold_needs_min_frames_even_when_time_has_passed(self):
        gate = self.gate(min_frames=3, miss_grace=0)
        self.assertFalse(gate.update(0.0, (0.0, 0.0)))
        self.assertFalse(gate.update(5.0, (0.0, 0.0)))  # long enough, only 2 frames
        self.assertTrue(gate.update(5.2, (0.0, 0.0)))

    def test_brief_brush_does_not_fire(self):
        gate = self.gate()
        self.assertFalse(gate.update(0.0, (0.0, 0.0)))
        self.assertFalse(gate.update(0.1, (0.0, 0.0)))
        self.assertFalse(gate.update(0.2, None))
        self.assertFalse(gate.update(0.3, None))
        self.assertFalse(gate.update(0.4, (0.0, 0.0)))

    def test_hand_sweeping_past_the_nose_never_fires(self):
        # 4 units/s of relative drift — an arm on its way to the mouth.
        gate = self.gate()
        for i in range(20):
            t = i * 0.1
            self.assertFalse(gate.update(t, (-1.0 + 0.4 * i, 0.0)))

    def test_hand_that_sweeps_in_then_settles_fires(self):
        gate = self.gate()
        for i in range(3):
            self.assertFalse(gate.update(i * 0.1, (-1.0 + 0.4 * i, 0.0)))
        fired = [gate.update(0.3 + i * 0.1, (0.02, 0.0)) for i in range(8)]
        self.assertTrue(any(fired))

    def test_one_dropped_frame_mid_touch_is_forgiven(self):
        gate = self.gate(miss_grace=1)
        self.assertFalse(gate.update(0.0, (0.0, 0.0)))
        self.assertFalse(gate.update(0.1, (0.0, 0.0)))
        self.assertFalse(gate.update(0.2, None))       # hand detector blinked
        self.assertFalse(gate.update(0.3, (0.0, 0.0)))
        self.assertTrue(gate.update(0.4, (0.0, 0.0)))  # hold survived the gap

    def test_two_dropped_frames_restart_the_hold(self):
        gate = self.gate(miss_grace=1)
        gate.update(0.0, (0.0, 0.0))
        gate.update(0.1, (0.0, 0.0))
        gate.update(0.2, None)
        gate.update(0.3, None)
        self.assertIsNone(gate.start)
        self.assertFalse(gate.update(0.4, (0.0, 0.0)))

    def test_cooldown_gates_repeat_alerts(self):
        gate = self.gate(cooldown_s=1.5)
        fires = [t / 10.0 for t in range(0, 40) if gate.update(t / 10.0, (0.0, 0.0))]
        self.assertGreaterEqual(len(fires), 2)
        for a, b in zip(fires, fires[1:]):
            self.assertGreaterEqual(b - a, 1.5)

    def test_speed_is_measured_across_the_gap_not_per_frame(self):
        gate = self.gate()
        gate.update(0.0, (0.0, 0.0))
        gate.update(2.0, (0.5, 0.0))  # 0.5 units over 2 s = slow, keep the hold
        self.assertEqual(gate.frames, 2)
        self.assertLess(gate.speed, g.MAX_SPEED)


if __name__ == "__main__":
    unittest.main()

"""Exercise profile changes, firmware resets and thermal protection without hardware."""

import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from daemon import Controller


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.limit = root / "constraint_0_power_limit_uw"
        self.limit.write_text("10500000\n")
        self.limit.with_name("constraint_0_name").write_text("long_term\n")
        self.limit.with_name("constraint_0_max_power_uw").write_text("35000000\n")
        self.sensor = root / "hwmon0" / "temp1_input"
        self.sensor.parent.mkdir()
        self.sensor.with_name("name").write_text("coretemp\n")
        self.sensor.write_text("60000\n")
        self.controller = Controller({
            "powerLimitPath": str(self.limit), "hwmonPath": str(root),
            "powerLimits": {"power-saver": 18, "balanced": 28, "performance": 35},
            "temperatureLimitCelsius": 88, "temperatureResumeCelsius": 80,
            "busctl": "/does-not-exist",
        })
        self.profile = "balanced"
        self.profile_patch = patch.object(self.controller, "profile", side_effect=lambda: self.profile)
        self.profile_patch.start()
        self.addCleanup(self.profile_patch.stop)

    def watts(self):
        return int(self.limit.read_text()) / 1000000

    def test_profiles_and_repeated_firmware_resets(self):
        for self.profile, expected in [("power-saver", 18), ("balanced", 28), ("performance", 35)]:
            self.controller.tick()
            self.assertEqual(self.watts(), expected)
            self.limit.write_text("10500000\n")
            self.controller.tick()
            self.assertEqual(self.watts(), expected)

    def test_hot_cpu_lowers_limit_and_waits_for_cooling(self):
        self.profile = "performance"
        self.controller.tick()
        self.sensor.write_text("88000\n")
        self.controller.tick()
        self.assertEqual(self.watts(), 18)
        self.sensor.write_text("83000\n")
        self.controller.tick()
        self.assertEqual(self.watts(), 18)
        self.sensor.write_text("80000\n")
        self.controller.tick()
        self.assertEqual(self.watts(), 35)

    def test_hot_cpu_does_not_override_lower_firmware_limit(self):
        self.sensor.write_text("90000\n")
        self.controller.tick()
        self.assertEqual(self.watts(), 10.5)

    def test_missing_sensor_never_increases_limit(self):
        self.sensor.unlink()
        self.controller.tick()
        self.assertEqual(self.watts(), 10.5)
        self.limit.write_text("35000000\n")
        self.controller.tick()
        self.assertEqual(self.watts(), 18)

    def test_limit_is_clamped_to_hardware_maximum(self):
        self.profile = "performance"
        self.limit.with_name("constraint_0_max_power_uw").write_text("30000000\n")
        self.controller.tick()
        self.assertEqual(self.watts(), 30)

    def test_rejects_a_constraint_other_than_pl1(self):
        self.limit.with_name("constraint_0_name").write_text("short_term\n")
        with self.assertRaises(ValueError):
            self.controller.tick()
        self.assertEqual(self.watts(), 10.5)

    def test_dry_run_does_not_write(self):
        self.controller.dry_run = True
        self.controller.tick()
        self.assertEqual(self.watts(), 10.5)

    def test_stop_restores_initial_limit_but_respects_firmware_changes(self):
        self.controller.tick()
        self.controller.restore()
        self.assertEqual(self.watts(), 10.5)
        self.controller.tick()
        self.limit.write_text("12000000\n")
        self.controller.restore()
        self.assertEqual(self.watts(), 12)

    def test_stop_does_not_raise_limit_while_hot(self):
        self.limit.write_text("28000000\n")
        self.sensor.write_text("90000\n")
        self.controller.tick()
        self.assertEqual(self.watts(), 18)
        self.controller.restore()
        self.assertEqual(self.watts(), 18)

    def test_profile_query_failure_uses_power_saver(self):
        with patch.object(self.controller, "profile", wraps=Controller.profile.__get__(self.controller)):
            self.controller.tick()
        self.assertEqual(self.watts(), 18)


if __name__ == "__main__":
    unittest.main()

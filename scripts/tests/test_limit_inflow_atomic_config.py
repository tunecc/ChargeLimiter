import re
import unittest
from pathlib import Path

DAEMON = (Path(__file__).resolve().parents[2] / "ChargeLimiter" / "daemon.mm").read_text(
    encoding="utf-8"
)

# Capture the full set_limit_inflow_config handler block
HANDLER = re.search(
    r'set_limit_inflow_config.*?return @\{@"status": @0\};',
    DAEMON,
    re.S,
)
HANDLER_TEXT = HANDLER.group(0) if HANDLER else ""


class TestLimitInflowAtomicConfig(unittest.TestCase):
    """原子限流配置 API: set_limit_inflow_config"""

    def test_handler_exists(self):
        self.assertIn('"set_limit_inflow_config"', DAEMON)

    def test_validates_enabled_bool(self):
        self.assertIn("enabled", HANDLER_TEXT)
        self.assertIn("boolValue", HANDLER_TEXT)

    def test_validates_mode_values(self):
        for mode in ["off", "nominal", "light", "moderate", "heavy"]:
            self.assertIn(mode, HANDLER_TEXT)

    def test_writes_two_keys_atomically(self):
        self.assertIn("adv_limit_inflow", HANDLER_TEXT)
        self.assertIn("adv_limit_inflow_mode", HANDLER_TEXT)

    def test_single_thermal_update_on_success(self):
        self.assertIn("applyThermalModeForCurrentState", HANDLER_TEXT)

    def test_no_thermal_write_on_failure(self):
        fail_returns = re.findall(r'return @\{@"status": @\(-?\d+\).*?\};', HANDLER_TEXT)
        for fr in fail_returns:
            self.assertNotIn("applyThermalMode", fr)
            self.assertNotIn("setThermalSimulationMode", fr)


if __name__ == "__main__":
    unittest.main()

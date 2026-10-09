import re
import unittest
from pathlib import Path

VC = (
    Path(__file__).resolve().parents[2]
    / "ChargeLimiter"
    / "UIKit"
    / "Controllers"
    / "CLAdvancedSettingsViewController.m"
).read_text(encoding="utf-8")


class TestLimitInflowUIAtomic(unittest.TestCase):
    """充电时档位切换只调一次原子方法

    thermal-sim-settings 合并设置面后，原 limitInflowModeTapped: 更名为
    chargingThermalModeTapped:，且只写 adv_limit_inflow + adv_limit_inflow_mode
    这一组键，不触碰 adv_def_thermal_mode。
    """

    def test_calls_atomic_method(self):
        m = re.search(
            r"- \(void\)chargingThermalModeTapped:.*?\{(.*?)\n\}",
            VC,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertIn("setLimitInflowEnabled:", body)

    def test_does_not_call_setConfigWithKey_twice(self):
        m = re.search(
            r"- \(void\)chargingThermalModeTapped:.*?\{(.*?)\n\}",
            VC,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        count = body.count("setConfigWithKey:@\"adv_limit_inflow\"")
        self.assertEqual(count, 0, "不应再调 setConfigWithKey:@\"adv_limit_inflow\"")
        count = body.count("setConfigWithKey:@\"adv_limit_inflow_mode\"")
        self.assertEqual(count, 0, "不应再调 setConfigWithKey:@\"adv_limit_inflow_mode\"")

    def test_does_not_touch_idle_level(self):
        """充电时档位只写自己那组键，不污染平时档位"""
        m = re.search(
            r"- \(void\)chargingThermalModeTapped:.*?\{(.*?)\n\}",
            VC,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertNotIn("adv_def_thermal_mode", body)

    def test_idle_level_only_writes_its_own_key(self):
        """平时档位只写 adv_def_thermal_mode，不碰限流组"""
        m = re.search(
            r"- \(void\)idleThermalModeTapped:.*?\{(.*?)\n\}",
            VC,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertIn("adv_def_thermal_mode", body)
        self.assertNotIn("adv_limit_inflow", body)


if __name__ == "__main__":
    unittest.main()

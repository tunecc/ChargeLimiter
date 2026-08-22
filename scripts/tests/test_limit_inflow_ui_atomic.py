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
    """UI 限流切换只调一次原子方法"""

    def test_calls_atomic_method(self):
        m = re.search(
            r"- \(void\)limitInflowModeTapped:.*?\{(.*?)\n\}",
            VC,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertIn("setLimitInflowEnabled:", body)

    def test_does_not_call_setConfigWithKey_twice(self):
        m = re.search(
            r"- \(void\)limitInflowModeTapped:.*?\{(.*?)\n\}",
            VC,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        count = body.count("setConfigWithKey:@\"adv_limit_inflow\"")
        self.assertEqual(count, 0, "不应再调 setConfigWithKey:@\"adv_limit_inflow\"")
        count = body.count("setConfigWithKey:@\"adv_limit_inflow_mode\"")
        self.assertEqual(count, 0, "不应再调 setConfigWithKey:@\"adv_limit_inflow_mode\"")


if __name__ == "__main__":
    unittest.main()

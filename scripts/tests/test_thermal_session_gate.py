import re
import unittest
from pathlib import Path

DAEMON = Path(__file__).resolve().parents[2] / "ChargeLimiter" / "daemon.mm"
SRC = DAEMON.read_text(encoding="utf-8")


def func_body(name):
    m = re.search(rf"static [^\n=]*\b{name}\(.*?\n[^ ]*\}}", SRC, re.S)
    return m.group(0) if m else ""


class TestThermalSessionGate(unittest.TestCase):
    def test_charge_session_requires_adaptor(self):
        body = func_body("desiredThermalSimulationModeForCurrentState")
        # 适配器在位判定用 AdapterDetails（稳定物理信号），不用读 ExternalChargeCapable
        # 的旧路径（iOS17 锁屏/限流态下系统派生值会塌，见 test_thermal_lockscreen_hold.py）。
        # 断言剥离注释只看代码。
        import re as _re
        code = _re.sub(r"//[^\n]*", "", body)
        self.assertIn("AdapterDetails", code)
        self.assertNotIn("isAdaptorConnect", code)

    def test_charge_session_not_ischarging_only(self):
        body = func_body("desiredThermalSimulationModeForCurrentState")
        compact = re.sub(r"\s+", " ", body)
        self.assertNotIn(
            'safeInfo[@"IsCharging"] boolValue] || currentLooksCharging',
            compact,
        )

    def test_unplug_resets_charge_command(self):
        m = re.search(
            r"is_adaptor_new_disconnected\)\s*\{.*?updatePolicyRuntimeState",
            SRC,
            re.S,
        )
        self.assertIsNotNone(m)
        self.assertIn("g_chargeCommandEnabled = YES", m.group(0))


if __name__ == "__main__":
    unittest.main()

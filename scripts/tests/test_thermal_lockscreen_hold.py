import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DAEMON = (REPO / "ChargeLimiter" / "daemon.mm").read_text(encoding="utf-8")


def func_body(name):
    m = re.search(rf"static [^\n=]*\b{name}\(.*?\n[^ ]*\}}", DAEMON, re.S)
    return m.group(0) if m else ""


class TestThermalLockscreenHold(unittest.TestCase):
    """锁屏期限流自取消回归：desired 计算不得依赖锁屏态会抖动的派生信号。"""

    def test_desired_not_depend_on_isadaptorconnect(self):
        # isAdaptorConnect 读 ExternalChargeCapable（iOS17 系统派生值，限流态锁屏期会塌），
        # desired 计算不得用它判定适配器在位
        body = func_body("desiredThermalSimulationModeForCurrentState")
        self.assertNotIn("isAdaptorConnect", body)

    def test_desired_uses_adapter_details(self):
        # 适配器在位改用 AdapterDetails（存在且 Description != "batt"），禁流守卫已真机验证稳定
        body = func_body("desiredThermalSimulationModeForCurrentState")
        self.assertIn("AdapterDetails", body)
        self.assertIn("batt", body)

    def test_desired_keeps_unplug_fallback(self):
        # 未插电仍回退默认档，防 672ab65 修的"未插电持续写限流"回归
        body = func_body("desiredThermalSimulationModeForCurrentState")
        self.assertIn("defaultMode", body)

    def test_heavy_limit_threshold_linked(self):
        # 限流档（moderate/heavy）压制电流到 120mA 以下，充电判定须联动低阈值
        self.assertIn("kThermalLimitCurrentThresholdmA", DAEMON)
        body = func_body("desiredThermalSimulationModeForCurrentState")
        self.assertIn("thermalLimitCurrentThresholdForMode", body)
        helper = func_body("thermalLimitCurrentThresholdForMode")
        self.assertIn("kThermalLimitCurrentThresholdmA", helper)

    def test_sticky_hold_branch_exists(self):
        # 粘滞兜底：限流档已写入且无明确退出信号时不瞬时降档
        self.assertIn("g_thermalLimitActive", DAEMON)
        self.assertIn("thermal_session_sticky_hold", DAEMON)

    def test_downgrade_event_recorded(self):
        # desired 从限流档降为默认档时记录事件，真机可定位降档原因
        self.assertIn("thermal_desired_downgrade", DAEMON)


if __name__ == "__main__":
    unittest.main()

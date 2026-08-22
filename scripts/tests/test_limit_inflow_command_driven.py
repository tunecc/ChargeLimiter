import re
import unittest
from pathlib import Path

DAEMON = (Path(__file__).resolve().parents[2] / "ChargeLimiter" / "daemon.mm").read_text(
    encoding="utf-8"
)


class TestLimitInflowCommandDriven(unittest.TestCase):
    """集中决策函数只读命令+配置，不读系统信号"""

    def test_decision_function_exists(self):
        # 集中决策函数应在 daemon 中存在
        self.assertRegex(
            DAEMON,
            r"static\s+NSString\*\s+\w*[Tt]hermal\w*[Mm]ode\w*\s*\(.*?\)\s*\{",
            "应有集中决策函数",
        )

    def test_reads_charge_command_enabled(self):
        # 决策函数应读 g_chargeCommandEnabled
        m = re.search(
            r"static\s+NSString\*\s+\w*[Tt]hermal\w*[Mm]ode\w*\s*\(.*?\)\s*\{.*?\n\}",
            DAEMON,
            re.S,
        )
        if m:
            seg = m.group(0)
            self.assertIn("g_chargeCommandEnabled", seg)

    def test_reads_four_config_keys(self):
        m = re.search(
            r"static\s+NSString\*\s+\w*[Tt]hermal\w*[Mm]ode\w*\s*\(.*?\)\s*\{.*?\n\}",
            DAEMON,
            re.S,
        )
        if m:
            seg = m.group(0)
            for key in [
                "adv_limit_inflow",
                "adv_limit_inflow_mode",
                "adv_def_thermal_mode",
                "adv_thermal_mode_lock",
            ]:
                self.assertIn(key, seg)

    def test_does_not_read_system_signals(self):
        # 不应读取系统实时信号
        m = re.search(
            r"static\s+NSString\*\s+\w*[Tt]hermal\w*[Mm]ode\w*\s*\(.*?\)\s*\{.*?\n\}",
            DAEMON,
            re.S,
        )
        if m:
            seg = m.group(0)
            for signal in [
                "isAdaptorConnect",
                "AdapterDetails",
                "currentLooksCharging",
                "IsCharging",
                "ExternalChargeCapable",
            ]:
                self.assertNotIn(signal, seg)

    def test_onBatteryEventEnd_no_thermal_write(self):
        # onBatteryEventEnd 不应调 setThermalSimulationMode
        m = re.search(
            r"static\s+void\s+onBatteryEventEnd\(\)\s*\{(.*?)\n\}",
            DAEMON,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertNotIn("setThermalSimulationMode", body)

    def test_no_desired_sync_loop(self):
        # 不应存在 desired/sync 闭环
        self.assertNotIn("desiredThermalSimulationModeForCurrentState", DAEMON)
        self.assertNotIn("syncThermalSimulationModeForCurrentState", DAEMON)

    def test_no_self_heal_or_debounce(self):
        # 不应存在自愈定时器或去抖
        self.assertNotIn("g_thermalLimitActive", DAEMON)
        self.assertNotIn("thermal_desired_downgrade", DAEMON)
        self.assertNotIn("thermal_session_sticky_hold", DAEMON)


if __name__ == "__main__":
    unittest.main()

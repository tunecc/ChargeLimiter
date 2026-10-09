import re
import unittest
from pathlib import Path

DAEMON = (Path(__file__).resolve().parents[2] / "ChargeLimiter" / "daemon.mm").read_text(
    encoding="utf-8"
)


def function_source(name):
    m = re.search(
        r"static\s+[A-Za-z_]+\*?\s+" + re.escape(name) + r"\s*\(.*?\)\s*\{.*?\n\}",
        DAEMON,
        re.S,
    )
    return m.group(0) if m else ""


def decision_function_source():
    """集中决策相关的两个函数：充电时档位是否生效 + 目标档位选择

    thermal-sim-settings 把「插电 && 充电命令开 && 限流开启」这个共判据抽成了
    chargingThermalLevelAppliesNow()，目标档位选择与生效范围都复用它。
    这两个函数合起来才是完整的集中决策，单独看任何一个都会漏判据。
    """
    return function_source("chargingThermalLevelAppliesNow") + function_source(
        "targetThermalModeForCurrentState"
    )


class TestLimitInflowCommandDriven(unittest.TestCase):
    """集中决策函数只读命令+配置+连接信号，不读实时充电读数"""

    def test_decision_function_exists(self):
        # 集中决策函数应在 daemon 中存在
        self.assertRegex(
            DAEMON,
            r"static\s+NSString\*\s+\w*[Tt]hermal\w*[Mm]ode\w*\s*\(.*?\)\s*\{",
            "应有集中决策函数",
        )

    def test_reads_charge_command_enabled(self):
        # 决策函数应读 g_chargeCommandEnabled
        seg = decision_function_source()
        if seg:
            self.assertIn("g_chargeCommandEnabled", seg)

    def test_reads_config_keys(self):
        # thermal-sim-settings：退役 adv_thermal_mode_lock 后只剩三个配置键
        seg = decision_function_source()
        if seg:
            for key in [
                "adv_limit_inflow",
                "adv_limit_inflow_mode",
                "adv_def_thermal_mode",
            ]:
                self.assertIn(key, seg)
            self.assertNotIn(
                "adv_thermal_mode_lock",
                seg,
                "已退役的锁定键不得再出现在集中决策中",
            )

    def test_scope_shares_the_same_predicate(self):
        # 生效范围必须复用同一个判据函数，不能在 UI 侧形成第二套裁决真相
        self.assertIn("chargingThermalLevelAppliesNow", function_source("thermalScopeForCurrentState"))

    def test_requires_adaptor_connected_gate(self):
        # 限流档只在插电充电会话生效：决策函数必须经 isAdaptorConnect 做连接门控，
        # 未插电（含启动默认命令态、拔线重置态）恒为默认档
        seg = decision_function_source()
        if seg:
            self.assertIn("isAdaptorConnect", seg)

    def test_does_not_read_charging_readings(self):
        # 不应读取实时充电读数（电流/充电标志/派生值）；连接判定只允许经
        # isAdaptorConnect 封装，决策函数体内不得直接出现这些信号
        seg = decision_function_source()
        if seg:
            for signal in [
                "currentLooksCharging",
                "InstantAmperage",
                "IsCharging",
                "ExternalChargeCapable",
                "AdapterDetails",
            ]:
                self.assertNotIn(signal, seg)

    def test_policy_end_applies_thermal(self):
        # applyChargePolicy 末尾兜底同步 thermal 档位：覆盖拔线解除残留、
        # daemon 启动/重启对齐上次会话档位
        m = re.search(
            r"static\s+void\s+applyChargePolicy\([^;{]*\)\s*\{.*?\n\}",
            DAEMON,
            re.S,
        )
        self.assertIsNotNone(m)
        self.assertIn("applyThermalModeForCurrentState", m.group(0))

    def test_apply_is_idempotent(self):
        # 应用路径幂等：最近写入键缓存未变化时不重写偏好、不重发通知；
        # 还原链（restoreThermalSimulationForReset）清除缓存
        self.assertIn("g_lastAppliedThermalKey", DAEMON)
        self.assertIn("g_lastAppliedThermalKey = nil", DAEMON)

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

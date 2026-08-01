import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DAEMON_PATH = REPO_ROOT / "ChargeLimiter" / "daemon.mm"


class Ios17OverridePathsTests(unittest.TestCase):
    def setUp(self):
        self.source = DAEMON_PATH.read_text(encoding="utf-8")

    def test_smart_battery_manager_service_name(self):
        self.assertIn("AppleSmartBatteryManager", self.source)
        self.assertIn("CLSmartBatteryManagerServiceName", self.source)

    def test_gate_helpers_exist(self):
        for fn in ["CLIsIOS17OrLater", "CLCanUseOverrideChargeControl"]:
            self.assertIn(fn, self.source)

    def test_override_write_helper_signatures_exist(self):
        # Task 1 提供占位骨架（函数名存在即可）；真实实现与 key 字符串契约由 Task 2 测试覆盖。
        for fn in ["writeChargeStatusOverride", "setInflowStatusOverride"]:
            self.assertIn(fn, self.source)

    def test_override_write_sets_both_keys_with_same_value(self):
        # 源码里 writeChargeStatusOverride 必须同时写 ChargingOverride 与 PredictiveChargingInhibit
        # 且值来自同一个 stop 表达式（避免 split-brain）。
        src = self.source
        # 定位 writeChargeStatusOverride 函数体区间
        start = src.find("static kern_return_t writeChargeStatusOverride(io_service_t serv, BOOL stop)")
        end = src.find("static kern_return_t setInflowStatusOverride")
        body = src[start:end]
        self.assertIn("props[@\"ChargingOverride\"] = value;", body)
        self.assertIn("props[@\"PredictiveChargingInhibit\"] = value;", body)
        self.assertIn("NSNumber* value = @(stop ? YES : NO);", body)

    def test_inflow_override_uses_inflowoverride_key(self):
        start = self.source.find("static kern_return_t setInflowStatusOverride(io_service_t serv, BOOL flag)")
        body = self.source[start:start+600]
        self.assertIn("props[@\"InflowOverride\"] = @(flag ? YES : NO);", body)

    def test_getiopmpsserv_prefers_manager_on_ios17(self):
        src = self.source
        start = src.find("static io_service_t getIOPMPSServ()")
        end = src.find("static NSDictionary* getBatSlimInfo")
        body = src[start:end]
        self.assertIn("CLIsIOS17OrLater()", body)
        self.assertIn("CLSmartBatteryManagerServiceName().UTF8String", body)
        # 旧回退仍保留
        self.assertIn("AppleSmartBattery", body)
        self.assertIn("IOPMPowerSource", body)


    def test_setchargestatus_has_override_branch_and_legacy_fallback(self):
        start = self.source.find("static int setChargeStatus(BOOL flag)")
        end = self.source.find("static NSString* desiredThermalSimulationModeForCurrentState")
        if end < 0:
            end = self.source.find("static int setBatteryStatus")
        body = self.source[start:end if end > start else start + 1600]
        self.assertIn("CLCanUseOverrideChargeControl()", body)
        # polarity: setChargeStatus flag is charge-enabled; helper takes stop
        self.assertIn("writeChargeStatusOverride(serv, !flag)", body)
        self.assertNotIn("writeChargeStatusOverride(serv, flag)", body)
        # 旧回退仍在
        self.assertIn("shouldUsePredictiveInhibitChargePath()", body)
        self.assertIn("writeChargeStatus(serv, flag", body)

    def test_setchargestatus_override_polarity_and_state_sync(self):
        """Contract: override call uses !flag (stop) and syncs g_chargeCommandEnabled."""
        start = self.source.find("static int setChargeStatus(BOOL flag)")
        end = self.source.find("static NSString* desiredThermalSimulationModeForCurrentState")
        if end < 0:
            end = self.source.find("static int setBatteryStatus")
        self.assertGreater(start, -1)
        self.assertGreater(end, start)
        body = self.source[start:end]

        self.assertIn("writeChargeStatusOverride(serv, !flag)", body)
        # Must not pass charge-enabled flag directly as stop
        self.assertNotIn("writeChargeStatusOverride(serv, flag)", body)

        # Override success block must sync g_chargeCommandEnabled before early return
        override_idx = body.find("writeChargeStatusOverride(serv, !flag)")
        self.assertGreater(override_idx, -1)
        success_block = body[override_idx:]
        success_ret = success_block.find("return 0;")
        self.assertGreater(success_ret, -1)
        early_success = success_block[:success_ret]
        self.assertIn("g_chargeCommandEnabled = flag;", early_success)
        self.assertIn("g_lastChargeCommandTs = time(0);", early_success)

    def test_setinflowstatus_has_override_branch_and_legacy_fallback(self):
        start = self.source.find("static int setInflowStatus(BOOL flag)")
        body = self.source[start:start+1200]
        self.assertIn("CLCanUseOverrideChargeControl()", body)
        self.assertIn("setInflowStatusOverride(serv, flag)", body)
        # 旧 ExternalConnected 回退仍在
        self.assertIn("props[@\"ExternalConnected\"]", body)

    def test_probe_default_paths_include_override(self):
        start = self.source.find("static NSArray* CLProbeDefaultPaths(void)")
        body = self.source[start:start+400]
        for p in ["charging_override", "predictive_inhibit_override", "inflow_override"]:
            self.assertIn(f'@"{p}"', body)

    def test_probe_default_services_include_manager(self):
        start = self.source.find("static NSArray* CLProbeDefaultServices(void)")
        body = self.source[start:start+300]
        self.assertIn('@"AppleSmartBatteryManager"', body)

    def test_probe_write_path_handles_override(self):
        start = self.source.find("static kern_return_t CLProbeWritePath(")
        end = self.source.find("static NSDictionary* CLProbeRunOne")
        body = self.source[start:end]
        self.assertIn('@"charging_override"', body)
        self.assertIn('@"inflow_override"', body)
        self.assertIn("ChargingOverride", body)
        self.assertIn("InflowOverride", body)


if __name__ == "__main__":
    unittest.main()

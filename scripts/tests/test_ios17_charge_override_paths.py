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

    def test_override_write_sets_opposite_polarity_keys(self):
        # iOS17 可写入口：IsCharging + PredictiveChargingInhibit 极性相反
        start = self.source.find("static kern_return_t writeChargeStatusOverride(io_service_t serv, BOOL stop)")
        end = self.source.find("static kern_return_t setInflowStatusOverride")
        body = self.source[start:end]
        self.assertIn('props[@"IsCharging"] = @(stop ? NO : YES);', body)
        self.assertIn('props[@"PredictiveChargingInhibit"] = @(stop ? YES : NO);', body)
        # 不得再写 ChargingOverride 发布属性
        self.assertNotIn('ChargingOverride', body)


    def test_inflow_override_uses_fielddiags_keys(self):
        start = self.source.find("static kern_return_t setInflowStatusOverride(io_service_t serv, BOOL flag)")
        end = self.source.find("static io_service_t getIOPMPSServ")
        body = self.source[start:end]
        self.assertIn('FieldDiagsInflowInhibit', body)
        self.assertIn('OBCInflowInhibit', body)
        self.assertNotIn('InflowOverride', body)
        self.assertIn('NSNumber* inhibit = @(flag ? NO : YES);', body)


    def test_getiopmpsserv_read_path_not_manager(self):
        """Read path must publish battery props; Manager does not (capacity=0 bug)."""
        src = self.source
        start = src.find("static io_service_t getIOPMPSServ()")
        end = src.find("static NSDictionary* getBatSlimInfo")
        body = src[start:end]
        self.assertIn("AppleSmartBattery", body)
        self.assertIn("IOPMPowerSource", body)
        # Must NOT match Manager in the read-path function body
        self.assertNotIn("CLSmartBatteryManagerServiceName()", body)
        self.assertNotIn('IOServiceMatching("AppleSmartBatteryManager")', body)
        # iOS17 still prefers smart for read when available
        self.assertIn("CLIsIOS17OrLater()", body)

    def test_override_write_service_is_apple_smart_battery(self):
        self.assertIn("CLOverrideWriteServiceName", self.source)
        self.assertIn("CLCopyOverrideWriteService", self.source)
        start = self.source.find("static NSString* CLOverrideWriteServiceName(void)")
        body = self.source[start:start+200]
        self.assertIn('@"AppleSmartBattery"', body)

    def test_setchargestatus_writes_via_override_copy_service(self):
        start = self.source.find("static int setChargeStatus(BOOL flag)")
        end = self.source.find("static NSString* desiredThermalSimulationModeForCurrentState")
        if end < 0:
            end = start + 2500
        body = self.source[start:end]
        self.assertIn("CLCopyOverrideWriteService()", body)
        self.assertIn("writeChargeStatusOverride(overrideServ, !flag)", body)
        self.assertIn("IOObjectRelease(overrideServ)", body)
        # Must not write override using the read-path serv variable as sole target
        self.assertNotIn("writeChargeStatusOverride(serv, !flag)", body)


    def test_setchargestatus_has_override_branch_and_legacy_fallback(self):
        start = self.source.find("static int setChargeStatus(BOOL flag)")
        end = self.source.find("static NSString* desiredThermalSimulationModeForCurrentState")
        if end < 0:
            end = self.source.find("static int setBatteryStatus")
        body = self.source[start:end if end > start else start + 1600]
        self.assertIn("CLCanUseOverrideChargeControl()", body)
        # polarity: setChargeStatus flag is charge-enabled; helper takes stop
        self.assertIn("writeChargeStatusOverride(overrideServ, !flag)", body)
        self.assertNotIn("writeChargeStatusOverride(serv, flag)", body)
        self.assertNotIn("writeChargeStatusOverride(serv, !flag)", body)
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

        self.assertIn("writeChargeStatusOverride(overrideServ, !flag)", body)
        # Must not pass charge-enabled flag directly as stop, nor write via read-path serv
        self.assertNotIn("writeChargeStatusOverride(serv, flag)", body)
        self.assertNotIn("writeChargeStatusOverride(serv, !flag)", body)

        # Override success block must sync g_chargeCommandEnabled before early return
        override_idx = body.find("writeChargeStatusOverride(overrideServ, !flag)")
        self.assertGreater(override_idx, -1)
        success_block = body[override_idx:]
        success_ret = success_block.find("return 0;")
        self.assertGreater(success_ret, -1)
        early_success = success_block[:success_ret]
        self.assertIn("g_chargeCommandEnabled = flag;", early_success)
        self.assertIn("g_lastChargeCommandTs = time(0);", early_success)

    def test_setinflowstatus_has_override_branch_and_legacy_fallback(self):
        start = self.source.find("static int setInflowStatus(BOOL flag)")
        end = self.source.find("static BOOL isAdaptorConnect")
        if end < 0:
            end = start + 2500
        body = self.source[start:end]
        self.assertIn("CLCanUseOverrideChargeControl()", body)
        self.assertIn("setInflowStatusOverride(overrideServ, flag)", body)
        self.assertIn("CLCopyOverrideWriteService()", body)
        # 旧 ExternalConnected 回退仍在
        self.assertIn('props[@"ExternalConnected"]', body)

    def test_probe_default_paths_include_override(self):
        start = self.source.find("static NSArray* CLProbeDefaultPaths(void)")
        body = self.source[start:start+400]
        for p in ["charging_override", "predictive_inhibit_override", "inflow_override"]:
            self.assertIn(f'@"{p}"', body)

    def test_probe_default_services_include_manager(self):
        start = self.source.find("static NSArray* CLProbeDefaultServices(void)")
        body = self.source[start:start+400]
        self.assertIn('@"AppleSmartBatteryManager"', body)
        self.assertIn('@"AppleSmartBattery"', body)
        self.assertIn('@"IOPMPowerSource"', body)
        # auto must come first; AppleSmartBattery before Manager so write target is probed early
        auto_i = body.find('@"auto"')
        smart_i = body.find('@"AppleSmartBattery"')
        mgr_i = body.find('@"AppleSmartBatteryManager"')
        self.assertTrue(0 <= auto_i < smart_i < mgr_i)

    def test_probe_write_path_handles_override(self):
        start = self.source.find("static kern_return_t CLProbeWritePath(")
        end = self.source.find("static NSDictionary* CLProbeRunOne")
        body = self.source[start:end]
        self.assertIn('@"charging_override"', body)
        self.assertIn('@"inflow_override"', body)
        self.assertIn("IsCharging", body)
        self.assertIn("FieldDiagsInflowInhibit", body)
        self.assertNotIn('props[@"ChargingOverride"]', body)
        self.assertIn("OBCInflowInhibit", body)


if __name__ == "__main__":
    unittest.main()

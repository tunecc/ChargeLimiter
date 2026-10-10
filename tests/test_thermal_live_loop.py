"""fix-thermal-limit-live-loop 合约测试。

限流真机生效闭环与诚实状态面（design D1-D8 / delta spec thermal-simulation-apply）：
- D1/排障工具：dump_thermal（只读）与 thermal_selftest（写-读-恢复）CLI 动词；
  策略诊断页"导出诊断快照"（App 视角，不依赖 daemon）；tweak 生命周期 NSLog。
- D3/诊断数据源：仅限流模式下模拟配置档位源自会话通道内核态、模拟应用结果源自
  App 活探针（附来源与时间），daemon 遗留 KV 不再作为当前值；Powercuff 污染标注。
- D4/失败终态：15s 验证窗口状态机（verifying/applied/failed），窗口限定计时器，
  不依赖 CLBatteryInfoDidUpdateNotification（仅限流模式下该通知不会发出）。
- D5/重启重建：App 启动时仅限流模式且会话通道 enabled 位缺失 → 复用
  apply_limit_only verb 补写；失败入诊断 KV；每启动至多一次。
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"
TWEAK_M = ROOT / "ChargeLimiter" / "Tweak" / "CLThermalSimTweak.m"
BATTERY_M = ROOT / "ChargeLimiter" / "UIKit" / "CLBatteryManager.m"
BATTERY_H = ROOT / "ChargeLimiter" / "UIKit" / "CLBatteryManager.h"
SETTINGS_M = ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLSettingsViewController.m"
ADVANCED_M = ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLAdvancedSettingsViewController.m"
STRINGS_EN = ROOT / "ChargeLimiter" / "en.lproj" / "Localizable.strings"
STRINGS_ZH = ROOT / "ChargeLimiter" / "zh-Hans.lproj" / "Localizable.strings"


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated function: {signature}")


class KernelChannelHelperTests(unittest.TestCase):
    """1.1 内核态读取辅助（utils.mm/.h，App 与 daemon 共用）。"""

    @classmethod
    def setUpClass(cls):
        cls.utils = UTILS_MM.read_text()
        cls.header = UTILS_H.read_text()

    def test_helpers_declared_in_header(self):
        for decl in (
            "CLThermalReadApplyChannel",
            "CLThermalReadSessionChannel",
            "CLThermalModeName",
            "CLThermalExternalSimulationSource",
        ):
            self.assertIn(decl, self.header)

    def test_apply_channel_read_uses_notify_state(self):
        # 档位通道读取：token 注册（共享辅助，进程内一次）+ notify_get_state，只读
        reg = function_body(self.utils, "static BOOL CLThermalEnsureToken(const char* name, int* token) {")
        self.assertIn("notify_register_check", reg)
        body = function_body(self.utils, "BOOL CLThermalReadApplyChannel(uint64_t *mode) {")
        self.assertIn("CLThermalEnsureToken", body)
        self.assertIn("notify_get_state", body)
        self.assertNotIn("notify_set_state", body)

    def test_session_channel_decode(self):
        # 会话通道解码：enabled(bit0) | 充电时档位(bit8-15) | 平时档位(bit16-23)，与写方互逆
        body = function_body(self.utils,
                             "BOOL CLThermalReadSessionChannel(BOOL *enabled, uint64_t *chargeMode, uint64_t *idleMode) {")
        self.assertIn("(state >> 16) & 0xFF", body)
        self.assertIn("CLThermalEnsureToken", body)
        self.assertIn("notify_get_state", body)
        self.assertIn("& 1ULL", body)
        self.assertIn(">> 8", body)
        self.assertNotIn("notify_set_state", body)

    def test_mode_name_decoding(self):
        # 档位名解码：0-4 → off/nominal/light/moderate/heavy，未知按 off
        body = function_body(self.utils, "NSString *CLThermalModeName(uint64_t mode) {")
        for name in ("off", "nominal", "light", "moderate", "heavy"):
            self.assertIn(f'@"{name}"', body)

    def test_external_simulation_detection(self):
        # Powercuff 在场判据：其通道内核态非零 或 偏好文件存在；只读
        body = function_body(self.utils, "NSString *CLThermalExternalSimulationSource(void) {")
        self.assertIn("com.rpetrich.powercuff.thermals", body)
        self.assertIn("com.rpetrich.powercuff.plist", body)
        self.assertIn("@\"powercuff\"", body)
        self.assertNotIn("notify_set_state", body)


class ThermalPushWrapperTests(unittest.TestCase):
    """1.2 前置：写侧复用既有通路（不新增第二写路径）。"""

    @classmethod
    def setUpClass(cls):
        cls.utils = UTILS_MM.read_text()
        cls.header = UTILS_H.read_text()

    def test_wrapper_declared_and_reuses_existing_writer(self):
        self.assertIn("CLThermalPushApplyChannel", self.header)
        body = function_body(self.utils, "void CLThermalPushApplyChannel(NSString *mode) {")
        self.assertIn("CLPostThermalApplyNotification(mode)", body)
        self.assertNotIn("notify_set_state", body)  # 唯一写实现仍在 CLPostThermalApplyNotification


class DumpThermalVerbTests(unittest.TestCase):
    """1.2 dump_thermal 只读动词。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon = DAEMON_MM.read_text()

    def test_verb_branch_exists(self):
        self.assertIn('strcmp(argv[argIndex], "dump_thermal")', self.daemon)
        self.assertIn("dumpThermalDiagnostics()", self.daemon)

    def test_dump_output_fields(self):
        body = function_body(self.daemon, "static int dumpThermalDiagnostics(void) {")
        self.assertIn("CLThermalReadApplyChannel", body)
        self.assertIn("CLThermalReadSessionChannel", body)
        self.assertIn("getThermalSimulationMode()", body)      # 本进程热状态
        self.assertIn("getLimitOnlySessionEnabled()", body)    # 会话键
        self.assertIn("getLimitOnlyLevel()", body)
        self.assertIn("thermalSimulationLocked", body)         # 退役键残留检查
        self.assertIn("CLThermalExternalSimulationSource()", body)
        for field in ("apply_channel", "session_channel", "thermal_state", "prefs", "external_simulation"):
            self.assertIn(field, body)

    def test_dump_strictly_readonly(self):
        body = function_body(self.daemon, "static int dumpThermalDiagnostics(void) {")
        for banned in ("notify_set_state", "CLThermalPushApplyChannel", "setThermalSimulationMode",
                       "setLimitOnlySession", "CLPostThermalApplyNotification"):
            self.assertNotIn(banned, body)


class ThermalSelftestVerbTests(unittest.TestCase):
    """1.3 thermal_selftest 写-读-恢复动词。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon = DAEMON_MM.read_text()

    def test_verb_branch_exists(self):
        self.assertIn('strcmp(argv[argIndex], "thermal_selftest")', self.daemon)
        self.assertIn("runThermalSelftest(", self.daemon)

    def test_selftest_flow_order_and_restore(self):
        # 顺序：读原档位 → 写测试档 → 收敛等待 → 读回（内核+热状态）→ 恢复原档位 → 恢复读回验证
        body = function_body(self.daemon, "static int runThermalSelftest(NSString *mode) {")
        first_read = body.index("CLThermalReadApplyChannel")
        write = body.index("CLThermalPushApplyChannel")
        sleep = body.index("sleepForTimeInterval")
        readback = body.index("CLThermalReadApplyChannel", write)  # 写后第二次读
        restore = body.rindex("CLThermalPushApplyChannel")
        restore_verify = body.rindex("CLThermalReadApplyChannel")
        self.assertLess(first_read, write)
        self.assertLess(write, sleep)
        self.assertLess(sleep, readback)
        self.assertLess(readback, restore)
        self.assertLess(restore, restore_verify)  # 审查修复：恢复后读回验证（写应答≠写生效）
        self.assertIn("getThermalSimulationMode()", body)
        for field in ("kernel_readback", "thermal_followed", "restored", "restore_verified"):
            self.assertIn(field, body)

    def test_selftest_off_follow_semantics(self):
        # 审查修复：off 请求的跟随判定 = 热状态回 nominal（NSProcessInfo 无更低值域）
        body = function_body(self.daemon, "static int runThermalSelftest(NSString *mode) {")
        self.assertIn('isEqualToString:@"off"]', body)
        self.assertIn('isEqualToString:@"nominal"]', body)

    def test_selftest_validates_mode(self):
        body = function_body(self.daemon, "static int runThermalSelftest(NSString *mode) {")
        for valid in ("nominal", "light", "moderate", "heavy"):
            self.assertIn(f'@"{valid}"', body)
        self.assertIn("return -1", body)  # 非法档位拒绝
        self.assertIn("invalid_mode", body)  # 拒绝时 stdout 可见


class TweakLifecycleLogTests(unittest.TestCase):
    """1.4 执行端生命周期日志（零行为改动）。"""

    @classmethod
    def setUpClass(cls):
        cls.tweak = TWEAK_M.read_text()

    def test_ctor_logs_injection_and_registration(self):
        # ctor 记录：CommonProduct 类可用性、双通道注册结果、电池 interest 注册结果
        body = function_body(self.tweak, "__attribute__((constructor)) static void CLTSInit(void) {")
        self.assertIn("NSLog(", body)
        self.assertIn("productClass", body)

    def test_capture_logged(self):
        body = function_body(self.tweak, "static id CLTSInitProductOverride(id self, SEL _cmd, id data) {")
        self.assertIn("NSLog(", body)

    def test_apply_logs_mode(self):
        # 每次档位应用记录实际下发档位（注入是否发生的直接证据）
        body = function_body(self.tweak, "static void CLTSApplyThermals(void) {")
        self.assertIn("NSLog(", body)
        self.assertIn("CLTSStringForThermalMode(mode)", body)

    def test_logging_only_no_new_write_face(self):
        # 日志不引入新写面：ApplyThermals 仍无 notify_set_state / CFPreferences
        body = function_body(self.tweak, "static void CLTSApplyThermals(void) {")
        self.assertNotIn("notify_set_state", body)
        self.assertNotIn("CFPreferences", body)
        self.assertNotIn("NSUserDefaults", self.tweak)


class HonestDiagnosticsDataTests(unittest.TestCase):
    """2.1 诊断数据源（App 侧内核态派生 + 污染标注）。"""

    @classmethod
    def setUpClass(cls):
        cls.manager = BATTERY_M.read_text()
        cls.header = BATTERY_H.read_text()

    def test_helpers_extern_declared(self):
        for sym in ("CLThermalReadSessionChannel", "CLThermalModeName", "CLThermalExternalSimulationSource"):
            self.assertIn(sym, self.manager)

    def test_header_honest_diagnostics_properties(self):
        for prop in ("sessionChannelEnabled", "sessionChannelMode", "externalSimulationSource",
                     "thermalApplySource", "thermalApplyCheckedAt", "limitOnlyVerifyState"):
            self.assertIn(prop, self.header)

    def test_refresh_reads_channels_and_pollution(self):
        body = function_body(self.manager, "- (void)refreshDirectSessionState {")
        self.assertIn("CLThermalReadSessionChannel", body)
        self.assertIn("CLThermalExternalSimulationSource", body)

    def test_limit_only_derivation(self):
        # 仅限流模式：档位=会话通道内核态（enabled 在场时如实显示含 off；回退本地档位键）；
        # 应用结果=App 活探针；来源=app-probe；完整控制模式来源=daemon-probe（时间取 daemon KV）
        body = function_body(self.manager, "- (void)refreshLimitOnlyDiagnostics {")
        self.assertIn("CLOperationModeLimitOnly", body)
        self.assertIn("_sessionChannelMode", body)
        self.assertIn("limitOnlyActiveScope", body)
        self.assertIn("_sessionChannelIdleMode", body)
        # off 是合法档位值：回退链不得把 off 归一成 moderate（审查修复 1）
        self.assertNotIn('[_limitOnlyLevel isEqualToString:@"off"] ? @"moderate"', body)
        self.assertIn('"app-probe"', body)
        self.assertIn('"daemon-probe"', body)
        self.assertIn("_thermalApplyStatus = _limitOnlyApplied", body)
        # daemon-probe 口径不覆盖判定时间（时间来自 applyConfigData 解析的 daemon KV）
        self.assertLess(body.index('"daemon-probe"'), body.index("_thermalApplyCheckedAt"))

    def test_apply_config_parses_daemon_checked_at(self):
        # 审查修复 3：完整控制模式"最近判定时间"取 daemon 实际验证时间
        body = function_body(self.manager, "- (void)applyConfigData:(NSDictionary *)data {")
        self.assertIn('data[@"thermal_apply_checked_at"]', body)

    def test_derivation_called_from_refresh(self):
        body = function_body(self.manager, "- (void)refreshDirectSessionState {")
        self.assertIn("[self refreshLimitOnlyDiagnostics]", body)


class VerifyWindowStateTests(unittest.TestCase):
    """2.2 15s 验证窗口状态机（失败终态）。"""

    @classmethod
    def setUpClass(cls):
        cls.manager = BATTERY_M.read_text()
        cls.header = BATTERY_H.read_text()

    def test_window_constant(self):
        self.assertIn("CLLimitOnlyVerifyWindowSeconds = 15", self.manager)

    def test_state_enum_in_header(self):
        for name in ("CLLimitOnlyVerifyUnknown", "CLLimitOnlyVerifyVerifying",
                     "CLLimitOnlyVerifyApplied", "CLLimitOnlyVerifyFailed"):
            self.assertIn(name, self.header)

    def test_window_uses_own_timer_not_battery_notification(self):
        # D4 边界：仅限流模式下 CLBatteryInfoDidUpdateNotification 不会发出——
        # 窗口必须用自有计时器，不得注册该通知的观察者
        self.assertIn("_limitOnlyVerifyTimer", self.manager)
        self.assertNotIn("addObserver:self selector:@selector(tickLimitOnlyVerifyWindow", self.manager)

    def test_start_window_flow(self):
        body = function_body(self.manager, "- (void)startLimitOnlyVerifyWindow {")
        self.assertIn("CLLimitOnlyVerifyVerifying", body)
        self.assertIn("_limitOnlyVerifyIssuedAt", body)
        self.assertIn("timerWithTimeInterval:1.0", body)

    def test_tick_terminal_states(self):
        body = function_body(self.manager, "- (void)tickLimitOnlyVerifyWindow {")
        self.assertIn("refreshDirectSessionState", body)
        # 审查修复 2：拔线竞态守卫——refresh 内边沿已转移状态时本 tick 不得覆盖
        self.assertIn("_limitOnlyVerifyState != CLLimitOnlyVerifyVerifying", body)
        self.assertIn("CLLimitOnlyVerifyApplied", body)
        self.assertIn("CLLimitOnlyVerifyWindowSeconds", body)
        self.assertIn("CLLimitOnlyVerifyFailed", body)
        self.assertIn("stopLimitOnlyVerifyWindow", body)

    def test_dispatch_success_opens_window(self):
        body = function_body(self.manager,
                             "- (void)applyLimitOnlyLevelsWithChargeMode:(NSString *)chargeMode")
        self.assertIn("startLimitOnlyVerifyWindow", body)
        switch = function_body(self.manager, "- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {")
        self.assertIn("startLimitOnlyVerifyWindow", switch)

    def test_plug_edge_rearms_and_unplug_stops(self):
        body = function_body(self.manager, "- (void)refreshDirectSessionState {")
        self.assertIn("_previousDirectPlugConnected", body)
        self.assertIn("startLimitOnlyVerifyWindow", body)


class SessionStatusUITests(unittest.TestCase):
    """2.3 会话状态条三态化（可重试）+ 双语文案。"""

    @classmethod
    def setUpClass(cls):
        cls.settings = SETTINGS_M.read_text()
        cls.manager = BATTERY_M.read_text()
        cls.en = STRINGS_EN.read_text()
        cls.zh = STRINGS_ZH.read_text()

    def test_limit_only_rows_tri_state(self):
        body = function_body(self.settings, "- (void)updateLimitOnlyRows {")
        for state in ("CLLimitOnlyVerifyApplied", "CLLimitOnlyVerifyFailed", "CLLimitOnlyVerifyVerifying"):
            self.assertIn(state, body)
        self.assertIn("CLLimitOnlyVerifyFailed", body)

    def test_pollution_annotation_on_verify_card(self):
        body = function_body(self.settings, "- (void)updateLimitOnlyRows {")
        self.assertIn("externalSimulationSource", body)
        self.assertIn("可能受外部模拟污染", body)

    def test_failed_state_tap_retry(self):
        # 验证失败态点按卡片 → 重新下发两个档位（applyLimitOnlyLevelsWithChargeMode）
        self.assertIn("UITapGestureRecognizer", self.settings)
        retry = function_body(self.settings, "- (void)limitOnlyCardTapped {")
        self.assertIn("CLLimitOnlyVerifyFailed", retry)
        self.assertIn("applyLimitOnlyLevelsWithChargeMode", retry)

    def test_window_transitions_post_config_notification(self):
        # 窗口状态变化通知 UI 刷新（CLBatteryManager 自发）
        for sig in ("- (void)startLimitOnlyVerifyWindow {", "- (void)tickLimitOnlyVerifyWindow {"):
            body = function_body(self.manager, sig)
            self.assertIn("CLConfigDidUpdateNotification", body)

    def test_new_strings_bilingual(self):
        for key in ("已插电充电 · 验证失败，点按重试", "未充电 · 验证失败，点按重试",
                    "已插电充电 · 充电档位已关闭", "未充电 · 平时档位已关闭",
                    "验证失败", "验证中", "（可能受外部模拟污染）"):
            self.assertIn(key, self.zh)
            self.assertIn(key, self.en)


class DiagnosticsRowsTests(unittest.TestCase):
    """2.4 策略诊断行：来源标注 + 污染行 + 仅限流模式活数据。"""

    @classmethod
    def setUpClass(cls):
        cls.adv = ADVANCED_M.read_text()
        cls.en = STRINGS_EN.read_text()
        cls.zh = STRINGS_ZH.read_text()

    def test_update_values_refreshes_direct_state(self):
        body = function_body(self.adv, "- (void)updateDiagnosticValues {")
        self.assertIn("refreshDirectSessionState", body)

    def test_new_diagnostic_rows(self):
        for key in ("thermal_apply_source", "thermal_apply_checked_at", "external_simulation"):
            self.assertIn(f'key:@"{key}"', self.adv)

    def test_source_labels_derived(self):
        body = function_body(self.adv, "- (void)updateDiagnosticValues {")
        self.assertIn("thermalApplySource", body)
        self.assertIn("app-probe", body)
        self.assertIn("daemon-probe", body)
        self.assertIn("externalSimulationSource", body)

    def test_diagnostics_strings_bilingual(self):
        for key in ("应用结果来源", "App 探针", "daemon 探针", "外部模拟源", "最近判定时间"):
            self.assertIn(key, self.zh)
            self.assertIn(key, self.en)


class GetConfDiagnosticsTests(unittest.TestCase):
    """2.5 daemon get_conf 诊断 KV：来源与会话通道内核态。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon = DAEMON_MM.read_text()

    def test_get_conf_kv_source_and_channel(self):
        # kv 快照段：来源字段 + daemon 视角会话通道内核态
        self.assertIn('kv[@"thermal_apply_source"] = @"daemon-probe";', self.daemon)
        self.assertIn('kv[@"limit_only_session_channel"]', self.daemon)
        self.assertIn("CLThermalReadSessionChannel", self.daemon)


class ExportSnapshotTests(unittest.TestCase):
    """2.6 导出诊断快照（App 视角，不依赖 daemon）。"""

    @classmethod
    def setUpClass(cls):
        cls.adv = ADVANCED_M.read_text()
        cls.en = STRINGS_EN.read_text()
        cls.zh = STRINGS_ZH.read_text()

    def test_export_entry_button(self):
        self.assertIn("导出诊断快照", self.adv)
        self.assertIn("exportThermalDiagnosticsSnapshot", self.adv)

    def test_export_assembles_app_face(self):
        body = function_body(self.adv, "- (void)exportThermalDiagnosticsSnapshot {")
        for field in ("sessionChannelEnabled", "sessionChannelMode", "thermalApplySource",
                      "thermalApplyStatus", "externalSimulationSource", "limitOnlyVerifyState"):
            self.assertIn(field, body)
        # thermal_state 本进程活读（IntegrationReviewFixesTests.test_export_thermal_state_live_probe 覆盖）
        # apply 通道须内核态直读（raw+解码），非配置派生值
        self.assertIn("CLThermalReadApplyChannel", body)
        self.assertIn("CLThermalModeName(applyRaw)", body)
        # 审查修复 5：补写失败可见（快照含重建结果字段）
        self.assertIn("limitOnlyReestablishStatus", body)
        self.assertIn("UIActivityViewController", body)

    def test_reestablish_visible_in_diagnostics(self):
        # 审查修复 5：重建结果入策略诊断行
        self.assertIn('key:@"limit_only_reestablish"', self.adv)

    def test_export_writes_shareable_file(self):
        body = function_body(self.adv, "- (void)exportThermalDiagnosticsSnapshot {")
        self.assertIn("writeToFile", body)
        self.assertIn("App", body)  # 来源标注：App 视角

    def test_export_strings_bilingual(self):
        for key in ("导出诊断快照",):
            self.assertIn(key, self.zh)
            self.assertIn(key, self.en)


class RebootReestablishTests(unittest.TestCase):
    """3.1 App 启动时仅限流会话重建（已知限制 D4 收口）。"""

    @classmethod
    def setUpClass(cls):
        cls.manager = BATTERY_M.read_text()

    def test_method_exists_and_once_guard(self):
        body = function_body(self.manager, "- (void)reestablishLimitOnlySessionIfNeeded {")
        self.assertIn("_limitOnlyReestablishDone", body)

    def test_trigger_conditions(self):
        # 仅限流模式 且 会话通道内核态 enabled 缺失 → 复用既有 apply_limit_only verb
        body = function_body(self.manager, "- (void)reestablishLimitOnlySessionIfNeeded {")
        gate = body.index("CLOperationModeLimitOnly")
        spawn = body.index("apply_limit_only")
        self.assertLess(gate, spawn)  # spawn 只在门控内
        self.assertIn("_sessionChannelEnabled", body)

    def test_failure_recorded_not_blocking(self):
        body = function_body(self.manager, "- (void)reestablishLimitOnlySessionIfNeeded {")
        self.assertIn("limit_only_reestablish_status", body)
        self.assertIn("limit_only_reestablish_ts", body)

    def test_called_from_refresh_config(self):
        body = function_body(self.manager, "- (void)refreshConfig {")
        self.assertIn("reestablishLimitOnlySessionIfNeeded", body)


    def test_export_method_in_correct_class(self):
        # 崩溃回归（2026-10-05 真机 .ips）：导出按钮在 CLPolicyDiagnosticsViewController，
        # 方法曾误落到文件末尾的 CLAdvancedSettingsViewController → unrecognized selector SIGABRT。
        # 结构断言：方法必须位于策略诊断控制器的实现块内。
        src = ADVANCED_M.read_text()
        impl_policy = src.index("@implementation CLPolicyDiagnosticsViewController")
        impl_advanced = src.index("@implementation CLAdvancedSettingsViewController")
        method = src.index("- (void)exportThermalDiagnosticsSnapshot {")
        self.assertLess(impl_policy, method)
        self.assertLess(method, impl_advanced)
        # 按钮挂在策略诊断控制器内（其实现块中）
        button = src.index('action:@selector(exportThermalDiagnosticsSnapshot)')
        self.assertLess(impl_policy, button)
        self.assertLess(button, impl_advanced)


class RespringStaleClearTests(unittest.TestCase):
    """Bug A（2026-10-05 真机）：注销后未插电残留热模拟——ctor 须无条件会话评估。"""

    @classmethod
    def setUpClass(cls):
        cls.tweak = TWEAK_M.read_text()

    def test_ctor_unconditional_session_evaluate(self):
        # 注销（respring）不清内核态：apply 通道残留旧档位会被 initProduct 重放。
        # ctor 必须无条件评估会话（读内核态会话配置 + IOKit 插电判定），
        # 不能只在偏好可读的重挂路径里评估（偏好不可见 → 永不评估 → 残留）。
        body = function_body(self.tweak, "__attribute__((constructor)) static void CLTSInit(void) {")
        self.assertIn("CLTSSessionEvaluate();", body)
        # 评估调用必须在重挂（偏好读取）之外独立存在：出现 ≥ 2 次（重挂内 1 次 + 无条件 1 次）
        self.assertGreaterEqual(body.count("CLTSSessionEvaluate();"), 2)

    def test_power_check_either_key(self):
        # Bug B2：插电判定放宽——ExternalChargeCapable 与 ExternalConnected 任一为真即插电
        # （首插瞬间 capable 可能未发布，严格优先级会误判未插电 → 清掉限流）
        body = function_body(self.tweak, "static BOOL CLTSPowerConnected(void) {")
        self.assertIn("ExternalChargeCapable", body)
        self.assertIn("ExternalConnected", body)
        self.assertNotIn("if (val == NULL) {", body)  # 不再"capable 缺失才看 connected"

    def test_session_evaluate_logs_decision(self):
        # 取证：评估决策入日志（enabled/plugged/target）
        body = function_body(self.tweak, "static void CLTSSessionEvaluate(void) {")
        self.assertIn("NSLog(", body)


class VerifyWindowPlugGateTests(unittest.TestCase):
    """Bug B1（2026-10-05 真机）：未插电不得开验证窗口/显示验证失败。"""

    @classmethod
    def setUpClass(cls):
        cls.manager = BATTERY_M.read_text()
        cls.settings = SETTINGS_M.read_text()

    def test_window_gated_on_active_scope(self):
        # Bug B1（2026-10-05 真机）经 limit-only-idle-thermal-level 修订：门控判据从
        # "是否插电"改为"当前时段是否有档位"。未插电时验证对象是「平时档位」——
        # 平时档位非关闭就有对象，照常开窗；两侧皆关（scope=Off）才停窗回 Unknown。
        body = function_body(self.manager, "- (void)startLimitOnlyVerifyWindow {")
        self.assertIn("self.limitOnlyActiveScope == CLLimitOnlyScopeOff", body)
        self.assertIn("CLLimitOnlyVerifyUnknown", body)
        self.assertNotIn("if (!_directPlugConnected)", body)

    def test_no_target_scope_shows_unverified(self):
        # 没有待生效对象时生效验证恒显「未验证」。limit-only-idle-thermal-level 后判据是
        # "当前时段是否有档位"（scope=Off），不再是"是否插电"——平时档位生效时未插电也要验证。
        # 只锚 verifyText 那一段：会话状态 switch 里也有 Failed 分支，按出现次数数不可靠。
        body = function_body(self.settings, "- (void)updateLimitOnlyRows {")
        verify_section = body[body.index("NSString *verifyText;"):]
        guard = verify_section.index("if (manager.limitOnlyActiveScope == CLLimitOnlyScopeOff)")
        self.assertLess(guard, verify_section.index("CLLimitOnlyVerifyFailed"))
        self.assertIn('verifyText = CLL(@"未验证");', verify_section[guard:])

    def test_plug_edge_reissues_session_apply(self):
        # Bug B2 自愈：App 观察到插电边沿（仅限流模式）时重下发会话一次，不依赖 tweak 边沿
        body = function_body(self.manager, "- (void)refreshDirectSessionState {")
        edge = body[body.index("_previousDirectPlugConnected != _directPlugConnected"):]
        self.assertIn("applyLimitOnlyLevelsWithChargeMode", edge)
        # limit-only-idle-thermal-level：边沿从"插电/拔线"扩为"生效时段翻转"，
        # 但只有插拔边沿才自愈重下发（IsCharging 抖动不 spawn 一次性 root 进程）
        self.assertIn("scopeChanged", body)
        self.assertIn("if (plugEdge)", body)


class IntegrationReviewFixesTests(unittest.TestCase):
    """Verify 集成审查修复（2026-10-05）：导出热状态活读、token 复用、顺序/门控/手势修正。"""

    @classmethod
    def setUpClass(cls):
        cls.adv = ADVANCED_M.read_text()
        cls.manager = BATTERY_M.read_text()
        cls.settings = SETTINGS_M.read_text()
        cls.utils = UTILS_MM.read_text()

    def test_export_thermal_state_live_probe(self):
        # IMPORTANT：导出快照 thermal_state 须本进程活读（daemon 镜像键在仅限流模式恒 off）
        body = function_body(self.adv, "- (void)exportThermalDiagnosticsSnapshot {")
        self.assertIn("NSProcessInfo", body)
        self.assertNotIn("manager.thermalSimulateMode", body)

    def test_external_source_reuses_static_token(self):
        # MINOR：污染检测 token 复用（1Hz tick 场景不得每次注册泄漏）
        body = function_body(self.utils, "NSString *CLThermalExternalSimulationSource(void) {")
        self.assertIn("CLThermalEnsureToken", body)
        self.assertIn("static int token = -1;", body)

    def test_switch_aligns_mode_before_refresh(self):
        # MINOR：先对齐内存模式再刷新——插电边沿以新派生模式判定（防窄窗口会话复活竞态）
        body = function_body(self.manager, "- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {")
        self.assertLess(body.index("alignModeStateInMemory"), body.index("refreshDirectSessionState"))

    def test_apply_failure_does_not_open_window(self):
        # MINOR：下发失败（rc!=0）不开验证窗——"下发失败"不混入"探针超窗"终态
        body = function_body(self.manager,
                             "- (void)applyLimitOnlyLevelsWithChargeMode:(NSString *)chargeMode")
        self.assertLess(body.index("if (ok) {"), body.index("startLimitOnlyVerifyWindow"))
        # limit-only-idle-thermal-level A9/A19：失败时内存与本地 KV 一起回滚
        self.assertIn("previousCharge", body)

    def test_refresh_failure_observes_direct_state(self):
        # MINOR：daemon 死亡路径复用既有 1s 刷新链观察插拔边沿（仅限流模式，无新增常驻轮询）
        body = function_body(self.manager, "- (void)refreshBatteryInfo {")
        err = body.index("if (error || !response) {")
        seg = body[err:body.index("NSDictionary *data")]
        self.assertIn("refreshDirectSessionState", seg)
        self.assertIn("CLOperationModeLimitOnly", seg)

    def test_retry_gesture_on_verify_row_not_card(self):
        # MINOR：重试手势挂"生效验证"行（整卡手势与档位行选择器嵌套）
        src = self.settings
        self.assertIn("verifyRow", src)
        card_tap = "[self.limitOnlyCard addGestureRecognizer"
        self.assertNotIn(card_tap, src)


class EdgeReliabilityTests(unittest.TestCase):
    """thermal-limit-edge-reliability：IOPS 边沿 + dealloc 卫生 + 自持重申 + App 拔电重下发。"""

    @classmethod
    def setUpClass(cls):
        cls.tweak = TWEAK_M.read_text()
        cls.manager = BATTERY_M.read_text()

    def test_iops_notification_registered(self):
        # HIPCharge 同款原语：IOPS 电源源通知挂主 runloop，回调触发会话重算
        self.assertIn("IOPSNotificationCreateRunLoopSource", self.tweak)
        body = function_body(self.tweak, "static void CLTSPowerSourceChanged(void *context) {")
        self.assertIn("CLTSSessionEvaluate();", body)

    def test_dealloc_clears_capture(self):
        # break98pl 同款：产品对象释放时清空捕获（防僵尸下发）
        body = function_body(self.tweak, "static void CLTSDeallocOverride(id self, SEL _cmd) {")
        self.assertIn("CLTSCurrentProduct = nil", body)
        self.assertIn("CLTSOrigDealloc", body)
        self.assertIn('CLTSHookSelector(productClass, sel_registerName("dealloc")', self.tweak)

    def test_reassert_timer_gated(self):
        # 30s watchdog（Verifier 失败轮修订）：门控=会话启用即运行（不再依赖插电/档位/捕获）；
        # 每次 tick 做完整会话重评估（重读插电态→应用或清除→刷新门控）——拔电/注销后
        # 边沿失灵时 30s 内必然收敛，杜绝盲重放钉死旧档位。
        body = function_body(self.tweak, "static void CLTSUpdateReassertTimer(void) {")
        self.assertIn("CLTSSessionConfig", body)
        self.assertIn("BOOL shouldRun = enabled;", body)
        self.assertIn("30 * NSEC_PER_SEC", body)
        handler = body[body.index("dispatch_source_set_event_handler"):]
        self.assertIn("CLTSSessionEvaluate();", handler)  # tick=完整重评估，非盲重放
        self.assertNotIn("notify_set_state", handler)  # handler 自身不写通道（评估函数才写）

    def test_ctor_logs_iops_registration(self):
        body = function_body(self.tweak, "__attribute__((constructor)) static void CLTSInit(void) {")
        self.assertIn("CLTSPowerSourceRef", body)

    def test_gate_refresh_precedes_early_return(self):
        # Verifier risks 修复：门控刷新必须先于会话禁用早退——否则 enabled→disabled
        # 切换后 30s 定时器空转不停（tick 早退无写入但不卫生）
        body = function_body(self.tweak, "static void CLTSSessionEvaluate(void) {")
        self.assertLess(body.index("CLTSUpdateReassertTimer();"),
                        body.index("if (!CLTSSessionConfig(&charge, &idle)) return;"))

    def test_app_unplug_edge_reissues(self):
        # App 侧纵深：插拔边沿都经 CLI 重下发（verb 按当前插电/充电态裁决目标档位）
        body = function_body(self.manager, "- (void)refreshDirectSessionState {")
        edge = body[body.index("_previousDirectPlugConnected != _directPlugConnected"):]
        # limit-only-idle-thermal-level：不再区分插电/拔线两个分支各自重下发，
        # 统一走 plugEdge 一次；tweak 侧按会话配置自行裁决两个档位
        self.assertIn("if (plugEdge)", edge)
        self.assertIn("applyLimitOnlyLevelsWithChargeMode", edge)


if __name__ == "__main__":
    unittest.main()

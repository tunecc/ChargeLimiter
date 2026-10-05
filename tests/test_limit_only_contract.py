"""limit-only-daemon-free 合约测试。

仅限流模式（三态主开关的一态）= 只保留充电限流，daemon 零驻留（spec B1-B7）：
- B2：CLThermalSim tweak 会话执行（thermal-sim-mikasa-rewrite 重写）——档位经
  内核 notify state 双通道（apply=档位 0-4 / session=enabled+档位编码），
  thermalmonitord 内零运行时偏好读取（真机实证偏好跨进程不可见）；
  仅 hook initProduct:（强引用捕获，Mikasa 同款），无缓解链路 hook；
  电池 interest + 会话通道通知驱动插拔边沿（插电档/拔线 off）；
  进程启动单次 best-effort 读会话偏好做跨重启重挂。
- B3：daemon 一次性 CLI 动词 apply_limit_only——写会话键（记录面）+ 双通道
  内核态推送 + 通知即退，不启动 HTTP/策略循环。
- B4：master-off 还原 carve-out——limit_only 模式下 thermal 会话键不被还原清除；
  enable=YES 防御清理回收会话键；PPM 复位随 PPM 面退役移除。
- B1/B5：白名单放行 limit_only_mode；App 三态主开关 + 状态条 + 置灰门控 +
  限流卡片；档位写入走一次性 root 进程（spawnDaemonCLIVerb_C），daemon 不驻留；
  切换成功后内存模式状态先同步再发通知（operation-mode-live-refresh M1）。
- B1 修订（fix-limit-only-restart-state）：切换先落盘模式标志与归一化档位
  （off/未设置→moderate），再 enable=NO，最后 CLI；CLI 失败重试一次且 UI 弹窗
  可见；applyConfigData 忽略 "off" 档、初始 moderate；共享配置 plist 写经
  flock 跨进程串行（utils writeMergedConfigDictionaryToDisk 单一收口）。
- B7：tweak 打包链接 IOKit.tbd。
- fix-thermal-limit-stuck-verifying：安装后 killall thermalmonitord（三形态 postinst，
  升级即时换掉内存中旧版 tweak）；退役键随写清洗（thermalSimulationLocked /
  ppmSimulationMode 残留会让旧版已注入 tweak 保持屏蔽/低温模拟）。
- thermal-sim-mikasa-rewrite：生效通路改内核 notify state（thermalmonitord 内
  CFPreferences 读不到 root 写入，真机实证；Mikasa fork 同机生效）。
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"
TWEAK_M = ROOT / "ChargeLimiter" / "Tweak" / "CLThermalSimTweak.m"
BUILD_SH = ROOT / "scripts" / "build_packages.sh"
POSTINST_ROOTFUL = ROOT / "ChargeLimiter" / "Package" / "DEBIAN" / "postinst"
POSTINST_ROOTLESS = ROOT / "ChargeLimiter" / "Package_rootless" / "DEBIAN" / "postinst"
POSTINST_ROOTHIDE = ROOT / "ChargeLimiter" / "Package_roothide" / "DEBIAN" / "postinst"
BATTERY_M = ROOT / "ChargeLimiter" / "UIKit" / "CLBatteryManager.m"
BATTERY_H = ROOT / "ChargeLimiter" / "UIKit" / "CLBatteryManager.h"
SETTINGS_M = ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLSettingsViewController.m"
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


class TweakSessionContractTests(unittest.TestCase):
    """B2：CLThermalSim 会话执行端（Mikasa 机制重写）。"""

    @classmethod
    def setUpClass(cls):
        cls.tweak = TWEAK_M.read_text()

    def test_session_keys_only_used_for_boot_restore(self):
        # 会话偏好键仅出现在跨重启重挂函数（进程启动单次读取）
        restore = function_body(self.tweak, "static void CLTSRestoreSessionFromPrefs(void) {")
        self.assertIn('CFSTR("clLimitSessionEnabled")', restore)
        self.assertIn('CFSTR("clLimitMode")', restore)

    def test_zero_runtime_pref_reads(self):
        # thermal-sim-mikasa-rewrite A1：运行时零偏好读取——CFPreferences 仅在重挂函数
        restore = function_body(self.tweak, "static void CLTSRestoreSessionFromPrefs(void) {")
        total = self.tweak.count("CFPreferencesCopyAppValue")
        self.assertEqual(total, restore.count("CFPreferencesCopyAppValue"))
        self.assertNotIn("NSUserDefaults", self.tweak)

    def test_apply_reads_kernel_state_only(self):
        # 档位唯一读取源 = 档位通道 notify_get_state；off 也下发
        body = function_body(self.tweak, "static void CLTSApplyThermals(void) {")
        self.assertIn("notify_get_state", body)
        self.assertIn("putDeviceInThermalSimulationMode:", body)
        self.assertNotIn("CFPreferences", body)

    def test_dual_channels_registered(self):
        # ctor 双通道 notify_register_dispatch（主队列）
        self.assertIn('notify_register_dispatch([CLTSApplyNotification UTF8String]', self.tweak)
        self.assertIn('notify_register_dispatch([CLTSSessionNotification UTF8String]', self.tweak)
        self.assertIn("dispatch_get_main_queue()", self.tweak)

    def test_only_initproduct_hook(self):
        # hook 面（thermal-limit-edge-reliability 修订）：initProduct: + dealloc（捕获卫生），
        # 仍无缓解链路 hook
        self.assertEqual(self.tweak.count("CLTSHookSelector(productClass"), 2)
        self.assertIn("CLTSHookSelector(productClass, @selector(initProduct:)", self.tweak)
        self.assertIn('CLTSHookSelector(productClass, sel_registerName("dealloc")', self.tweak)
        for sel in ("tryTakeAction", "simulateLightThermalPressure", "updatePowerzoneTelemetry"):
            self.assertNotIn(sel, self.tweak)

    def test_strong_product_capture(self):
        # 强引用捕获（Mikasa 同款，非 __weak）
        self.assertIn("static id CLTSCurrentProduct = nil;", self.tweak)
        self.assertNotIn("__weak", self.tweak)
        body = function_body(self.tweak, "static id CLTSInitProductOverride(id self, SEL _cmd, id data) {")
        self.assertIn("CLTSCurrentProduct = result;", body)
        self.assertIn("CLTSApplyThermals();", body)  # 重启重放：内核态即真相

    def test_session_evaluate_kernel_edges(self):
        # 会话边沿：读会话通道 + IOKit 插电判定；未启用不动档位通道（daemon 独写）
        body = function_body(self.tweak, "static void CLTSSessionEvaluate(void) {")
        self.assertIn("CLTSSessionConfig", body)
        self.assertIn("if (!CLTSSessionConfig(&limit)) return;", body)
        self.assertIn("CLTSPowerConnected()", body)
        self.assertIn("notify_set_state", body)
        self.assertIn("CLTSApplyThermals();", body)
        self.assertNotIn("CFPreferences", body)

    def test_session_channel_encoding(self):
        # 会话通道编码：enabled(bit0) | 档位值(bit8-15)
        body = function_body(self.tweak, "static BOOL CLTSSessionConfig(uint64_t *limitMode) {")
        self.assertIn("(state >> 8) & 0xFF", body)
        self.assertIn("(state & 1ULL) != 0", body)

    def test_powercuff_mode_encoding(self):
        # Powercuff 编码：1=nominal/2=light/3=moderate/4=heavy，其余 off
        body = function_body(self.tweak, "static uint64_t CLTSModeValueForString(NSString *mode) {")
        self.assertIn('return 1;', body)
        self.assertIn('return 2;', body)
        self.assertIn('return 3;', body)
        self.assertIn('return 4;', body)

    def test_no_low_temp_ppm_simulation(self):
        # 低温/PPM 模拟不在执行端
        self.assertNotIn("putDeviceInLowTempSimulationMode", self.tweak)
        self.assertNotIn("ppmSimulationMode", self.tweak)

    def test_plug_predicate_prefers_external_charge_capable(self):
        body = function_body(self.tweak, "static BOOL CLTSPowerConnected(void) {")
        self.assertIn('"ExternalChargeCapable"', body)
        self.assertIn('"ExternalConnected"', body)  # 回退键

    def test_battery_interest_notification_registered(self):
        # 插拔边沿主触发：AppleSmartBattery interest 通知
        self.assertIn('IOServiceMatching("AppleSmartBattery")', self.tweak)
        self.assertIn("IOServiceAddInterestNotification", self.tweak)
        self.assertIn('"IOServiceInterestNotifications"', self.tweak)
        self.assertIn("CLTSBatteryInterestCallback", self.tweak)

    def test_no_periodic_timer_added(self):
        # 无定时器：触发 = 通知 + 电池 interest + initProduct 重放
        self.assertNotIn("NSTimer", self.tweak)
        self.assertNotIn("dispatch_after", self.tweak)


class DaemonCLIVerbContractTests(unittest.TestCase):
    """B3：apply_limit_only 一次性动词。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon = DAEMON_MM.read_text()

    def test_verb_defined(self):
        self.assertIn('"apply_limit_only"', self.daemon)

    def test_verb_writes_session_and_exits(self):
        start = self.daemon.index('"apply_limit_only"')
        segment = self.daemon[start:start + 2200]
        self.assertIn("setLimitOnlySession(enabled, mode, plugged)", segment)
        self.assertIn("return 0;", segment)
        # 不启动服务：动词段不得落入 [Service.inst serve]
        self.assertNotIn("[Service.inst serve]", segment)

    def test_verb_validates_mode(self):
        start = self.daemon.index('"apply_limit_only"')
        segment = self.daemon[start:start + 2200]
        for mode in ("nominal", "light", "moderate", "heavy"):
            self.assertIn(mode, segment)


class RestoreCarveOutContractTests(unittest.TestCase):
    """B4：master-off 还原 carve-out 与防御清理。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon = DAEMON_MM.read_text()

    def test_thermal_restore_gated_on_limit_only(self):
        body = function_body(self.daemon, "static void restoreThermalSimulationForReset(void) {")
        self.assertIn('getLocalBool(@"limit_only_mode", NO)', body)
        self.assertIn("getLimitOnlySessionEnabled()", body)
        self.assertIn("setThermalSimulationMode(@\"off\");", body)

    def test_ppm_restore_removed(self):
        # PPM 面整体退役（fix-thermal-limit-powercuff A3）：还原路径无 PPM 归零调用
        body = function_body(self.daemon, "static void restoreThermalSimulationForReset(void) {")
        self.assertNotIn("setPPMSimulationMode", body)
        self.assertNotIn("ppmSimulationMode", body)
        # carve-out 语义保留：gate 只包裹 thermal 归零
        gate_pos = body.index("getLimitOnlySessionEnabled()")
        thermal_pos = body.index("setThermalSimulationMode")
        self.assertLess(gate_pos, thermal_pos)

    def test_no_ppm_api_surface(self):
        # ppm_simulate_mode 处理与诊断随 PPM 面退役
        self.assertNotIn("ppm_simulate_mode", self.daemon)
        self.assertNotIn("setPPMSimulationMode", self.daemon)
        self.assertNotIn("getPPMSimulationMode", self.daemon)

    def test_full_control_cleanup_clears_session_keys(self):
        # enable=YES：回收会话键 + 模式标志（完整控制与 tweak 会话不得同时管理 thermal）
        self.assertIn("clearLimitOnlySessionKeys();", self.daemon)
        body = function_body(self.daemon, "    g_enable = getLocalBool(@\"enable\", YES);")
        self.assertIn("clearLimitOnlySessionKeys();", body)
        self.assertIn('setLocalBool(@"limit_only_mode", NO);', body)

    def test_boot_cleanup_only_when_enabled(self):
        # g_enable=NO（master-off / 仅限流非驻留形态）不得清理会话
        pos = self.daemon.index('g_enable = getLocalBool(@"enable", YES);')
        segment = self.daemon[pos:pos + 400]
        self.assertIn("if (g_enable) {", segment)
        self.assertIn("clearLimitOnlySessionKeys();", segment)


class WhitelistContractTests(unittest.TestCase):
    """B1/B5：master-off 白名单放行模式标志键。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon = DAEMON_MM.read_text()

    def test_limit_only_mode_allowed_in_gate(self):
        body = function_body(self.daemon, "static NSDictionary* CLMasterOffGateRequest(NSString* api, NSDictionary* nsreq) {")
        self.assertIn('@"limit_only_mode"', body)

    def test_session_diagnostics_in_get_conf(self):
        self.assertIn('kv[@"limit_only_session_enabled"]', self.daemon)
        self.assertIn('kv[@"limit_only_level"]', self.daemon)


class UtilsSessionContractTests(unittest.TestCase):
    """共享层：会话键读写、插电判定、镜像语义。"""

    @classmethod
    def setUpClass(cls):
        cls.utils = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def test_c_linkage_exports(self):
        # App（.m）需要 C 链接符号
        self.assertIn("extern \"C\" {", self.utils_h)
        self.assertIn("spawnDaemonCLIVerb_C", self.utils_h)
        self.assertIn("setLimitOnlySession", self.utils_h)

    def test_set_limit_only_session_writes_mirror(self):
        body = function_body(self.utils, "void setLimitOnlySession(BOOL enabled, NSString* mode, BOOL plugged) {")
        self.assertIn('"thermalSimulationMode"', body)
        self.assertIn("CLPostThermalSessionNotification(enabled, mode);", body)
        self.assertIn("CLPostThermalApplyNotification(", body)

    def test_kernel_state_push_on_writers(self):
        # thermal-sim-mikasa-rewrite A2：档位通道 notify_set_state（Powercuff 编码）+ 广播
        body = function_body(self.utils, "static void CLPostThermalApplyNotification(NSString* mode) {")
        self.assertIn("notify_register_check", body)
        self.assertIn("notify_set_state(token, CLThermalModeValue(mode));", body)
        self.assertIn("CFNotificationCenterPostNotification", body)
        # 会话通道编码：enabled(bit0) | 档位值(bit8-15)
        session = function_body(self.utils, "static void CLPostThermalSessionNotification(BOOL enabled, NSString* mode) {")
        self.assertIn("(enabled ? 1ULL : 0ULL) | (CLThermalModeValue(mode) << 8)", session)
        # 三个写入路径全部推送内核态
        thermal = function_body(self.utils, "void setThermalSimulationMode(NSString* mode) {")
        self.assertIn("CLPostThermalApplyNotification(mode);", thermal)
        clear = function_body(self.utils, "void clearLimitOnlySessionKeys() {")
        self.assertIn("CLPostThermalSessionNotification(NO, @\"off\");", clear)
        self.assertIn("CLPostThermalApplyNotification(@\"off\");", clear)

    def test_disable_resets_mirror_off(self):
        body = function_body(self.utils, "void setLimitOnlySession(BOOL enabled, NSString* mode, BOOL plugged) {")
        self.assertIn('setObject:@"off" forKey:@"thermalSimulationMode"', body)

    def test_no_ppm_and_lock_mirror_in_utils(self):
        # locked 镜像与 PPM 帮助函数退役（fix-thermal-limit-powercuff A2/A3/D3）：
        # 退役键不得有任何写入（setObject/setValue），只允许清洗路径移除
        for line in self.utils.splitlines():
            if "setObject" in line or "setValue" in line:
                self.assertNotIn("thermalSimulationLocked", line)
                self.assertNotIn("ppmSimulationMode", line)
        self.assertNotIn("setPPMSimulationMode", self.utils)
        self.assertNotIn("getPPMSimulationMode", self.utils)
        self.assertNotIn("PPMSimulationMode", self.utils_h)

    def test_retired_keys_scrubbed_on_mirror_writes(self):
        # fix-thermal-limit-stuck-verifying A2：随写清洗升级残留（旧版 tweak 的
        # thermalSimulationLocked=YES 会保持屏蔽行为，ppmSimulationMode 同类）
        scrub = function_body(self.utils, "static void CLScrubRetiredThermalKeys(NSUserDefaults* defs) {")
        self.assertIn('removeObjectForKey:@"thermalSimulationLocked"', scrub)
        self.assertIn('removeObjectForKey:@"ppmSimulationMode"', scrub)
        for sig in ("void setThermalSimulationMode(NSString* mode) {",
                    "void setLimitOnlySession(BOOL enabled, NSString* mode, BOOL plugged) {",
                    "void clearLimitOnlySessionKeys() {"):
            body = function_body(self.utils, sig)
            self.assertIn("CLScrubRetiredThermalKeys(defs);", body)
            self.assertIn("synchronize", body)

    def test_shared_config_write_serialized(self):
        # 共享配置 plist 读-合并-写全程持跨进程排它 flock（fix-limit-only-restart-state B8 单一收口）
        # wrapper 定义前有前向声明，不能用 function_body 锚定，改全文件顺序断言
        lock_call = self.utils.index("int lockFd = acquireConfigWriteLock(lockPath);")
        locked_call = self.utils.index("writeMergedConfigDictionaryToDiskLocked(fallbackPreferences,")
        unlock_call = self.utils.index("releaseConfigWriteLock(lockFd);")
        self.assertLess(lock_call, locked_call)
        self.assertLess(locked_call, unlock_call)
        helper = function_body(self.utils, "static int acquireConfigWriteLock(NSString* lockPath) {")
        self.assertIn("flock(fd, LOCK_EX)", helper)
        self.assertIn("O_RDWR | O_CREAT, 0666", helper)

    def test_clear_removes_session_keys(self):
        body = function_body(self.utils, "void clearLimitOnlySessionKeys() {")
        self.assertIn("removeObjectForKey:", body)

    def test_blocking_spawn_helper(self):
        body = function_body(self.utils, "int spawnDaemonCLIVerb_C(NSArray<NSString*>* verbArgs) {")
        self.assertIn("spawn(argv", body)
        self.assertNotIn("SPAWN_FLAG_NOWAIT", body)  # 阻塞式等待动词退出


class AppContractTests(unittest.TestCase):
    """B5：三态主开关、门控、档位写入路径。"""

    @classmethod
    def setUpClass(cls):
        cls.manager_m = BATTERY_M.read_text()
        cls.manager_h = BATTERY_H.read_text()
        cls.settings = SETTINGS_M.read_text()

    def test_operation_mode_enum(self):
        self.assertIn("CLOperationModeOff", self.manager_h)
        self.assertIn("CLOperationModeFullControl", self.manager_h)
        self.assertIn("CLOperationModeLimitOnly", self.manager_h)

    def test_mode_derivation_enable_first(self):
        body = function_body(self.manager_m, "- (CLOperationMode)operationMode {")
        self.assertIn("if (_enabled) return CLOperationModeFullControl;", body)

    def test_level_apply_uses_one_shot_root_process(self):
        body = function_body(self.manager_m, "- (void)applyLimitOnlyLevel:(NSString *)mode completion:(void (^)(BOOL))completion {")
        self.assertIn('spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1", level])', body)
        self.assertIn('setlocalKV_C(@"limit_only_level", level)', body)

    def test_mode_switch_orchestration_order(self):
        # 完整控制→仅限流（spec B1 修订次序）：先落盘模式标志与档位（不被 daemon
        # 关停写突发覆盖），再 enable=NO（daemon 完整还原），最后 CLI 建会话
        body = function_body(self.manager_m, "- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {")
        limit_pos = body.index("CLOperationModeLimitOnly")
        level_pos = body.index('setlocalKV_C(@"limit_only_level", level)')
        mode_pos = body.index('setlocalKV_C(@"limit_only_mode", @YES)')
        enable_pos = body.index('saveConfigKey:@"enable" value:@NO')
        cli_pos = body.index('spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1"')
        self.assertLess(limit_pos, level_pos)
        self.assertLess(level_pos, mode_pos)
        self.assertLess(mode_pos, enable_pos)
        self.assertLess(enable_pos, cli_pos)

    def test_level_normalized_to_moderate_on_switch(self):
        # 进入仅限流自动中度（fix-limit-only-restart-state）：off/未设置一律归一化
        body = function_body(self.manager_m, "- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {")
        self.assertIn('if (level.length == 0 || [level isEqualToString:@"off"])', body)
        self.assertIn('level = @"moderate";', body)
        self.assertIn("self.limitOnlyLevel = level;", body)

    def test_cli_failure_retried_once(self):
        # apply_limit_only spawn 失败自动重试一次（两个调用点各两处）
        switch_body = function_body(self.manager_m, "- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {")
        self.assertEqual(switch_body.count('spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1"'), 2)
        level_body = function_body(self.manager_m, "- (void)applyLimitOnlyLevel:(NSString *)mode completion:(void (^)(BOOL))completion {")
        self.assertEqual(level_body.count('spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1"'), 2)

    def test_off_level_seed_ignored(self):
        # off 种子根除：applyConfigData 忽略 daemon 上报的 "off"，初始默认 moderate
        body = function_body(self.manager_m, "- (void)applyConfigData:(NSDictionary *)data {")
        self.assertIn('![limitOnlyLevelValue isEqualToString:@"off"]', body)
        init_body = function_body(self.manager_m, "- (instancetype)init {")
        self.assertIn('_limitOnlyLevel = @"moderate";', init_body)

    def test_mode_switch_failure_alert(self):
        # 切换失败必须可见：completion(NO) 弹窗提示（不再静默）
        body = function_body(self.settings, "- (void)switchToOperationMode:(CLOperationMode)mode {")
        self.assertIn("if (!success)", body)
        self.assertIn("showModeSwitchFailureAlert", body)
        self.assertIn("showModeSwitchFailureAlert", self.settings)

    def test_mode_switch_syncs_memory_before_notify(self):
        # operation-mode-live-refresh M1：切换成功后内存模式状态先对齐再发通知，
        # 否则 operationMode 派生自过期字段，UI 要重启才能看到新模式
        body = function_body(self.manager_m, "- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {")
        sync_pos = body.index("[self alignModeStateInMemory:mode]")
        notify_pos = body.index("postNotificationName:CLConfigDidUpdateNotification")
        self.assertLess(sync_pos, notify_pos)
        # 失败路径以磁盘真值为准重取
        self.assertIn("[self refreshConfig];", body)

    def test_align_mode_state_maps_three_states(self):
        body = function_body(self.manager_m, "- (void)alignModeStateInMemory:(CLOperationMode)mode {")
        self.assertIn("case CLOperationModeFullControl:", body)
        self.assertIn("case CLOperationModeLimitOnly:", body)
        self.assertIn("case CLOperationModeOff:", body)
        self.assertIn("_limitOnlyModeFlag", body)

    def test_direct_read_uses_smart_battery_registry(self):
        body = function_body(self.manager_m, "- (void)refreshDirectSessionState {")
        self.assertIn('IOServiceMatching("AppleSmartBattery")', body)
        self.assertIn('"ExternalChargeCapable"', body)

    def test_three_state_row_replaces_switch(self):
        # 主开关三态化：行值 + 选择器，不再是 tag 100 拨动开关
        self.assertNotIn('addSwitchRowWithIcon:@"bolt.fill"', self.settings)
        self.assertIn("presentOperationModePicker", self.settings)
        body = function_body(self.settings, "- (void)setupControlCard {")
        self.assertIn("addRowWithIcon", body)
        self.assertIn("operationModeText", body)

    def test_limit_only_gating_greys_daemon_cards(self):
        body = function_body(self.settings, "- (void)applyLimitOnlyUIGating {")
        self.assertIn("limitOnly ? 0.35 : 1.0", body)
        self.assertIn("userInteractionEnabled", body)
        self.assertIn("self.tempCard", body)
        self.assertIn("self.powerPathCard", body)

    def test_limit_only_banner_and_card_present(self):
        self.assertIn("setupLimitOnlyBanner", self.settings)
        self.assertIn("setupLimitOnlyCard", self.settings)
        self.assertIn("仅限流模式 · 守护进程未运行", self.settings)

    def test_config_did_update_refreshes_mode(self):
        # 本文件有两个 configDidUpdate（软件设置控制器在前）；锚定主控制器的更新注释
        anchor = self.settings.index("// 更新控制卡片的模式行（三态主开关，limit-only spec B2）+ 门控")
        segment = self.settings[anchor:anchor + 400]
        self.assertIn("applyLimitOnlyUIGating", segment)
        self.assertIn("operationModeText", segment)

    def test_old_switch_update_removed(self):
        self.assertNotIn("updateSwitchInCard:self.controlCard tag:100", self.settings)


class ThermalmonitordReloadContractTests(unittest.TestCase):
    """fix-thermal-limit-stuck-verifying A1：安装后重载 thermalmonitord（三形态）。"""

    def test_rootful_postinst_reloads_thermalmonitord(self):
        text = POSTINST_ROOTFUL.read_text()
        self.assertIn("killall thermalmonitord", text)

    def test_rootless_postinst_reloads_thermalmonitord(self):
        text = POSTINST_ROOTLESS.read_text()
        self.assertIn("killall thermalmonitord", text)

    def test_roothide_postinst_reloads_thermalmonitord(self):
        # roothide：killall 不能假定在 PATH（DISABLE_TWEAKS 安装器无注入），经
        # PATH → jbroot → 真实 rootfs 推导；失败仅放弃重载不阻塞安装
        text = POSTINST_ROOTHIDE.read_text()
        self.assertIn("reload_thermalmonitord() {", text)
        self.assertIn('"$KILLALL_BIN" thermalmonitord 2>/dev/null || true', text)
        self.assertIn("reload_thermalmonitord\n", text)


class PackagingAndStringsContractTests(unittest.TestCase):
    """B7 + 文案同步。"""

    @classmethod
    def setUpClass(cls):
        cls.build = BUILD_SH.read_text()
        cls.en = STRINGS_EN.read_text()
        cls.zh = STRINGS_ZH.read_text()

    def test_tweak_links_iokit(self):
        body = function_body(self.build, "build_tweak_dylib() {")
        self.assertIn("IOKit.tbd", body)

    def test_strings_synced(self):
        for key in ("运行模式", "完整控制", "仅限流", "限流档位", "会话状态", "生效验证",
                    "已插电 · 限流生效中", "未插电 · 限流已解除", "切换失败"):
            self.assertIn('"%s"' % key, self.zh)
            self.assertIn('"%s"' % key, self.en)


if __name__ == "__main__":
    unittest.main()

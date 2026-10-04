"""limit-only-daemon-free 合约测试。

仅限流模式（三态主开关的一态）= 只保留充电限流，daemon 零驻留（spec B1-B7）：
- B2：CLThermalSim tweak 会话执行——会话键 clLimitSessionEnabled/clLimitMode，
  插电时限流档、拔线回 off（幂等收敛）；会话关闭不碰 thermal 镜像；PPM 不属于会话；
  电池 interest 通知 + hook 点机会性复查 + thermalmonitord 重启重放。
- B3：daemon 一次性 CLI 动词 apply_limit_only——写会话键 + thermal 初始镜像 + 通知即退，
  不启动 HTTP/策略循环。
- B4：master-off 还原 carve-out——limit_only 模式下 thermal 会话键不被还原清除，
  PPM 照常归零；enable=YES 防御清理回收会话键。
- B1/B5：白名单放行 limit_only_mode；App 三态主开关 + 状态条 + 置灰门控 +
  限流卡片；档位写入走一次性 root 进程（spawnDaemonCLIVerb_C），daemon 不驻留。
- B7：tweak 打包链接 IOKit.tbd。
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"
TWEAK_M = ROOT / "ChargeLimiter" / "Tweak" / "CLThermalSimTweak.m"
BUILD_SH = ROOT / "scripts" / "build_packages.sh"
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
    """B2：CLThermalSim 会话执行端。"""

    @classmethod
    def setUpClass(cls):
        cls.tweak = TWEAK_M.read_text()

    def test_session_keys_defined(self):
        self.assertIn('"clLimitSessionEnabled"', self.tweak)
        self.assertIn('"clLimitMode"', self.tweak)

    def test_session_evaluate_unplug_converges_off(self):
        # 会话收敛：未插电或档位 off → 目标 off；锁定随目标镜像
        body = function_body(self.tweak, "static void CLTSSessionEvaluate(void) {")
        self.assertIn("CLTSPowerConnected()", body)
        self.assertIn('@"off"', body)
        self.assertIn("CLTSKeyThermalMode", body)
        self.assertIn("CLTSKeyLocked", body)
        self.assertIn("kCFPreferencesCurrentUser", body)

    def test_session_disabled_does_not_touch_mirror(self):
        # 会话关闭时直接返回：镜像写方归 CLI/常驻 daemon，tweak 不得越权
        body = function_body(self.tweak, "static void CLTSSessionEvaluate(void) {")
        self.assertIn("if (!CLTSReadSessionEnabled()) return;", body)

    def test_session_evaluate_idempotent(self):
        # 幂等：镜像与锁定均未变化时早退，不重写偏好
        body = function_body(self.tweak, "static void CLTSSessionEvaluate(void) {")
        self.assertIn("CLTSIsLocked() == locked", body)
        self.assertIn("return;", body)

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

    def test_replay_on_thermalmonitord_restart(self):
        # thermalmonitord 重启重放：initProduct hook 先重算会话再应用
        body = function_body(self.tweak, "static id CLTSInitProductOverride(id self, SEL _cmd, id data) {")
        self.assertIn("CLTSSessionEvaluate();", body)
        self.assertIn("CLTSApplyOnProduct(self);", body)

    def test_opportunistic_recheck_in_hooks(self):
        for sig in ("static void CLTSTryTakeActionOverride(id self, SEL _cmd) {",
                    "static void CLTSUpdateTelemetryOverride(id self, SEL _cmd) {"):
            body = function_body(self.tweak, sig)
            self.assertIn("CLTSSessionEvaluate();", body)

    def test_apply_notification_recomputes_session(self):
        body = function_body(self.tweak, "static void CLTSApplyNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {")
        self.assertIn("CLTSSessionEvaluate();", body)


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

    def test_ppm_restore_not_gated(self):
        # PPM 不属于会话：归零无条件执行（位于 carve-out if 块之后）
        body = function_body(self.daemon, "static void restoreThermalSimulationForReset(void) {")
        gate_pos = body.index("getLimitOnlySessionEnabled()")
        thermal_pos = body.index("setThermalSimulationMode")
        ppm_pos = body.index("setPPMSimulationMode")
        self.assertLess(gate_pos, thermal_pos)   # gate 只包裹 thermal
        between = body[thermal_pos:ppm_pos]
        self.assertIn("}", between)              # thermal 调用与 PPM 调用之间已出 if 块

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
        self.assertIn('"thermalSimulationLocked"', body)
        self.assertIn("CLPostThermalApplyNotification();", body)

    def test_disable_resets_mirror_off(self):
        body = function_body(self.utils, "void setLimitOnlySession(BOOL enabled, NSString* mode, BOOL plugged) {")
        self.assertIn('setObject:@"off" forKey:@"thermalSimulationMode"', body)
        self.assertIn('setObject:@NO forKey:@"thermalSimulationLocked"', body)

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
        # 完整控制→仅限流：先 enable=NO（daemon 完整还原），后建会话——还原不清会话
        body = function_body(self.manager_m, "- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {")
        limit_pos = body.index("CLOperationModeLimitOnly")
        enable_pos = body.index('saveConfigKey:@"enable" value:@NO')
        session_pos = body.index('setlocalKV_C(@"limit_only_mode", @YES)')
        cli_pos = body.index('spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1"')
        self.assertLess(enable_pos, session_pos)
        self.assertLess(session_pos, cli_pos)

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
                    "已插电 · 限流生效中", "未插电 · 限流已解除"):
            self.assertIn('"%s"' % key, self.zh)
            self.assertIn('"%s"' % key, self.en)


if __name__ == "__main__":
    unittest.main()

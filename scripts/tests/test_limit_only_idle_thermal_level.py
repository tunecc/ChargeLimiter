"""仅限流模式分时段双档位（limit-only-idle-thermal-level）

这一组断言防护的对象是：仅限流模式的热模拟档位从"只有一个插电档位"扩为
「充电时档位 / 平时档位」两个分时段档位后，最容易悄悄退化的几处——

1. tweak 会话评估忘了读平时档位，未插电又回到无条件 off（新功能等于没做）；
2. 会话通道写方与读方编解码不一致（一侧加了 bit16-23、另一侧没读）；
3. 选「关闭」又被某条路径归一化成中度（旧假控件复活）；
4. 「会话状态」行继续说「限流已解除」，而平时档位其实正在生效（状态面说假话）。

测法是源码结构核对（本仓无 ObjC 运行时测试体系，AGENTS.md 规定最小验证为
受影响 scheme 编译 + 定向脚本核对）。断言全部锚在具体函数体上，不用整文件
包含判断——那会让"函数被删了"和"函数写对了"都通过。
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TWEAK = (REPO / "ChargeLimiter" / "Tweak" / "CLThermalSimTweak.m").read_text(encoding="utf-8")
UTILS = (REPO / "ChargeLimiter" / "utils.mm").read_text(encoding="utf-8")
DAEMON = (REPO / "ChargeLimiter" / "daemon.mm").read_text(encoding="utf-8")
MANAGER = (REPO / "ChargeLimiter" / "UIKit" / "CLBatteryManager.m").read_text(encoding="utf-8")
SETTINGS = (
    REPO / "ChargeLimiter" / "UIKit" / "Controllers" / "CLSettingsViewController.m"
).read_text(encoding="utf-8")


def function_body(source: str, signature: str) -> str:
    """按签名取 ObjC 函数体（C 函数或方法）。签名需含左花括号前的全部字符。"""
    start = source.find(signature)
    assert start != -1, f"未找到函数签名: {signature}"
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : index]
    raise AssertionError(f"函数体未闭合: {signature}")


class TestTweakSessionEvaluation(unittest.TestCase):
    """tweak 会话评估：按插电+充电态在两个档位之间二选一"""

    def test_evaluate_reads_both_levels(self):
        seg = function_body(TWEAK, "static void CLTSSessionEvaluate(void) {")
        # 会话配置解出两个档位
        self.assertIn("CLTSSessionConfig(&charge, &idle)", seg)
        # 取值判据必须是"插电且正在充电"，不是旧的"插电"
        self.assertIn("plugged && CLTSIsCharging()", seg)
        self.assertIn("charging ? charge : idle", seg)
        # 旧判据（未插电一律归零）不得残留
        self.assertNotIn("(plugged && limit != 0) ? limit : 0", seg)

    def test_session_config_decodes_idle_bits(self):
        seg = function_body(TWEAK, "static BOOL CLTSSessionConfig(uint64_t *chargeMode, uint64_t *idleMode) {")
        self.assertIn("(state >> 8) & 0xFF", seg, "充电时档位仍在 bit8-15")
        self.assertIn("(state >> 16) & 0xFF", seg, "平时档位必须从 bit16-23 解出")

    def test_is_charging_probe_defaults_to_charging(self):
        # IsCharging 不可读时按"正在充电"：误判充电保留限流，是更安全的错误方向
        seg = function_body(TWEAK, "static BOOL CLTSIsCharging(void) {")
        self.assertIn("BOOL charging = YES;", seg)
        self.assertIn('CFSTR("IsCharging")', seg)

    def test_restore_reads_both_pref_keys(self):
        seg = function_body(TWEAK, "static void CLTSRestoreSessionFromPrefs(void) {")
        self.assertIn('CLTSCopyLimitOnlyMode(CFSTR("clLimitMode"))', seg)
        self.assertIn('CLTSCopyLimitOnlyMode(CFSTR("clLimitIdleMode"))', seg)
        self.assertIn("(idle << 16)", seg, "恢复时必须把平时档位写进 bit16-23")

    def test_watchdog_gate_uses_both_levels(self):
        seg = function_body(TWEAK, "static void CLTSUpdateReassertTimer(void) {")
        self.assertIn("CLTSSessionConfig(&charge, &idle)", seg)


class TestSessionChannelEncoding(unittest.TestCase):
    """写方（utils.mm）与读方（tweak / CLBatteryManager）编解码必须一致"""

    def test_writer_encodes_both_levels(self):
        seg = function_body(
            UTILS,
            "static void CLPostThermalSessionNotification(BOOL enabled, NSString* chargeMode, NSString* idleMode) {",
        )
        self.assertIn("CLThermalModeValue(chargeMode) << 8", seg)
        self.assertIn("CLThermalModeValue(idleMode) << 16", seg)

    def test_reader_decodes_both_levels(self):
        seg = function_body(
            UTILS, "BOOL CLThermalReadSessionChannel(BOOL *enabled, uint64_t *chargeMode, uint64_t *idleMode) {"
        )
        self.assertIn("(state >> 8) & 0xFF", seg)
        self.assertIn("(state >> 16) & 0xFF", seg)

    def test_encoding_is_backward_compatible(self):
        """bits16-23 为 0 必须解读为"平时档位关闭"

        旧安装只写 bit8-15。若缺字段时解读成别的值（例如回退到充电时档位），
        升级后用户会在未插电时突然多出一个生效档位。0 = 关闭同时覆盖
        "旧安装"与"平时档位确实是关闭"两种情形，这是零改写迁移的前提。
        """
        seg = function_body(
            UTILS, "BOOL CLThermalReadSessionChannel(BOOL *enabled, uint64_t *chargeMode, uint64_t *idleMode) {"
        )
        self.assertIn("(state >> 16) & 0xFF", seg)
        # 不得出现把 0 映射成非关闭档位的分支
        self.assertNotIn("idle ? idle : charge", seg.replace(" ", ""))

    def test_set_limit_only_session_writes_both_keys(self):
        seg = function_body(
            UTILS, "void setLimitOnlySession(BOOL enabled, NSString* chargeMode, NSString* idleMode, BOOL chargingActive) {"
        )
        self.assertIn("CLLimitOnlyLevelKey", seg)
        self.assertIn("CLLimitOnlyIdleLevelKey", seg)
        self.assertIn("CLPostThermalSessionNotification(enabled, chargeMode, idleMode)", seg)

    def test_off_is_a_legal_level(self):
        """off 是合法值：任何路径不得把它归一化成其他档位"""
        seg = function_body(UTILS, "static BOOL CLIsValidLimitOnlyMode(NSString* mode) {")
        self.assertIn('"off"', seg)
        # setLimitOnlySession 内的兜底只能是 off，不能是 moderate
        seg = function_body(
            UTILS, "void setLimitOnlySession(BOOL enabled, NSString* chargeMode, NSString* idleMode, BOOL chargingActive) {"
        )
        self.assertNotIn('@"moderate"', seg)
        self.assertIn('@"off"', seg)


class TestDaemonVerb(unittest.TestCase):
    """apply_limit_only CLI 动词接受两个档位，且不把 off 归一化"""

    def test_verb_parses_two_modes(self):
        seg = function_body(DAEMON, 'strcmp(argv[argIndex], "apply_limit_only")')
        # 直接从 daemon.mm 中截取该分支的主体
        self.assertIn("chargeMode", seg)
        self.assertIn("idleMode", seg)
        self.assertIn("setLimitOnlySession(enabled, chargeMode, idleMode, charging)", seg)

    def test_verb_accepts_off(self):
        seg = function_body(DAEMON, 'strcmp(argv[argIndex], "apply_limit_only")')
        self.assertIn('isEqualToString:@"off"', seg, "off 必须是合法档位值")
        # 非法值兜底关闭，不偷偷升档
        self.assertNotIn('mode = @"moderate"', seg)

    def test_get_conf_reports_idle_level(self):
        # daemon 的 get_conf 全量分支：按 api 字符串定位（HTTP 处理器里不是 strcmp 形式）
        seg = function_body(DAEMON, '[api isEqualToString:@"get_conf"]')
        self.assertIn('kv[@"limit_only_idle_level"]', seg)
        self.assertIn("getLimitOnlyIdleLevel()", seg)


class TestAppSideScopeDecision(unittest.TestCase):
    """App 侧分时段裁决与验证门控"""

    def test_scope_uses_same_predicate_as_tweak(self):
        seg = function_body(MANAGER, "- (CLLimitOnlyActiveScope)limitOnlyActiveScope {")
        self.assertIn("_directPlugConnected && _directIsCharging", seg)
        self.assertIn("CLLimitOnlyScopeCharging", seg)
        self.assertIn("CLLimitOnlyScopeIdle", seg)
        self.assertIn("CLLimitOnlyScopeOff", seg)

    def test_active_level_follows_scope(self):
        seg = function_body(MANAGER, "- (NSString *)limitOnlyActiveLevel {")
        self.assertIn("CLLimitOnlyScopeCharging", seg)
        self.assertIn("CLLimitOnlyScopeIdle", seg)

    def test_probe_targets_active_level(self):
        seg = function_body(MANAGER, "- (BOOL)computeLimitOnlyApplied {")
        self.assertIn("self.limitOnlyActiveLevel", seg)
        self.assertNotIn("thermalModeFromString:self.limitOnlyLevel]", seg)

    def test_verify_window_gate_is_scope_not_plug(self):
        """门控判据从"是否插电"改为"当前时段是否有档位"

        Bug B1 的原始修法是"未插电不开窗"，理由是当时未插电没有待生效对象。
        平时档位生效后未插电重新有了对象，若沿用旧门控，平时档位将永远得不到
        生效反馈——15s 后还会跳出假"验证失败"。
        """
        seg = function_body(MANAGER, "- (void)startLimitOnlyVerifyWindow {")
        self.assertIn("self.limitOnlyActiveScope == CLLimitOnlyScopeOff", seg)
        self.assertNotIn("if (!_directPlugConnected)", seg)

    def test_no_off_normalization_in_apply(self):
        """off 不得被改写

        旧实现在这一步把 off 归一成 moderate，选择器上的「关闭」因此是假控件。
        现在的 `@"moderate"` 只是"键从未写过"的缺省，与用户选过的 off 无关——
        判据是函数体内不得出现任何针对 off 的条件分支。
        """
        seg = function_body(
            MANAGER,
            "- (void)applyLimitOnlyLevelsWithChargeMode:(NSString *)chargeMode",
        )
        self.assertNotIn('isEqualToString:@"off"', seg)
        self.assertNotIn('isEqualToString: @"off"', seg)

    def test_no_off_normalization_in_switch_to_mode(self):
        seg = function_body(MANAGER, "- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {")
        limit_branch = seg.split("case CLOperationModeLimitOnly:")[1].split("case CLOperationModeFullControl:")[0]
        self.assertNotIn('isEqualToString:@"off"', limit_branch, "进入仅限流时不得把 off 改成中度")
        self.assertIn("apply_limit_only", limit_branch)

    def test_reestablish_compares_both_levels(self):
        seg = function_body(MANAGER, "- (void)reestablishLimitOnlySessionIfNeeded {")
        self.assertIn("_sessionChannelIdleMode", seg)
        self.assertIn("apply_limit_only", seg)


class TestLimitOnlyCardUI(unittest.TestCase):
    """主页仅限流卡片：两行档位 + 当前生效 + 诚实状态面"""

    def test_card_has_both_level_rows(self):
        self.assertIn('title:CLL(@"充电时档位")', SETTINGS)
        self.assertIn('title:CLL(@"平时档位")', SETTINGS)
        self.assertIn('title:CLL(@"当前生效")', SETTINGS)
        # 原「限流档位」行名不再出现
        self.assertNotIn('title:CLL(@"限流档位")', SETTINGS)

    def test_both_rows_have_pickers(self):
        self.assertIn("@selector(presentLimitOnlyChargeLevelPicker)", SETTINGS)
        self.assertIn("@selector(presentLimitOnlyIdleLevelPicker)", SETTINGS)

    def test_picker_offers_five_levels(self):
        seg = function_body(SETTINGS, "- (void)presentLimitOnlyLevelPickerForScope:(CLLimitOnlyActiveScope)scope {")
        self.assertIn('@"off"', seg)
        self.assertIn('@"nominal"', seg)
        self.assertIn('@"heavy"', seg)
        # 写入失败必须可见，不能静默保留旧值
        self.assertIn("showModeSwitchFailureAlert", seg)

    def test_active_scope_text_has_three_states(self):
        seg = function_body(SETTINGS, "- (NSString *)limitOnlyActiveScopeText {")
        self.assertIn("CLLimitOnlyScopeCharging", seg)
        self.assertIn("CLLimitOnlyScopeIdle", seg)
        self.assertIn("CLLimitOnlyScopeOff", seg)

    def test_session_row_does_not_claim_released_while_idle_active(self):
        """状态面诚实性：平时档位生效时不得说"限流已解除"

        旧实现未插电恒显「未插电 · 限流已解除」。平时档位生效后这句话是假话，
        用户会以为什么都没开，而设备其实正处于模拟热状态。
        """
        seg = function_body(SETTINGS, "- (void)updateLimitOnlyRows {")
        self.assertIn("CLLimitOnlyScopeOff", seg)
        self.assertIn("CLLimitOnlyScopeCharging", seg)
        # 退役文案不得再作为面向用户的字符串出现（注释里提一句是为了说明改了什么）
        self.assertIsNone(
            re.search(r'CLL\(@"未插电 · 限流已解除"\)', seg),
            "会话状态行不得再显示「未插电 · 限流已解除」",
        )
        self.assertNotIn('CLL(@"已插电 · 限流生效中")', seg)
        # 三个分支各自有独立文案：两侧皆关 / 插电充电 / 其余（平时档位生效）
        self.assertIn("两个档位均已关闭", seg)
        self.assertIn("已插电充电 · 充电时档位生效中", seg)
        self.assertIn("未充电 · 平时档位生效中", seg)

    def test_update_rows_refreshes_all_three_status_rows(self):
        seg = function_body(SETTINGS, "- (void)updateLimitOnlyRows {")
        for title in ["充电时档位", "平时档位", "当前生效", "会话状态", "生效验证"]:
            self.assertIn(f'title:CLL(@"{title}")', seg)


class TestLocalization(unittest.TestCase):
    """新增/退役文案必须中英成对，且退役文案不得残留"""

    STRINGS = {
        "zh": REPO / "ChargeLimiter" / "zh-Hans.lproj" / "Localizable.strings",
        "en": REPO / "ChargeLimiter" / "en.lproj" / "Localizable.strings",
    }

    def test_new_keys_exist_in_both(self):
        required = [
            "两个档位均已关闭",
            "已插电充电 · 充电时档位生效中",
            "已插电充电 · 生效验证中",
            "已插电充电 · 验证失败，点按重试",
            "未充电 · 平时档位生效中",
            "未充电 · 生效验证中",
            "未充电 · 验证失败，点按重试",
        ]
        for lang, path in self.STRINGS.items():
            text = path.read_text(encoding="utf-8")
            for key in required:
                self.assertIn(f'"{key}" =', text, f"{lang}.lproj 缺少 {key}")

    def test_retired_keys_are_gone(self):
        retired = [
            "限流档位",
            "已插电 · 限流生效中",
            "未插电 · 限流已解除",
        ]
        for lang, path in self.STRINGS.items():
            text = path.read_text(encoding="utf-8")
            for key in retired:
                self.assertNotIn(f'"{key}" =', text, f"{lang}.lproj 仍残留退役文案 {key}")


if __name__ == "__main__":
    unittest.main()

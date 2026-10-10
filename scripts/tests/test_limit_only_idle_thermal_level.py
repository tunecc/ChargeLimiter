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
ADVANCED = (
    REPO / "ChargeLimiter" / "UIKit" / "Controllers" / "CLAdvancedSettingsViewController.m"
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
        """两个参数位各自都要接受 off

        第 4 轮 Verifier 变异测试发现：只断言"动词段内某处出现过 off"时，把充电时档位
        参数位（argIndex+2）的 off 接受删掉，测试仍然全绿——而第 1 轮 A3/A13 的缺陷
        正在这一带。因此必须按参数位分别断言。
        """
        seg = function_body(DAEMON, 'strcmp(argv[argIndex], "apply_limit_only")')
        # 非法值兜底关闭，不偷偷升档
        self.assertNotIn('mode = @"moderate"', seg)
        charge_branch = seg.split("(argIndex + 2) < argc")[1].split("(argIndex + 3) < argc")[0]
        idle_branch = seg.split("(argIndex + 3) < argc")[1]
        self.assertIn('isEqualToString:@"off"', charge_branch, "充电时档位参数位必须接受 off")
        self.assertIn('isEqualToString:@"off"', idle_branch, "平时档位参数位必须接受 off")

    def test_get_conf_reports_idle_level(self):
        # daemon 的 get_conf 全量分支：按 api 字符串定位（HTTP 处理器里不是 strcmp 形式）
        seg = function_body(DAEMON, '[api isEqualToString:@"get_conf"]')
        self.assertIn('kv[@"limit_only_idle_level"]', seg)
        self.assertIn("getLimitOnlyIdleLevel()", seg)


class TestAppSideScopeDecision(unittest.TestCase):
    """App 侧分时段裁决与验证门控"""

    def test_scope_uses_same_predicate_as_tweak(self):
        # 判据经 limitOnlyChargingPeriodApplies 单点实现（第 4 轮 A8 修复）：
        # scope 与 UI 的关闭分支共用它，不再各写一份。
        seg = function_body(MANAGER, "- (CLLimitOnlyActiveScope)limitOnlyActiveScope {")
        self.assertIn("[self limitOnlyChargingPeriodApplies]", seg)
        self.assertIn("_directPlugConnected && _directIsCharging",
                      function_body(MANAGER, "- (BOOL)limitOnlyChargingPeriodApplies {"))
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

    def test_reestablish_does_not_normalize_off(self):
        """重启重建不得把用户选过的「关闭」改回中度

        Verifier 首轮判定 A3/A13 failed 的根因。off 合法化后这条归一化变成了真 bug：
        仅限流模式 daemon 不在场，本地 KV 里持久化的 off 经 applyConfigData 的旧门控被跳过，
        _limitOnlyLevel 退回 init 缺省中度；reestablish 再把 off 归一成中度并与内核态的 off
        判 mismatch，最终重写 apply_limit_only 1 moderate off。用户重启后插电充电实际被施加
        热模拟，而「当前生效」显示「充电时档位 · 中度」而非「未开启」。
        """
        seg = function_body(MANAGER, "- (void)reestablishLimitOnlySessionIfNeeded {")
        self.assertNotIn(
            'isEqualToString:@"off"',
            seg,
            "reestablish 不得把 off 归一成中度；缺省值只应发生在键从未写过时",
        )
        self.assertIn('@"moderate"', seg, "键从未写过时仍应缺省中度")


class TestOffSurvivesRestart(unittest.TestCase):
    """A3/A13 回归：用户选过的「关闭」必须跨重启保留

    这一组是 Verifier 首轮 fail 后补的。缺陷链：
    applyConfigData 对 limit_only_level 的防污染门控跳过 off → 仅限流模式（daemon 不在场，
    走本地 KV 回退）读到 off 也不覆写 → _limitOnlyLevel 退回 init 缺省中度 →
    reestablish 归一化并重写内核态。三处必须同时修正，缺一处缺陷就复发。
    """

    def test_apply_config_adopts_off(self):
        """键在场就采纳，含「关闭」"""
        seg = function_body(MANAGER, "- (void)applyConfigData:(NSDictionary *)data {")
        # 两个档位都不允许再用 off 做跳过条件
        self.assertNotIn('isEqualToString:@"off"', seg)
        # 但仍然要求是非空字符串（nil / 非字符串不得覆写）
        self.assertIn("isKindOfClass:[NSString class]", seg)
        self.assertIn("limitOnlyLevelValue", seg)
        self.assertIn("limitOnlyIdleLevelValue", seg)

    def test_local_fallback_does_not_mask_absence(self):
        """本地回退不得替用户填档位字面值

        填了 "moderate" 就让"缺键"和"用户选过中度"无法区分；缺键时的缺省由 init 提供，
        applyConfigData 只负责"在场即采纳"。
        """
        seg = function_body(MANAGER, "- (NSDictionary *)localConfigFallback {")
        self.assertNotIn(
            'm[@"limit_only_level"] = @"moderate"',
            seg,
            "不得在本地回退里填档位缺省值，否则用户选过的关闭被它冒充",
        )
        self.assertNotIn('m[@"limit_only_idle_level"] = @"off"', seg)

    def test_daemon_reports_levels_only_when_configured(self):
        """daemon 侧只在键真实存在时才上报

        "用户选过关闭"与"从未配置"值都是 off，必须由上报侧区分，否则完整控制态的缺省 off
        会把用户选过的关闭冲掉。
        """
        seg = function_body(DAEMON, '[api isEqualToString:@"get_conf"]')
        self.assertIn("getLimitOnlyLevelConfigured()", seg)
        self.assertIn("getLimitOnlyIdleLevelConfigured()", seg)
        self.assertIn('kv[@"limit_only_level"]', seg)
        self.assertIn('kv[@"limit_only_idle_level"]', seg)

    def test_utils_exposes_configured_probes(self):
        seg = function_body(UTILS, "BOOL getLimitOnlyLevelConfigured() {")
        self.assertIn("objectForKey:CLLimitOnlyLevelKey", seg)
        seg = function_body(UTILS, "BOOL getLimitOnlyIdleLevelConfigured() {")
        self.assertIn("objectForKey:CLLimitOnlyIdleLevelKey", seg)


class TestWriteFailureRollsBack(unittest.TestCase):
    """A9/A19：写入失败后 UI 必须显示写入前的档位，不是用户刚选的那个"""

    def test_apply_rolls_back_on_failure(self):
        seg = function_body(
            MANAGER, "- (void)applyLimitOnlyLevelsWithChargeMode:(NSString *)chargeMode"
        )
        # 必须记住写入前的值
        self.assertIn("previousCharge", seg)
        self.assertIn("previousIdle", seg)
        # 失败分支必须回滚内存与本地 KV，不能只弹个提示
        self.assertIn("self.limitOnlyLevel = previousCharge;", seg)
        self.assertIn("self.limitOnlyIdleLevel = previousIdle;", seg)
        # 本地 KV 也要回滚：否则下次刷新把新值读回来，UI 又翻成新选的值
        self.assertIn('setlocalKV_C(@"limit_only_level", previousCharge', seg)
        self.assertIn('setlocalKV_C(@"limit_only_idle_level", previousIdle', seg)

    def test_failure_does_not_open_verify_window(self):
        seg = function_body(
            MANAGER, "- (void)applyLimitOnlyLevelsWithChargeMode:(NSString *)chargeMode"
        )
        # 函数里有两个 if (ok)：第一个落本地 KV，第二个在 1.5s 后决定开窗还是回滚刷新。
        # 只看第二个——开窗属于"已生效"路径，失败路径开窗只会刷假"验证失败"。
        blocks = seg.split("if (ok) {")
        self.assertGreaterEqual(len(blocks), 3, "应存在 KV 写入与延迟刷新两个 ok 分支")
        refresh_block = blocks[2]
        self.assertIn("startLimitOnlyVerifyWindow", refresh_block)
        self.assertIn("refreshDirectSessionState", refresh_block)
        fail_block = refresh_block.split("} else {")[1]
        self.assertNotIn("startLimitOnlyVerifyWindow", fail_block)
        self.assertIn("previousCharge", fail_block)


class TestLimitOnlyCardUI(unittest.TestCase):
    """主页仅限流卡片：两行档位 + 当前生效 + 诚实状态面"""

    def test_card_has_both_level_rows(self):
        # 断言锚在 setupLimitOnlyCard 函数体上，不是整文件 substring——后者在删掉卡片
        # 某一行时仍然全绿（同样的文案在别处也出现），变异测试 7/31 漏网由此而来。
        seg = function_body(SETTINGS, "- (void)setupLimitOnlyCard {")
        for title in ("充电档位", "平时档位", "当前生效", "会话状态", "生效验证"):
            self.assertIn(f'title:CLL(@"{title}")', seg, f"卡片缺少「{title}」行")
        # 原「限流档位」行名不再出现
        self.assertNotIn('title:CLL(@"限流档位")', seg)

    def test_card_keeps_channel_tip_and_trollstore_hint(self):
        seg = function_body(SETTINGS, "- (void)setupLimitOnlyCard {")
        self.assertIn("充电档位与平时档位共用同一个温度模拟通道", seg)
        self.assertIn("getJBType_C() == 8", seg)
        self.assertIn("巨魔环境无执行端", seg)

    def test_verify_row_has_retry_gesture(self):
        # 重试手势必须挂在"生效验证"行上（挂整卡会与档位行选择器嵌套）
        seg = function_body(SETTINGS, "- (void)setupLimitOnlyCard {")
        self.assertIn("verifyRow", seg)
        self.assertIn("@selector(limitOnlyCardTapped)", seg)
        self.assertNotIn("[self.limitOnlyCard addGestureRecognizer", seg)

    def test_notes_use_note_row_not_bare_label(self):
        """两条说明必须走 addNoteRowWithText，不能再把裸 UILabel 塞进 contentStack

        裸 UILabel 只约束左右 16pt，结果是说明首行紧贴上方分隔线、末行直接顶到卡片
        下边缘——用户反馈的"最后的文字留白不够"。说明行带 8pt 上下内边距，且左缘与
        行名对齐而不是卡片左缘。
        """
        seg = function_body(SETTINGS, "- (void)setupLimitOnlyCard {")
        self.assertEqual(seg.count("addNoteRowWithText:"), 2)
        self.assertNotIn("contentStack addArrangedSubview:channelTip", seg)
        self.assertNotIn("contentStack addArrangedSubview:tip", seg)

    def test_note_row_has_vertical_padding_and_title_aligned_leading(self):
        seg = function_body(SETTINGS, "- (UIView *)addNoteRowWithText:(NSString *)text {")
        self.assertIn("[label.topAnchor constraintEqualToAnchor:row.topAnchor constant:8]", seg)
        self.assertIn("[label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8]", seg)
        # 左缘与行名同一度量，右缘 16pt；三者从同一组常量推出，不会各自漂移
        self.assertIn("constant:kCLCardTitleLeading", seg)
        self.assertIn("constant:-kCLCardIconLeading", seg)

    def test_row_metrics_come_from_shared_constants(self):
        """行名、分隔线、说明行左缘必须同源，不留裸魔法数

        曾出现"行名在 50pt、分隔线在 48pt"式的漂移风险。三个左缘都由同一组
        kCLCard* 常量推出，改一处即全卡对齐。裸 16 / 22 / 12 / 50 重新出现即失败。
        """
        self.assertIn(
            "static const CGFloat kCLCardTitleLeading = kCLCardIconLeading + kCLCardIconWidth + kCLCardIconTitleGap;",
            SETTINGS,
        )
        # 图标行从图标度量推行名左缘；分隔线与说明行直接用行名左缘
        expectations = {
            "- (void)addRowWithIcon:(NSString *)iconName title:(NSString *)title value:(NSString *)value color:(UIColor *)color {": [
                "kCLCardIconLeading",
                "kCLCardIconTitleGap",
            ],
            "- (UIView *)addNoteRowWithText:(NSString *)text {": ["kCLCardTitleLeading"],
            "- (UIView *)addSeparator {": ["kCLCardTitleLeading"],
        }
        for signature, required in expectations.items():
            seg = function_body(SETTINGS, signature)
            for token in required:
                self.assertIn(token, seg, f"{signature} 未使用 {token}")
            for magic in ("constant:16", "constant:22", "constant:12", "constant:50", "constant:-16"):
                self.assertNotIn(magic, seg, f"{signature} 残留裸度量 {magic}")

    def test_long_value_degrades_without_truncating_title(self):
        """窄屏长值只许缩字号，行名不参与压缩

        「会话状态」最长约 15 字，375pt 及更窄屏上与行名的固有宽度之和已超过可用宽度。
        两个标签压缩优先级都是默认 750，谁被压是未定义的——这里定死方向。
        """
        seg = function_body(SETTINGS, "- (void)addRowWithIcon:(NSString *)iconName title:(NSString *)title value:(NSString *)value color:(UIColor *)color {")
        self.assertIn("valueLabel.adjustsFontSizeToFitWidth = YES;", seg)
        self.assertIn("valueLabel.minimumScaleFactor = 0.6;", seg)
        self.assertIn(
            "[titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];",
            seg,
        )
        self.assertNotIn("[self.limitOnlyCard addGestureRecognizer", seg)

    def test_card_has_no_section_header(self):
        """卡内不得有 section header，直接以参数行开头

        limit-only-thermal-card-alignment D1：主页除本卡外没有卡内标题带，分组标签只以
        卡外普通标签的形式存在（如「更多功能」）。上一轮这里锁的是"必须有 header 且排在
        第一个档位行之前"，本轮按用户确认的"对齐主页图标参数行"反向锁定：header 出现
        即失败，且卡片第一个 arranged subview 必须是「充电档位」行。
        """
        seg = function_body(SETTINGS, "- (void)setupLimitOnlyCard {")
        self.assertNotIn("addSectionHeader", seg)
        # header 若回来，只会插在档位行之前——按出现顺序一并锁死
        self.assertLess(
            seg.find("addRowWithIcon"),
            seg.find("addNoteRowWithText"),
            "参数行必须排在说明行之前",
        )
        self.assertIn("addSectionHeader:(NSString *)title {", SETTINGS)

    def test_both_rows_have_pickers(self):
        seg = function_body(SETTINGS, "- (void)setupLimitOnlyCard {")
        self.assertIn("@selector(presentLimitOnlyChargeLevelPicker)", seg)
        self.assertIn("@selector(presentLimitOnlyIdleLevelPicker)", seg)
        # 两行都必须真的挂上手势并放开交互，否则出现"看得见选不动"的假控件
        self.assertEqual(seg.count("addGestureRecognizer"), 3)  # 两个档位行 + 生效验证行
        self.assertEqual(seg.count("userInteractionEnabled = YES"), 3)

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
        # 四个分支各自有独立文案：插电充电 / 未充电（平时档位生效）/ 两种"当前时段已关闭"
        self.assertIn("已插电充电 · 充电档位生效中", seg)
        self.assertIn("未充电 · 平时档位生效中", seg)
        self.assertIn("已插电充电 · 充电档位已关闭", seg)
        self.assertIn("未充电 · 平时档位已关闭", seg)
        # 不得再把"两个档位均已关闭"当作用户可见文案——scope=Off 不等于两侧皆关。
        # 注释里提一句是为了说明改了什么，所以断言 CLL(...) 形式而不是裸字符串。
        self.assertNotIn('CLL(@"两个档位均已关闭")', seg)

    def test_pollution_annotation_kept(self):
        # 外部模拟在场时标注"可能受污染"：只标注不推翻生效判定（D3 口径）
        seg = function_body(SETTINGS, "- (void)updateLimitOnlyRows {")
        self.assertIn("externalSimulationSource", seg)
        self.assertIn("（可能受外部模拟污染）", seg)

    def test_update_rows_refreshes_all_three_status_rows(self):
        seg = function_body(SETTINGS, "- (void)updateLimitOnlyRows {")
        for title in ["充电档位", "平时档位", "当前生效", "会话状态", "生效验证"]:
            self.assertIn(f'title:CLL(@"{title}")', seg)


class TestSessionStatusTruthTable(unittest.TestCase):
    """A8/A18：scope=Off 必须按时段点名，不能说"两个档位均已关闭"

    第 3 轮验收 failed 的根因。limitOnlyActiveScope == Off 覆盖两种并不相同的情况：
      - 插电充电中，但充电时档位为关（平时档位是什么都不影响当前时刻）
      - 未插电，但平时档位为关（充电时档位是什么都不影响）
    出厂缺省态（充电时=中度、平时=关闭）在未插电时正好落在第二种，此时卡片同时显示
    「充电时档位 = 中度」和「两个档位均已关闭」——自相矛盾。必须按时段点名是哪一档关了。
    """

    def test_off_branch_names_the_period_level(self):
        seg = function_body(SETTINGS, "- (void)updateLimitOnlyRows {")
        self.assertIn("已插电充电 · 充电档位已关闭", seg)
        self.assertIn("未充电 · 平时档位已关闭", seg)
        # 两个关闭分支按"插电且正在充电"区分，不能合成一句
        self.assertIn("} else if ([manager limitOnlyChargingPeriodApplies]) {", seg)
        self.assertNotIn('CLL(@"两个档位均已关闭")', seg)

    def test_off_branch_uses_charging_period_predicate(self):
        """判据必须与 scope 同源：插电 **且正在充电**，不是"插着线"

        第 4 轮验收 A8 的根因。scope 判据是 `_directPlugConnected && _directIsCharging`，
        而 UI 的 Off 分支只用 directPlugConnected——"插线但系统暂停充电"（优化充电 /
        80% 限制 / 已充满）被错判成充电时段，于是平时档位为关时显示
        「已插电充电 · 充电时档位已关闭」：设备并没在充电，该点名的是平时档位。
        出厂缺省态（充电时=中度、平时=关闭）在插线未充电时正好落入该组合。
        修复把判据抽成 manager 的 limitOnlyChargingPeriodApplies，两侧共用一份实现。
        """
        seg = function_body(SETTINGS, "- (void)updateLimitOnlyRows {")
        off_branches = seg[seg.index("已插电充电 · 充电档位已关闭") - 500:]
        self.assertIn("[manager limitOnlyChargingPeriodApplies]", off_branches)
        self.assertNotIn("manager.directPlugConnected", off_branches)

    def test_scope_and_ui_share_one_predicate(self):
        """scope 计算与 UI 不得各写一份判据

        判据分叉正是前三轮反复失传的原因：scope 说"未充电"，UI 说"已插电充电"。
        锁定 manager 侧存在唯一实现，且 limitOnlyActiveScope 复用它。
        """
        seg = function_body(MANAGER, "- (BOOL)limitOnlyChargingPeriodApplies {")
        self.assertIn("_directPlugConnected && _directIsCharging", seg)
        scope = function_body(MANAGER, "- (CLLimitOnlyActiveScope)limitOnlyActiveScope {")
        self.assertIn("[self limitOnlyChargingPeriodApplies]", scope)
        self.assertNotIn(
            "_directPlugConnected && _directIsCharging",
            scope,
            "scope 不得再内联一份判据",
        )


class TestLocalization(unittest.TestCase):
    """新增/退役文案必须中英成对，且退役文案不得残留"""

    STRINGS = {
        "zh": REPO / "ChargeLimiter" / "zh-Hans.lproj" / "Localizable.strings",
        "en": REPO / "ChargeLimiter" / "en.lproj" / "Localizable.strings",
    }

    def test_new_keys_exist_in_both(self):
        required = [
            "已插电充电 · 充电档位已关闭",
            "未充电 · 平时档位已关闭",
            "已插电充电 · 充电档位生效中",
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

    def test_limit_only_tip_names_the_main_page_rows(self):
        """「充电高级」页置灰提示指向主页的两个档位行，不再引用已不存在的卡名

        limit-only-thermal-card-alignment D2：主页该卡不再有卡名，原文案里的
        「高温模拟」卡片名会让用户去找一张不存在的卡。
        """
        for lang, path in self.STRINGS.items():
            text = path.read_text(encoding="utf-8")
            self.assertIn('"仅限流模式：档位由主页「充电档位 / 平时档位」接管，此处不可修改。" =', text)
            self.assertNotIn('"仅限流模式：档位由主页「高温模拟」卡片接管，此处不可修改。" =', text)
        adv = ADVANCED
        self.assertIn('CLL(@"仅限流模式：档位由主页「充电档位 / 平时档位」接管，此处不可修改。")', adv)
        self.assertNotIn('CLL(@"仅限流模式：档位由主页「高温模拟」卡片接管，此处不可修改。")', adv)

    def test_retired_keys_are_gone(self):
        retired = [
            "限流档位",
            "已插电 · 限流生效中",
            "未插电 · 限流已解除",
            "两个档位均已关闭",
        ]
        for lang, path in self.STRINGS.items():
            text = path.read_text(encoding="utf-8")
            for key in retired:
                self.assertNotIn(f'"{key}" =', text, f"{lang}.lproj 仍残留退役文案 {key}")


if __name__ == "__main__":
    unittest.main()

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"
API_CLIENT_H = ROOT / "ChargeLimiter" / "UIKit" / "CLAPIClient.h"
API_CLIENT_M = ROOT / "ChargeLimiter" / "UIKit" / "CLAPIClient.m"
ADV_SETTINGS_M = ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLAdvancedSettingsViewController.m"
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


class MCLPrefsContractTests(unittest.TestCase):
    """任务 2.1：层1 偏好读取层——白名单键、Missing/ReadFailed 语义、域扫描。"""

    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def test_whitelist_keys_exact_set(self):
        body = function_body(self.utils_mm, "NSArray<NSString*>* CLMCLPrefKeys(void) {")
        for key in ("MCLFeatureState", "currentState", "chargeLimitToken",
                    "mclLimitValue", "mclTargetSoC", "allowMCLOverride"):
            self.assertIn(f'@"{key}"', body)

    def test_candidate_domains_both_scanned(self):
        body = function_body(self.utils_mm, "static NSArray<NSString*>* CLMCLCandidateDomains(void) {")
        self.assertIn('@"com.apple.powerui.smartcharge"', body)
        self.assertIn('@"com.apple.powerui.smartcharging"', body)

    def test_read_prefs_distinguishes_missing_vs_read_failed(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadPrefs(NSMutableDictionary* outPrefs) {")
        self.assertIn("fileExistsAtPath", body)        # 域存在性判定
        self.assertIn("CLMCLPrefReadFailed", body)      # 读取异常标记（区分于缺失）
        self.assertIn("CLMCLPrefMissing", body)         # 缺失标记
        self.assertIn('@"unresolved"', body)            # 域未解析报告

    def test_read_agent_state_reuses_existing_xpc_channel(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadAgentState(int* obcStatus, BOOL* mclSupported, BOOL* mclEnabled) {")
        self.assertIn("isSmartChargeMCLSupported()", body)
        self.assertIn("getSmartChargeStatus()", body)
        self.assertIn("getSmartChargeMCLEnabled()", body)

    def test_declarations_in_header(self):
        self.assertIn("CLMCLPrefMissing = 0", self.utils_h)
        self.assertIn("CLMCLPrefFound = 1", self.utils_h)
        self.assertIn("CLMCLPrefReadFailed = 2", self.utils_h)
        self.assertIn("NSArray<NSString*>* CLMCLPrefKeys(void);", self.utils_h)
        self.assertIn("BOOL CLMCLReadPrefs(NSMutableDictionary* outPrefs);", self.utils_h)
        self.assertIn("BOOL CLMCLReadAgentState(int* obcStatus, BOOL* mclSupported, BOOL* mclEnabled);", self.utils_h)


class MCLForceEntryContractTests(unittest.TestCase):
    """任务 3.1：强制入口无读回短路、无条件下发；既有调用方语义不变。"""

    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def test_force_enable_has_no_readback_shortcircuit(self):
        body = function_body(self.utils_mm, "BOOL CLMCLForceEnable(void) {")
        self.assertIn("[client enableMCL:&err]", body)
        self.assertNotIn("getSmartChargeMCLEnabled() ==", body)

    def test_force_disable_has_no_readback_shortcircuit(self):
        body = function_body(self.utils_mm, "BOOL CLMCLForceDisable(void) {")
        self.assertIn("[client disableMCL:&err]", body)
        self.assertNotIn("getSmartChargeMCLEnabled() ==", body)

    def test_legacy_set_keeps_readback_shortcircuit(self):
        body = function_body(self.utils_mm, "BOOL setSmartChargeMCLEnabled(BOOL flag) {")
        self.assertIn("if (getSmartChargeMCLEnabled() == flag) {", body)  # v1.16.1 语义不变

    def test_both_force_entries_gated_by_capability_probe(self):
        for fn in ("BOOL CLMCLForceEnable(void) {", "BOOL CLMCLForceDisable(void) {"):
            body = function_body(self.utils_mm, fn)
            self.assertIn("isSmartChargeMCLSupported()", body, msg=fn)

    def test_declarations_in_header(self):
        self.assertIn("BOOL CLMCLForceEnable(void);", self.utils_h)
        self.assertIn("BOOL CLMCLForceDisable(void);", self.utils_h)


class MCLDiagnosticsContractTests(unittest.TestCase):
    """任务 2.2：诊断编排——字段集合、判定矩阵全分支、iOS 16 门控、读写分离。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_get_bat_info_embeds_mcl_diagnostics(self):
        body = function_body(self.daemon_mm, 'else if ([api isEqualToString:@"get_bat_info"]) {')
        self.assertIn('data[@"MCLDiagnostics"] = collectMCLDiagnostics();', body)

    def test_get_mcl_diagnostics_readonly_api_exists(self):
        self.assertIn('"get_mcl_diagnostics"', self.daemon_mm)
        self.assertIn("collectMCLDiagnostics()", self.daemon_mm)

    def test_ios16_gate_returns_early_with_zero_collection(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override) {")
        early = body.index("if (!mclSupported) {")
        head = body[early:early + 400]
        self.assertNotIn("CLMCLReadPrefs(", head)       # 早退分支内不得做层1/层2 收集
        self.assertNotIn("CLMCLReadAgentState(", head)
        self.assertIn('@"unsupported"', head)

    def test_verdict_matrix_all_five_rows(self):
        body = function_body(self.daemon_mm, "static NSString* MCLVerdictFromDiagnostics(BOOL mclSupported, NSDictionary* layer1, BOOL agentEnabled, NSDictionary* layer3) {")
        for verdict in ("healthy_enabled", "healthy_disabled", "disconnected", "pref_lost", "unsupported"):
            self.assertIn(f'@"{verdict}"', body)
        self.assertIn("registry_diff", body)

    def test_layer3_diff_targets_limit_or_override_keys(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLDiffRegistryProps(NSDictionary* before, NSDictionary* after) {")
        self.assertIn('containsString:@"limit"', body)
        self.assertIn('containsString:@"override"', body)
        self.assertIn('@"limit_related"', body)

    def test_standalone_layer3_degrades_to_indirect_without_candidates(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLLayer3EvidenceStandalone(void) {")
        self.assertIn('@"indirect"', body)
        self.assertIn("MCLRegistryEvidenceCandidateKeys()", body)


class MCLRepairContractTests(unittest.TestCase):
    """任务 3.2：修复编排——调用序列、busy 守卫、健康无副作用、iOS 16 零写入、回滚。

    相对 brief 测试代码的两处扩展（跨任务协调上下文要求）：
    1. 失败分支含 gate1/gate2 四分类：re-notes F2 新发现——enableMCL 在写偏好前有
       两个静默 bail 门（gate1 augury feature；gate2 DeviceSupports80ChargeLimit
       为假且非内部构建），报告须能区分（gate_evidence 携带 MobileGestalt 原始值）。
    2. mcl_repair_* 时间线事件经 appendMCLRepairCoordinationEvent 直写 policy 事件
       时间线：appendSmartChargeCoordinationEvent 在 from==to 时丢弃事件（daemon.mm
       转移过滤），而 MCL 修复不改充电状态，brief 参考代码的调用会被静默吞掉。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_repair_dispatched_via_post_api(self):
        self.assertIn('"repair_mcl_limit"', self.daemon_mm)
        self.assertIn("performMCLLimitRepair()", self.daemon_mm)

    def test_sequence_snapshot_then_normalize_then_force_then_recheck(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        snap = body.index("CLMCLReadPrefs(beforePrefs)")
        normalize = body.index("MCLNormalizePrefsForRepair(beforePrefs)")
        force = body.index("CLMCLForceEnable()")
        recheck = body.index("collectMCLDiagnosticsWithLayer3(")
        self.assertLess(snap, normalize)
        self.assertLess(normalize, force)
        self.assertLess(force, recheck)

    def test_healthy_verdict_keeps_semantics_no_write_no_force(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        healthy = body.index('isEqualToString:@"healthy_enabled"]')
        force = body.index("CLMCLForceEnable()")
        self.assertLess(healthy, force)  # 健康提前返回在 force 之前（kept 路径不触发 force/写入）
        self.assertIn('@"kept"', body)

    def test_busy_guards(self):
        wrapper = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepair(void) {")
        self.assertIn("g_mclRepairRunning", wrapper)
        self.assertIn("MCLRepairLock()", wrapper)
        inner = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertIn("g_tempSmartChargeDisabledByCL", inner)  # 协调会话活跃拒绝
        self.assertIn('@"coordination_session_active"', inner)

    def test_ios16_zero_write_gate_in_wrapper(self):
        wrapper = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepair(void) {")
        gate = wrapper.index("@available(iOS 17.0, *)")
        lock = wrapper.index("MCLRepairLock()")
        self.assertLess(gate, lock)  # 旧系统在加锁/任何写入之前退出
        self.assertIn('@"unsupported"', wrapper)

    def test_failure_rolls_back_snapshot_and_reports_branch(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertIn("MCLRollbackPrefs(", body)
        for branch in ("call_error", "gate1_augury_feature", "gate2_device_gate",
                       "qmax_neutralized", "token_zero", "still_disconnected"):
            self.assertIn(f'@"{branch}"', body)
        self.assertIn("DeviceSupports80ChargeLimit", body)   # gate2 MobileGestalt 证据探测
        self.assertIn('@"gate_evidence"', body)              # gate1/gate2 可区分的原始证据
        self.assertIn('@"reboot_and_retry"', body)
        self.assertIn('@"rollback"', body)

    def test_whitelist_only_normalization(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLNormalizePrefsForRepair(NSMutableDictionary* layer1) {")
        for key in ("MCLFeatureState", "mclLimitValue", "mclTargetSoC"):
            self.assertIn(f'@"{key}"', body)
        self.assertNotIn('@"currentState"', body)          # 服务端自有键不写
        self.assertNotIn('@"chargeLimitToken"', body)      # token 生命周期归服务端（F5）

    def test_normalize_skips_when_plist_unreadable_at_write(self):
        # 修复轮 1（审查 Important）：CLMCLReadPrefs 快照与 normalize 重读之间存在 TOCTOU——
        # states 检查只保证快照时刻可解析，重读失败（文件被删/损坏）时若以空字典继续写，
        # 会整体覆盖 plist、丢掉全部非白名单键。重读 nil 必须 skip 零写入。
        body = function_body(self.daemon_mm, "static NSDictionary* MCLNormalizePrefsForRepair(NSMutableDictionary* layer1) {")
        reread = body.index("dictionaryWithContentsOfFile:path")
        nil_skip = body.index('@"plist_unreadable_at_write"')
        write = body.index("writeToFile:path")
        self.assertLess(reread, nil_skip)    # 重读 nil 分支即返回 skip
        self.assertLess(nil_skip, write)     # skip 在任何 writeToFile 之前
        self.assertNotIn("dict = [NSMutableDictionary dictionary]", body)  # 空字典兜底已移除

    def test_coordination_timeline_events(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertIn('@"mcl_repair_started"', body)
        self.assertIn('@"mcl_repair_finished"', body)
        self.assertIn("appendMCLRepairCoordinationEvent", body)
        helper = function_body(self.daemon_mm, "static void appendMCLRepairCoordinationEvent(NSString* reason, NSDictionary* extras) {")
        self.assertIn("appendPolicyEventHistory", helper)   # 与协调事件同一 policy 事件时间线

    def test_no_daemon_restart_in_repair(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertNotIn("killall", body)
        self.assertNotIn("launchctl", body)   # Design Doc：不重启 poweruiagent

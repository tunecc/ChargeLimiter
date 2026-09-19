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

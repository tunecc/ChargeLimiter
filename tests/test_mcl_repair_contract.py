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

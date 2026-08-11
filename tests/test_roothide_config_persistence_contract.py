from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
COLLECTOR_H = ROOT / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.h"
COLLECTOR_M = ROOT / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.m"


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


class ConfigPersistenceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()
        cls.daemon_mm = DAEMON_MM.read_text()
        cls.collector_h = COLLECTOR_H.read_text()
        cls.collector_m = COLLECTOR_M.read_text()

    def test_path_finalization_runs_after_resolution_branch(self):
        body = function_body(self.utils_mm, "static void ensureAppPathsWithLibroot()")
        failure_branch = body.index("if (!appDoc || !sharedDataRoot || !configRoot)")
        finalization = body.index("// Finalize primary and fallback paths through one exit")
        assignment = body.index("g_confPath =", finalization)
        self.assertLess(failure_branch, finalization)
        self.assertLess(finalization, assignment)

    def test_direct_write_is_verified_before_success(self):
        signature = "static BOOL writeConfigDataToDiskWithLibroot(NSData* plistData, NSString** pathOut, NSError** errorOut) {"
        body = function_body(self.utils_mm, signature)
        self.assertIn("verifyWrittenConfigData", body)
        direct = body.index("NSDataWritingFileProtectionNone")
        verified = body.index("verifyWrittenConfigData", direct)
        direct_success = body.index("return YES", verified)
        self.assertLess(direct, verified)
        self.assertLess(verified, direct_success)

    def test_config_diagnostics_wrapper_is_declared(self):
        declaration = 'extern "C" NSDictionary* getConfigPersistenceDiagnostics_C(void);'
        self.assertIn(declaration, self.utils_h)
        self.assertIn("getConfigPersistenceDiagnostics_C(void)", self.utils_mm)

    def test_diagnostics_do_not_export_config_values(self):
        forbidden = ["config_values", "preferences_dump", "plist_contents"]
        combined = self.utils_mm + self.daemon_mm + self.collector_m
        for token in forbidden:
            self.assertNotIn(token, combined)


if __name__ == "__main__":
    unittest.main()

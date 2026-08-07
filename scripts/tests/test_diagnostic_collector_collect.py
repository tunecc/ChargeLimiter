# scripts/tests/test_diagnostic_collector_collect.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
API_H = REPO / "ChargeLimiter" / "UIKit" / "CLAPIClient.h"
API_M = REPO / "ChargeLimiter" / "UIKit" / "CLAPIClient.m"
COL_M = REPO / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.m"


class CollectContractTests(unittest.TestCase):
    def setUp(self):
        self.api_h = API_H.read_text(encoding="utf-8")
        self.api_m = API_M.read_text(encoding="utf-8")
        self.col_m = COL_M.read_text(encoding="utf-8")

    def test_get_diag_declared(self):
        self.assertIn("getDiagWithCompletion", self.api_h)

    def test_get_diag_uses_no_daemon_restart(self):
        idx = self.api_m.find("getDiagWithCompletion")
        self.assertGreater(idx, -1)
        body = self.api_m[idx : idx + 1200]
        self.assertIn('@"get_diag"', body)
        self.assertIn("allowDaemonRestart:NO", body)
        self.assertIn("allowRetry:NO", body)

    def test_collect_calls_get_diag(self):
        self.assertIn("getDiagWithCompletion", self.col_m)

    def test_collect_fills_environment_locally(self):
        # 本地环境不依赖 daemon
        self.assertIn("CLPackageSchemeString", self.col_m)
        self.assertIn("CLSanitizePathForDiag", self.col_m)
        self.assertIn("CLJBTypeLabelFromCode", self.col_m)

    def test_collect_uses_c_linkage_wrappers(self):
        # utils.mm 符号是 C++ mangled；collector 必须 dlsym unmangled _C wrappers
        self.assertIn("getJBType_C", self.col_m)
        self.assertIn("getSelfExePath_C", self.col_m)
        self.assertIn("get_sys_boottime_C", self.col_m)
        self.assertIn("getRuntimeDataRootPath_C", self.col_m)
        # 禁止直接 dlsym 裸 C++ 符号名
        self.assertNotIn('dlsym(RTLD_DEFAULT, "getJBType")', self.col_m)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "getSelfExePath")', self.col_m)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "get_sys_boottime")', self.col_m)

    def test_collect_falls_back_jbtype_from_diag(self):
        # 本地 unknown/空时用 daemon jbtype 回填
        self.assertIn('data[@"jbtype"]', self.col_m)
        self.assertIn("unknown", self.col_m)

    def test_collect_marks_offline_on_error(self):
        # 失败路径必须把 httpReachable / daemonAlive 置 NO
        self.assertTrue(
            "httpReachable = NO" in self.col_m or "httpReachable=NO" in self.col_m
            or ".httpReachable = NO" in self.col_m
        )


if __name__ == "__main__":
    unittest.main()

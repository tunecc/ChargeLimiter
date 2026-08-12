# scripts/tests/test_diagnostic_collector_collect.py
import unittest

from _helpers import REPO_ROOT as REPO, source_for
API_H = REPO / "ChargeLimiter" / "UIKit" / "CLAPIClient.h"
API_M = REPO / "ChargeLimiter" / "UIKit" / "CLAPIClient.m"
COL_H = REPO / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.h"
COL_M = REPO / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.m"


class CollectContractTests(unittest.TestCase):
    def setUp(self):
        self.api_h = source_for(API_H)
        self.api_m = source_for(API_M)
        self.col_h = source_for(COL_H) if COL_H.exists() else ""
        self.col_m = source_for(COL_M)

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

    def test_collect_signature_has_repair_summary(self):
        # 采集签名必须含 repairSummary，让「修复 daemon 启动」结果进报告
        self.assertIn("repairSummary:(nullable NSString *)repairSummary", self.col_h)
        self.assertIn("repairSummaryText", self.col_h)

    def test_collect_fills_environment_locally(self):
        # 本地环境不依赖 daemon
        self.assertIn("CLPackageSchemeString", self.col_m)
        self.assertIn("CLSanitizePathForDiag", self.col_m)
        self.assertIn("CLJBTypeLabelFromCode", self.col_m)

    def test_collect_uses_c_linkage_wrappers(self):
        # utils.mm 符号是 C++ mangled；collector 通过 extern 声明直接调用 unmangled _C wrappers。
        # 直接调用走链接期绑定，不依赖导出表；stripped Mach-O executable 不导出本地符号，
        # dlsym(RTLD_DEFAULT, ...) 会返回 NULL，故禁止用 dlsym 调 _C wrapper。
        self.assertIn("getJBType_C", self.col_m)
        self.assertIn("getSelfExePath_C", self.col_m)
        self.assertIn("get_sys_boottime_C", self.col_m)
        self.assertIn("getRuntimeDataRootPath_C", self.col_m)
        self.assertIn("clDaemonLaunchProbe_C", self.col_m)
        # 必须有 extern 声明（直接调用前置）
        self.assertIn("extern NSDictionary *clDaemonLaunchProbe_C", self.col_m)
        self.assertIn("extern int getJBType_C", self.col_m)
        # 禁止 dlsym 裸 C++ 符号名
        self.assertNotIn('dlsym(RTLD_DEFAULT, "getJBType")', self.col_m)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "getSelfExePath")', self.col_m)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "get_sys_boottime")', self.col_m)
        # 禁止 dlsym 调 _C wrapper（stripped binary 不导出，dlsym 必失败）
        self.assertNotIn('dlsym(RTLD_DEFAULT, "getJBType_C")', self.col_m)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "getSelfExePath_C")', self.col_m)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "get_sys_boottime_C")', self.col_m)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "getRuntimeDataRootPath_C")', self.col_m)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "clDaemonLaunchProbe_C")', self.col_m)

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

    def test_collect_has_local_environment_fallbacks(self):
        # 离线时不能依赖 BatteryManager 缓存，设备/系统/App 信息必须本地可读。
        self.assertIn("uname", self.col_m)
        self.assertIn("operatingSystemVersion", self.col_m)
        self.assertIn("CFBundleShortVersionString", self.col_m)


if __name__ == "__main__":
    unittest.main()

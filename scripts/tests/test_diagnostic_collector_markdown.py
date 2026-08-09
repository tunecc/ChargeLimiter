# scripts/tests/test_diagnostic_collector_markdown.py
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
H = REPO / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.h"
M = REPO / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.m"


class DiagnosticCollectorContractTests(unittest.TestCase):
    def setUp(self):
        self.h = H.read_text(encoding="utf-8") if H.exists() else ""
        self.m = M.read_text(encoding="utf-8") if M.exists() else ""

    def test_files_exist(self):
        self.assertTrue(H.exists(), "CLDiagnosticCollector.h missing")
        self.assertTrue(M.exists(), "CLDiagnosticCollector.m missing")

    def test_report_has_markdown_text(self):
        self.assertIn("- (NSString *)markdownText", self.h)

    def test_markdown_emits_four_sections(self):
        # markdownText 实现必须产出四个段标题
        self.assertIn("# 环境", self.m)
        self.assertIn("# 连通性", self.m)
        self.assertIn("# 读电量链路", self.m)
        self.assertIn("# 策略信号", self.m)

    def test_offline_banner(self):
        self.assertIn("⚠️ daemon 离线", self.m)

    def test_sanitize_path_helper(self):
        self.assertIn("CLSanitizePathForDiag", self.h)
        self.assertIn("CLSanitizePathForDiag", self.m)
        # 必须处理 .jbroot- 截断
        self.assertIn(".jbroot-", self.m)

    def test_package_scheme_helper(self):
        self.assertIn("CLPackageSchemeString", self.h)
        self.assertIn("CL_PACKAGE_ROOTHIDE", self.m)
        self.assertIn("CL_PACKAGE_ROOTLESS", self.m)

    def test_five_critical_keys_in_markdown(self):
        for k in ["CurrentCapacity", "Amperage", "Voltage", "IsCharging", "Temperature"]:
            self.assertIn(k, self.m)

    def test_no_uikit_import(self):
        # 纯函数层不碰 UIKit
        self.assertNotIn("#import <UIKit/UIKit.h>", self.m)
        self.assertNotIn("#import <UIKit/UIKit.h>", self.h)


    def test_usage_and_live_battery_lines(self):
        self.assertIn("# 使用说明", self.m)
        self.assertIn("当前电量/电流", self.m)
        self.assertIn("停充控制探针结论", self.m)
        # roothide expected wording present in formatter
        self.assertIn("roothide 预期", self.m)

    def test_daemon_link_offline_section(self):
        self.assertIn("# daemon 启动链路", self.m)
        self.assertIn("CLDiagErrnoLabel", self.h)
        self.assertIn("CLDiagErrnoLabel", self.m)

    def test_daemon_link_model(self):
        self.assertIn("CLDiagDaemonLink", self.h)
        self.assertIn("daemonLink", self.h)

    def test_jb_dual_source(self):
        self.assertIn("jbRawCode", self.h)
        self.assertIn("jbProbeDetail", self.h)


if __name__ == "__main__":
    unittest.main()

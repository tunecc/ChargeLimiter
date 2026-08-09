# scripts/tests/test_diagnostics_panel_ui.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ADV = REPO / "ChargeLimiter" / "UIKit" / "Controllers" / "CLAdvancedSettingsViewController.m"
ZH = REPO / "ChargeLimiter" / "zh-Hans.lproj" / "Localizable.strings"
EN = REPO / "ChargeLimiter" / "en.lproj" / "Localizable.strings"


class DiagnosticsPanelUITests(unittest.TestCase):
    def setUp(self):
        self.src = ADV.read_text(encoding="utf-8")
        self.zh = ZH.read_text(encoding="utf-8")
        self.en = EN.read_text(encoding="utf-8")

    def test_imports_collector(self):
        self.assertIn("CLDiagnosticCollector.h", self.src)

    def test_one_tap_copy_button_exists(self):
        self.assertIn("一键复制完整诊断", self.src)
        self.assertIn("copyFullDiagnosticTapped", self.src)

    def test_environment_card_keys(self):
        for key in [
            "diag_device", "diag_ios", "diag_appver", "diag_scheme",
            "diag_jbtype", "diag_daemon", "diag_http", "diag_service",
            "diag_key_capacity", "diag_iokit",
        ]:
            self.assertIn(f'@"{key}"', self.src, f"missing valueLabels key {key}")

    def test_collect_called_on_appear_or_refresh(self):
        self.assertIn("collectWithPolicySummary", self.src)

    def test_calibration_template_removed(self):
        # setupContent 的导出卡不再添加「复制长测校准模板」
        # 允许 method 残留但 setupContent 区域不得 addPicker 该 title
        setup_start = self.src.find("- (void)setupContent")
        # 只检查 CLPolicyDiagnosticsViewController 的 setupContent(第一个)
        setup_end = self.src.find("- (void)addDiagnosticRowToCard", setup_start)
        body = self.src[setup_start:setup_end]
        self.assertNotIn("复制长测校准模板", body)

    def test_renamed_export_buttons(self):
        self.assertIn("复制探针→详细", self.src)
        self.assertIn("复制策略信号", self.src)

    def test_localization_keys(self):
        for key in [
            "一键复制完整诊断",
            "环境与连通性",
            "复制探针→详细",
            "复制策略信号",
            "完整诊断已复制到剪贴板。",
        ]:
            self.assertIn(f'"{key}"', self.zh, f"zh missing {key}")
            self.assertIn(f'"{key}"', self.en, f"en missing {key}")

    def test_repair_daemon_button(self):
        self.assertIn("修复 daemon 启动", self.src)
        self.assertIn("repairDaemonTapped", self.src)
        self.assertIn("clRepairDaemonForApp_C", self.src)

    def test_repair_localization_keys(self):
        for key in ("修复 daemon 启动", "修复", "修复完成：daemon 已在线",
                    "daemon 已在运行", "未找到 daemon 二进制，请重装包",
                    "仍不在线（见下方诊断报告）"):
            self.assertIn(f'"{key}"', self.zh, f"zh missing {key}")
            self.assertIn(f'"{key}"', self.en, f"en missing {key}")


if __name__ == "__main__":
    unittest.main()

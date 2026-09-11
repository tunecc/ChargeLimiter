from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
API_CLIENT_H = ROOT / "ChargeLimiter" / "UIKit" / "CLAPIClient.h"
API_CLIENT_M = ROOT / "ChargeLimiter" / "UIKit" / "CLAPIClient.m"
ADV_SETTINGS_M = ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLAdvancedSettingsViewController.m"
SETTINGS_M = ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLSettingsViewController.m"
STRINGS_EN = ROOT / "ChargeLimiter" / "en.lproj" / "Localizable.strings"
STRINGS_ZH = ROOT / "ChargeLimiter" / "zh-Hans.lproj" / "Localizable.strings"
PRERM_PATHS = [
    ROOT / "ChargeLimiter" / "Package" / "DEBIAN" / "prerm",
    ROOT / "ChargeLimiter" / "Package_rootless" / "DEBIAN" / "prerm",
    ROOT / "ChargeLimiter" / "Package_roothide" / "DEBIAN" / "prerm",
]
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"


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


class UninstallRestoreContractTests(unittest.TestCase):
    """卸载/重装还原契约：还原语义、卸载可见性、App 入口与本地化资源同步。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()
        cls.api_client_h = API_CLIENT_H.read_text()
        cls.api_client_m = API_CLIENT_M.read_text()
        cls.adv_settings_m = ADV_SETTINGS_M.read_text()
        cls.settings_m = SETTINGS_M.read_text()
        cls.strings_en = STRINGS_EN.read_text()
        cls.strings_zh = STRINGS_ZH.read_text()
        cls.prerms = {path: path.read_text() for path in PRERM_PATHS}
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def test_reset_path_restores_inflow_override_keys(self):
        body = function_body(
            self.daemon_mm,
            "static void resetBatteryStatusWithContext(BOOL restoreRuntimeSideEffects, NSString* reason) {",
        )
        self.assertIn("restoreInflowOverrideForReset()", body)

    def test_inflow_restore_targets_override_write_plane(self):
        body = function_body(self.daemon_mm, "static void restoreInflowOverrideForReset(void) {")
        self.assertIn("CLCanUseOverrideChargeControl()", body)
        self.assertIn("CLCopyOverrideWriteService()", body)
        self.assertIn("setInflowStatusOverride(overrideServ, YES)", body)

    def test_full_restore_force_enables_and_clears_permanent_disable(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performFullSmartChargeRestore(NSString* reason) {")
        force_enable = body.index("setSmartChargeEnable(YES)")
        cleared = body.index('setLocalBool(@"disable_smart_charge", NO)')
        self.assertLess(cleared, force_enable, "必须先清除永久停用配置再强制开启，否则 daemon 会按旧配置立即重新停用")
        self.assertIn("endSmartChargeCoordinationSession()", body)
        self.assertIn("restoreInflowOverrideForReset()", body)
        self.assertIn("restoreThermalSimulationForReset()", body)
        self.assertIn("restoreAcceleratedChargeStateForReset()", body)
        self.assertIn("restoreMCLStateAfterEnable()", body)
        self.assertIn("appendSmartChargeCoordinationEvent", body)

    def test_permanent_disable_coordinates_mcl(self):
        """iOS 17 充电优化三选项 = OBC + MCL 组合（固件逆向结论）：
        永久停用必须同时关 MCL，还原/自愈必须恢复 MCL。"""
        # 永久停用路径：先记 MCL 原状态，再 OBC disable + MCL disable
        sync_body = function_body(self.daemon_mm, "static void syncSmartChargeCoordination(NSDictionary* info, BOOL isAdaptorConnected) {")
        self.assertIn("rememberMCLStateBeforeDisable()", sync_body)
        self.assertIn("disableMCLForPermanentDisable()", sync_body)
        # 还原/自愈路径：OBC enable 后恢复 MCL
        for fn in (
            "static void restoreSmartChargeForReset(NSString* reason) {",
            "static void selfHealSmartChargeOnBootstrap(void) {",
        ):
            body = function_body(self.daemon_mm, fn)
            self.assertIn("restoreMCLStateAfterEnable()", body, msg=fn)
        # MCL 记忆/恢复辅助函数存在且走能力探测
        self.assertIn("static void rememberMCLStateBeforeDisable(void) {", self.daemon_mm)
        self.assertIn("static void restoreMCLStateAfterEnable(void) {", self.daemon_mm)
        self.assertIn("static void disableMCLForPermanentDisable(void) {", self.daemon_mm)
        self.assertIn("isSmartChargeMCLSupported()", self.daemon_mm)
        # get_bat_info 暴露 MCL 状态供 App 显示/诊断
        self.assertIn('data[@"SmartChargeMCLSupported"]', self.daemon_mm)
        self.assertIn('data[@"SmartChargeMCLEnabled"]', self.daemon_mm)

    def test_restore_exposes_api_and_cli_and_notify(self):
        self.assertIn('"restore_smart_charge"', self.daemon_mm)
        self.assertIn('strcmp(argv[argIndex], "restore")', self.daemon_mm)
        self.assertIn("kDaemonRestoreNotifyName", self.daemon_mm)
        self.assertIn("registerDaemonRestoreNotifySignal", self.daemon_mm)
        # CLI 兜底必须先通知运行中 daemon 再自行还原，与 reset_and_exit 模式一致
        cli_pos = self.daemon_mm.index('strcmp(argv[argIndex], "restore")')
        notify_pos = self.daemon_mm.index("notify_post(kDaemonRestoreNotifyName.UTF8String)", cli_pos)
        fallback_pos = self.daemon_mm.index('performFullSmartChargeRestore(@"cli_restore")', notify_pos)
        self.assertLess(cli_pos, notify_pos)
        self.assertLess(notify_pos, fallback_pos)

    def test_api_client_has_restore_method(self):
        self.assertIn("restoreSmartChargeWithCompletion", self.api_client_h)
        self.assertIn('"api": @"restore_smart_charge"', self.api_client_m)
        self.assertIn("restore_smart_charge", self.api_client_m)  # mock 分支

    def test_advanced_settings_has_restore_entry(self):
        self.assertIn("CLAdvRestoreSmartChargeTag", self.adv_settings_m)
        self.assertIn("restoreSmartChargeTapped", self.adv_settings_m)
        self.assertIn("smartChargeRestoreValueText", self.adv_settings_m)

    def test_main_page_has_residue_banner(self):
        self.assertIn("setupSmartChargeRestoreBanner", self.settings_m)
        self.assertIn("updateSmartChargeRestoreBannerVisibilityForManager", self.settings_m)
        body = function_body(
            self.settings_m,
            "- (void)updateSmartChargeRestoreBannerVisibilityForManager:(CLBatteryManager *)manager {",
        )
        # 提示条件：状态 3 且非本工具协调会话；不做静默自动恢复
        self.assertIn("manager.smartChargeStatus == 3", body)
        self.assertIn("!manager.smartChargeManagedByDaemon", body)

    def test_prerm_warns_on_restore_failure(self):
        for path, content in self.prerms.items():
            with self.subTest(prerm=str(path)):
                self.assertIn("if ! \"$APP_DIR/ChargeLimiterDaemon\" reset_and_exit", content)
                self.assertIn("warn_restore_failed", content)
                self.assertIn("Optimized Battery Charging", content)
                # 数据容器清理逻辑保持不变
                self.assertIn("cleanup_data_container", content)

    def test_mcl_probe_gated_before_selector_calls(self):
        """iOS 16 回归（2026-09-10）：PowerUISmartChargeClient 在 iOS 16 存在但
        没有 MCL selector，未设防的 [client isMCLSupported] 会抛 unrecognized
        selector 打挂 daemon——get_bat_info 每次读电池数据都会触发。探测必须
        @available(iOS 17) + respondsToSelector 双重门控。"""
        body = function_body(self.utils_mm, "BOOL isSmartChargeMCLSupported(void) {")
        self.assertIn("@available(iOS 17.0, *)", body)
        for sel in ("isMCLSupported", "isMCLCurrentlyEnabled:", "enableMCL:", "disableMCL:"):
            self.assertIn(f"respondsToSelector:@selector({sel})", body)
        # get/set 只能在探测通过后才允许调用 MCL selector
        get_body = function_body(self.utils_mm, "BOOL getSmartChargeMCLEnabled(void) {")
        self.assertIn("if (!isSmartChargeMCLSupported())", get_body)
        set_body = function_body(self.utils_mm, "BOOL setSmartChargeMCLEnabled(BOOL flag) {")
        self.assertIn("if (!isSmartChargeMCLSupported())", set_body)

    def test_localization_strings_present_in_both_languages(self):
        keys = [
            "还原系统优化充电",
            "还原成功",
            "还原失败",
            "操作失败：%@",
            "无法连接守护进程",
            "系统优化充电处于异常临时停用状态，可能无法使用系统的充电限制",
            "还原命令已执行，但系统优化充电状态未变化，请重启设备后再试。",
        ]
        for key in keys:
            with self.subTest(key=key):
                self.assertIn(f'"{key}"', self.strings_en)
                self.assertIn(f'"{key}"', self.strings_zh)


if __name__ == "__main__":
    unittest.main()

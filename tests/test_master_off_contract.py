"""master-off-full-disable 合约测试。

主页面「启用」总开关关闭 = 软件对系统零干预 + 后台零驻留（用户决定 D1/D2/D3）：
- B1/B2：enable=NO → 全量还原（resetBatteryStatusWithContext(YES)）→ 越狱形态 launchd
  自注销（bootout，SIGTERM 终止进程，atexit 不执行）→ 退出；TrollStore 直接退出。
- B3：launchd 拉起（ppid==1）且 g_enable=NO → 自检还原后退出。
- B4：App spawn 非驻留诊断形态——空闲退出（300s > 探针长会话 180s）。
- B5：HTTP 白名单——只读诊断 + 修复/还原 + enable=YES + disable_smart_charge=NO；
  其余写入拒绝 master_switch_off；自愈与统计停写。
- B6：enable=YES 时越狱形态 bootstrap 回 launchd（TrollStore 跳过）。
- B7：App 高级设置灰锁，仅「还原系统优化充电」行保持可用。
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"
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


class MasterOffShutdownContractTests(unittest.TestCase):
    """B1/B2：主开关关闭的全量还原 + 退出 + launchd 自注销。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_shutdown_sequence_defined(self):
        body = function_body(self.daemon_mm, "static void CLMasterOffShutdown(NSString* reason) {")
        # 全量还原（restore=YES），不是旧路径 resetBatteryStatus()
        self.assertIn("resetBatteryStatusWithContext(YES, reason)", body)
        # TrollStore 分支先行跳过 launchd
        self.assertIn("JBTYPE_TROLLSTORE", body)
        self.assertIn("CLMasterBootoutSelf()", body)
        self.assertIn("exit(0)", body)

    def test_bootout_uses_service_target_form(self):
        # bootout 用 system/<label> 形式，避免各形态 plist 路径解析（rootless/roothide jbroot）
        body = function_body(self.daemon_mm, "static int CLMasterBootoutSelf(void) {")
        self.assertIn('@"bootout"', body)
        self.assertIn('@"system/com.chargelimiter.mod"', body)

    def test_set_conf_enable_off_routes_to_shutdown(self):
        body = function_body(self.daemon_mm, "NSDictionary* handleReq(NSDictionary* nsreq) {")
        gate = body.index('if ([key isEqualToString:@"enable"]) {')
        region = body[gate:gate + 2000]
        self.assertIn("CLMasterOffShutdown(@\"master_off_set_conf\")", region)
        # 旧路径不得残留于 enable=NO 分支
        self.assertNotIn("tryRestoreSmartChargeAfterCoordination(@\"daemon_disabled\")", region)

    def test_launchd_boot_check_self_exits(self):
        body = function_body(self.daemon_mm, "- (void)serve {")
        check = body.index("!g_enable && getppid() == 1")
        region = body[check:check + 300]
        self.assertIn("CLMasterOffShutdown(@\"master_off_boot_check\")", region)

    def test_bootout_terminates_without_atexit_rerun_documented(self):
        # bootout 以 SIGTERM 终止进程：atexit 不执行，无重复还原——语义必须写明
        # （保证还原集合与「还原系统优化充电」一致、不新增副作用）。
        window = self.daemon_mm.index("CLMasterBootoutSelf")
        head = self.daemon_mm[max(0, window - 2500):window]
        self.assertIn("SIGTERM", head)


class MasterOffGateContractTests(unittest.TestCase):
    """B5：g_enable=NO 时 HTTP 白名单 + 自愈/统计停写。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_gate_installed_before_api_dispatch(self):
        body = function_body(self.daemon_mm, "NSDictionary* handleReq(NSDictionary* nsreq) {")
        gate = body.index("CLMasterOffGateRequest(api, nsreq)")
        first_api = body.index('@"get_conf"')
        self.assertLess(gate, first_api)

    def test_gate_whitelist_membership(self):
        body = function_body(self.daemon_mm, "static NSDictionary* CLMasterOffGateRequest(NSString* api, NSDictionary* nsreq) {")
        for api in ("get_conf", "get_bat_info", "get_mcl_diagnostics", "get_statistics",
                    "get_policy_events", "get_diag", "reload_conf",
                    "restore_smart_charge", "repair_mcl_limit", "charge_control_probe",
                    "clear_statistics"):
            self.assertIn(f'@"{api}"', body)
        # 修复/还原类动作语义注释（用户决定 D1）
        self.assertIn("D1", body)
        # App 本地数据管理键放行（真机回灌：主开关关闭时历史开关/清空必须可用）
        self.assertIn('history_stats_enabled', body)
        self.assertIn('@"lang"', body)

    def test_gate_allows_reopen_and_restore_semantics_only(self):
        body = function_body(self.daemon_mm, "static NSDictionary* CLMasterOffGateRequest(NSString* api, NSDictionary* nsreq) {")
        self.assertIn('if ([key isEqualToString:@"enable"])', body)
        # disable_smart_charge=NO（还原语义）放行；=YES（写入式停用）不放行
        self.assertIn('disable_smart_charge"] && ![nsreq[@"val"] boolValue]', body)
        self.assertIn('@"master_switch_off"', body)

    def test_healing_disabled_when_master_off(self):
        for fn in ("static void recoverSmartChargeCoordinationOnBootstrap(void) {",
                   "static void selfHealSmartChargeOnBootstrap(void) {"):
            body = function_body(self.daemon_mm, fn)
            self.assertIn("if (!g_enable) {", body, msg=fn)

    def test_statistics_disabled_when_master_off(self):
        body = function_body(self.daemon_mm, "static void updateStatistics() {")
        self.assertIn("if (!g_enable) {", body)

    def test_idle_exit_only_in_nonresident_mode(self):
        body = function_body(self.daemon_mm, "- (void)serve {")
        self.assertIn("g_masterIdleMonitor", body)
        self.assertIn("kMasterIdleExitSeconds", body)
        # 空闲阈值必须覆盖探针长会话（180s），防误杀
        self.assertIn("300", body)


class MasterOnBootstrapContractTests(unittest.TestCase):
    """B6：重开主开关恢复 launchd 常驻注册。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_bootstrap_called_on_enable_yes(self):
        body = function_body(self.daemon_mm, "NSDictionary* handleReq(NSDictionary* nsreq) {")
        enable_yes = body.index("CLMasterOnBootstrapSelf();")
        # 必须在 enable 分支的启用侧（disableSmartCharge 检查之后）
        branch = body.index('if ([key isEqualToString:@"enable"]) {')
        self.assertLess(branch, enable_yes)

    def test_bootstrap_skips_trollstore_and_registered_job(self):
        body = function_body(self.daemon_mm, "static void CLMasterOnBootstrapSelf(void) {")
        self.assertIn("JBTYPE_TROLLSTORE", body)
        self.assertIn('@"print", @"system/com.chargelimiter.mod"', body)
        self.assertIn('@"bootstrap", @"system"', body)

    def test_plist_candidates_cover_rootful_and_jbroot(self):
        body = function_body(self.daemon_mm, "static void CLMasterOnBootstrapSelf(void) {")
        self.assertIn("/Library/LaunchDaemons/com.chargelimiter.mod.plist", body)
        self.assertIn("CLDaemonJbRootPath()", body)
        # jbroot 解析已在 utils 导出
        self.assertIn("NSString* CLDaemonJbRootPath(void);", UTILS_H.read_text())
        self.assertIn("NSString* CLDaemonJbRootPath(void) {", UTILS_MM.read_text())


class MasterOffAppContractTests(unittest.TestCase):
    """B7：App 高级设置灰锁——功能行禁用，修复动作保留。"""

    @classmethod
    def setUpClass(cls):
        cls.adv = ADV_SETTINGS_M.read_text()

    def test_lock_state_applied_on_lifecycle(self):
        self.assertIn("applyMasterSwitchLockState", self.adv)
        # viewDidLoad / configDidUpdate / daemon 状态变化三处挂钩
        self.assertGreaterEqual(self.adv.count("applyMasterSwitchLockState"), 4)

    def test_restore_row_whitelisted_in_lock(self):
        body = function_body(self.adv, "- (void)applyMasterSwitchLockState {")
        self.assertIn("CLAdvRestoreSmartChargeTag", body)
        self.assertIn("userInteractionEnabled", body)

    def test_banner_informs_user(self):
        body = function_body(self.adv, "- (void)applyMasterSwitchLockState {")
        self.assertIn("CLAdvMasterOffBannerTag", body)
        self.assertIn("主开关已关闭", body)
        for path in (STRINGS_EN, STRINGS_ZH):
            self.assertIn("主开关已关闭", path.read_text())

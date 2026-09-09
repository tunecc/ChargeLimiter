import re
import unittest

from _helpers import REPO_ROOT, source_for, function_body

VC_PATH = REPO_ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLBatteryCompatibilityTestViewController.m"
ZH_STRINGS = REPO_ROOT / "ChargeLimiter" / "zh-Hans.lproj" / "Localizable.strings"
EN_STRINGS = REPO_ROOT / "ChargeLimiter" / "en.lproj" / "Localizable.strings"

INFLOW_HANDLER = "- (void)handleInflowSample:(BOOL)isCharging"
HANDLE_SAMPLE = "- (void)handleSample:(NSDictionary *)data"
RELEASE_METHOD = "- (void)issueInflowRelease"


class CompatInflowPlugCycleTests(unittest.TestCase):
    """禁流测试判定口径：软件模拟拔线的充电状态翻转判定。

    用户准则（2026-09-07）：测试过程中电池出现过「未充电 → 已充电」翻转即判支持——
    配合勿拔线提示，未充电样本只能由禁流写造成（基线锚定充电中），其后回到已充电即
    禁流可退出且可恢复。判定信号只用 IsCharging，不使用电流读数、电流极值、
    ExternalConnected 翻转或重试维持（两台真机证据：系统对抗恢复使连续确认/维持
    判定必然误判"无法支持"；iPhone16,2 iOS17.1 电流不转负、iPhone11,2 iOS16.1.2
    inflow_override 键 write_rejected 走 legacy ExternalConnected 写且系统派生恢复）。
    停充/智能停充的电流口径不变（IsCharging 是自己写的，翻转是写入伪迹）。
    """

    def setUp(self):
        self.source = source_for(VC_PATH)
        self.zh = ZH_STRINGS.read_text(encoding="utf-8")
        self.en = EN_STRINGS.read_text(encoding="utf-8")

    def inflow_body(self):
        return function_body(self.source, INFLOW_HANDLER)

    # ---- 判定状态机 ----

    def test_inflow_stage_enum_and_constants(self):
        """禁流状态机：三阶段枚举（等待未充电/等待返回/释放等待）+ 释放后返回等待上限 20s。"""
        for stage in ("CLCompatInflowStageWaitingExit", "CLCompatInflowStageWaitingReturn",
                      "CLCompatInflowStageReleaseWaiting"):
            self.assertIn(stage, self.source)
        self.assertRegex(self.source, r"CLCompatInflowReleaseWait\s*=\s*20")

    def test_no_streak_or_retry_machinery(self):
        """移除连续样本确认与重试机制（两台真机误判的根源）。"""
        for removed in ("CLCompatStateStreak", "CLCompatInflowMaxRetries",
                        "inflowNonChargeStreak", "inflowRetryOrExhaust",
                        "inflowRetryInFlight", "inflowRetries"):
            self.assertNotIn(removed, self.source, f"应移除: {removed}")

    def test_handle_sample_dispatches_inflow_to_dedicated_handler(self):
        """handleSample 把禁流样本分派到专用判定，与停充电流口径路径分离。"""
        body = function_body(self.source, HANDLE_SAMPLE)
        self.assertIn("handleInflowSample", body)

    def test_inflow_verdict_uses_ischarging_only(self):
        """判定信号纯度：禁流判定只用 IsCharging，不含电流/ExternalConnected/基线复合信号。"""
        body = self.inflow_body()
        self.assertIn("isCharging", body)
        for forbidden in ("extConnected", "bExtConnected", "bCurrent",
                          "CLCompatCurrentThresholdmA", "confirmMaxA", "confirmMinA"):
            self.assertNotIn(forbidden, body, f"禁流判定不得使用: {forbidden}")
        # 电流入参/局部变量（词边界，避免误伤 currentKind 等）
        self.assertIsNone(re.search(r"\bcurrent\b", body), "禁流判定不得使用电流量")

    def test_exit_is_first_not_charging_sample(self):
        """未充电样本出现即生效（无连续确认），并发出状态变化事件。"""
        body = self.inflow_body()
        self.assertIn("if (!isCharging)", body)
        self.assertIn("CLCompatEventKindStateChange", body)

    def test_system_restore_flip_is_supported(self):
        """系统自愈：未充电→已充电翻转 → 周期完成 → 支持。"""
        body = self.inflow_body()
        self.assertIn("CLCompatInflowRestoreSystem", body)
        self.assertIn("CLCompatTestVerdictSupported", body)

    def test_release_path_issues_write_and_waits(self):
        """禁流维持（观察窗到期）→ 显式释放 setInflowStatus:YES → 等待返回翻转。"""
        body = self.inflow_body()
        release_body = function_body(self.source, RELEASE_METHOD)
        self.assertIn("CLCompatInflowStageReleaseWaiting", body)
        self.assertIn("CLCompatInflowRestoreAfterRelease", body)
        self.assertIn("setInflowStatus:YES", release_body)

    def test_release_write_failure_is_error(self):
        """释放写入失败 → Error（测不了），不是无法支持。"""
        release_body = function_body(self.source, RELEASE_METHOD)
        self.assertIn("CLCompatTestVerdictError", release_body)
        self.assertIn("释放禁流写入失败", release_body)

    def test_release_wait_timeout_unsupported(self):
        """释放后限期内未回到已充电 → 无法支持（周期不完整：可退出但无法恢复）。"""
        body = self.inflow_body()
        self.assertIn("CLCompatInflowReleaseWait", body)
        self.assertIn("禁流可生效但释放后无法恢复充电", body)

    def test_monitor_limit_timeout_unsupported(self):
        """120 秒内始终充电（从未出现未充电样本）→ 无法支持（禁流写无效果）。"""
        body = self.inflow_body()
        self.assertIn("CLCompatMonitorLimit", body)
        self.assertIn("禁流写未生效：120 秒内未能退出充电状态", body)

    # ---- 停充回归 ----

    def test_stop_charge_verdict_keeps_current_basis(self):
        """停充/智能停充判定保持电流口径（IsCharging 翻转是写入伪迹，电流才是效果证据）。"""
        body = function_body(self.source, HANDLE_SAMPLE)
        self.assertIn("CLCompatCurrentThresholdmA", body)
        self.assertIn("(self.bCharging && !isCharging)", body)
        # 三信号 OR 已移入历史：停充等待分支不混入
        self.assertNotIn("bExtConnected && !extConnected", body)

    # ---- 结果展示 ----

    def test_event_carries_state_cycle_fields(self):
        """判定事件携带状态口径字段（退出/返回耗时、恢复方式）。"""
        self.assertIn("exitElapsed", self.source)
        self.assertIn("returnElapsed", self.source)
        self.assertIn("restoreMode", self.source)

    def test_result_cards_kind_specific_rows(self):
        """禁流结果卡状态口径行；停充结果卡保持电流极值行。"""
        body = function_body(self.source, "- (void)setupResultCards")
        self.assertIn("退出充电", body)
        self.assertIn("恢复方式", body)
        self.assertIn("恢复充电", body)
        self.assertIn("判定窗口最大电流", body)

    def test_verdict_event_branches_by_kind(self):
        """applyVerdictEvent 按测试类型分支：禁流填状态口径，停充电流极值。"""
        body = function_body(self.source, "- (void)applyVerdictEvent:(CLCompatTestEvent *)event")
        self.assertIn("CLCompatTestKindInflow", body)
        self.assertIn("系统自愈", body)
        self.assertIn("释放后恢复", body)

    # ---- 文案 ----

    def test_new_strings_present_both_languages(self):
        """判定文案在 zh-Hans 与 en 双语齐全。"""
        new_keys = [
            "禁流写未生效：120 秒内未能退出充电状态",
            "禁流可生效但释放后无法恢复充电",
            "禁流维持中，正在释放并等待恢复充电…",
            "释放禁流写入失败",
            "退出充电耗时 %ds",
            "恢复耗时 %ds",
            "系统自愈",
            "释放后恢复",
            "检测到退出充电（%ds）",
        ]
        for key in new_keys:
            self.assertIn(f'"{key}"', self.zh, f"zh 缺 key: {key}")
            self.assertIn(f'"{key}"', self.en, f"en 缺 key: {key}")

    def test_obsolete_strings_removed(self):
        """旧口径文案（无法维持/被系统恢复重发/退出未确认重发/无法确认生效）不再出现。"""
        for obsolete in ("禁流无法维持：充电被系统恢复且重试已耗尽",
                         "禁流被系统恢复，正在重新下发禁流（第 %d 次）",
                         "禁流退出未确认，正在重新下发禁流（第 %d 次）",
                         "无法确认禁流生效：退出信号被系统立即恢复且重试已耗尽"):
            self.assertNotIn(f'"{obsolete}"', self.zh)
            self.assertNotIn(f'"{obsolete}"', self.en)

    def test_intro_tip_reflects_state_cycle_judgment(self):
        """页面说明保持状态翻转口径的拔线提醒。"""
        new_tip = "测试期间请勿拔掉充电线：禁流判定依据充电状态的退出与返回翻转，拔线会造成误判。"
        self.assertIn(f'"{new_tip}"', self.zh)
        self.assertIn(f'"{new_tip}"', self.en)


if __name__ == "__main__":
    unittest.main()

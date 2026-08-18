import unittest

from _helpers import REPO_ROOT, source_for, function_body
DAEMON_PATH = REPO_ROOT / "ChargeLimiter" / "daemon.mm"


class Ios17InflowFlickerGuardTests(unittest.TestCase):
    """iOS 17 禁流稳态下 ExternalConnected/ExternalChargeCapable 派生抖动误发 noti_start_charge 的守卫测试。

    背景：iOS 17 禁流改写 override key（FieldDiagsInflowInhibit/OBCInflowInhibit）后，
    ExternalConnected/ExternalChargeCapable 由系统间接派生，息屏周期性刷新会抖动，
    被 isAdaptorNewConnect 边沿判定当插电信号误发"开始充电"通知。
    """

    def setUp(self):
        self.source = source_for(DAEMON_PATH)

    def test_inflow_guard_helper_exists_and_uses_semantic_state(self):
        """禁流态守卫用语义判定：adv_disable_inflow=YES 或 g_policyState 为 no_inflow/temp_paused。"""
        body = function_body(self.source, "static BOOL isInflowGuardActive(BOOL advDisableInflow, NSString* policyState)")
        self.assertIn("advDisableInflow", body)
        self.assertIn("no_inflow", body)
        self.assertIn("temp_paused", body)
        # 不引入时间窗口常量
        self.assertNotIn("g_lastInflowCommandTs", body)

    def test_isAdaptorConnect_uses_inflow_guard_when_not_user_disabled(self):
        """用户未开 adv_disable_inflow 时，禁流态（policy=no_inflow/temp_paused）也走 AdapterDetails 分支。"""
        body = function_body(self.source, "static BOOL isAdaptorConnect(NSDictionary* info, NSNumber* disableInflow)")
        self.assertIn("isInflowGuardActive(NO, g_policyState)", body)
        self.assertIn("AdapterDetails", body)
        self.assertIn("Description", body)
        self.assertIn("batt", body)

    def test_isAdaptorNewConnect_suppresses_edge_in_inflow_state(self):
        """禁流态下 isAdaptorNewConnect 抑制 false→true 伪边沿，避免抖动产生伪插电信号。"""
        body = function_body(self.source, "static BOOL isAdaptorNewConnect(NSDictionary* oldInfo, NSDictionary* info, NSNumber* disableInflow)")
        self.assertIn("isInflowGuardActive", body)
        # 禁流态直接返回 NO，不走边沿判定
        guard_idx = body.find("isInflowGuardActive")
        return_idx = body.find("return NO", guard_idx)
        self.assertGreater(return_idx, -1, "禁流态守卫必须有 return NO 抑制边沿")

    def test_freshPlug_gate_suppressed_in_inflow_state(self):
        """freshPlug 门禁：禁流态（当前或上一轮）不单凭 bool 跳变发 noti_start_charge。"""
        body = function_body(
            self.source,
            "static NSString* notificationMessageIDForChargeCommandTransition(BOOL previousExternalConnected",
        )
        # freshPlug 分支内必须调用守卫
        freshplug_idx = body.find("BOOL freshPlug")
        self.assertGreater(freshplug_idx, -1)
        guard_idx = body.find("isInflowGuardActive", freshplug_idx)
        self.assertGreater(guard_idx, -1, "freshPlug 分支必须有禁流态守卫")
        # 守卫命中时返回 nil，不发 noti_start_charge
        return_nil_after_guard = body.find("return nil", guard_idx)
        self.assertGreater(return_nil_after_guard, -1, "禁流态守卫命中时必须返回 nil")

    def test_inflow_guard_does_not_block_temperature_resume(self):
        """热控恢复 noti_resume_charge_temperature 走 stillPlugged 分支，不被 freshPlug 守卫误抑制。"""
        body = function_body(
            self.source,
            "static NSString* notificationMessageIDForChargeCommandTransition(BOOL previousExternalConnected",
        )
        # temperature_recovered 路径仍存在
        self.assertIn("temperature_recovered", body)
        self.assertIn("noti_resume_charge_temperature", body)


if __name__ == "__main__":
    unittest.main()

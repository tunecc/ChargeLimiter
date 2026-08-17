import re
import unittest
from pathlib import Path

SRC = (Path(__file__).resolve().parents[2] / "ChargeLimiter" / "daemon.mm").read_text(
    encoding="utf-8"
)


class TestAccchargeLpmBootstrapTrigger(unittest.TestCase):
    """重越狱 / 重启用户空间后未开 APP 时加速充电 LPM 不生效的回归保护。

    根因：commit 049b9bc 把加速项「首次应用」收敛到「进入充电态的命令翻转
    分支」(plug_mode_start / capacity_low 等)，但 userspace reboot 后已插电
    稳态无新边沿，命令翻转分支不触发，g_accChargeAppliedThisSession 保持
    NO，加速项不被首次应用。修复需补 bootstrap 与首个电池事件的兜底首次
    应用路径，且必须不重新引入「稳态重申首次应用」导致的「开 app 秒进 LPM」。
    """

    def _serve_body(self):
        m = re.search(r"-\s*\(void\)serve\s*\{.*?\n@end", SRC, re.S)
        self.assertIsNotNone(m, "未能定位 -[Service serve] 实现")
        return m.group(0)

    def _onBatteryEvent_body(self):
        m = re.search(
            r"static void onBatteryEvent\(io_service_t serv\)\s*\{.*?\n\}",
            SRC,
            re.S,
        )
        self.assertIsNotNone(m, "未能定位 onBatteryEvent 实现")
        return m.group(0)

    def _helper_body(self):
        m = re.search(
            r"static void applyBootstrapAccChargeIfNeeded\(NSDictionary\* info, NSString\* policyState\)\s*\{.*?\n\}",
            SRC,
            re.S,
        )
        self.assertIsNotNone(m, "未能定位 applyBootstrapAccChargeIfNeeded 实现")
        return m.group(0)

    def test_serve_has_bootstrap_acccharge_trigger(self):
        """serve() 末尾须有 bootstrap 兜底首次应用：充电稳态 + 标志 NO 时调用
        performAcccharge(YES)。兜底调用可封装在辅助函数内（applyBootstrapAccChargeIfNeeded），
        故允许 serve() 内通过该辅助函数间接调用 —— 断言存在该辅助函数、其内部
        调用 performAcccharge(YES)、且 serve() 与 onBatteryEvent 均调用它。"""
        body = self._strip_comments(self._serve_body())
        self.assertIn("applyBootstrapAccChargeIfNeeded", body)
        helper = self._strip_comments(self._helper_body())
        # 兜底调用必须存在
        self.assertIn("performAcccharge(YES)", helper)
        # 必须前置充电稳态条件（适配器连接）
        self.assertRegex(helper, r"is_adaptor_connected")
        # 必须前置 g_accChargeAppliedThisSession 守卫，避免覆盖幂等守卫语义
        self.assertRegex(helper, r"g_accChargeAppliedThisSession")
        # 必须前置 acc_charge 开关，避免加速充电总开关关闭时也触发
        self.assertRegex(helper, r"acc_charge\b")

    def test_onBatteryEvent_has_acccharge_trigger(self):
        """onBatteryEvent 内须有充电稳态兜底：IORegistry 延迟就绪时，首个
        电池事件补齐首次应用。前置 is_adaptor_connected 避免未插电误开 LPM。"""
        body = self._strip_comments(self._onBatteryEvent_body())
        self.assertIn("applyBootstrapAccChargeIfNeeded", body)

    @staticmethod
    def _strip_comments(text):
        # 去掉行注释与块注释，避免注释里的字样被当作代码断言
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"//[^\n]*", "", text)
        return text

    def test_steady_reassert_still_gated_by_session_flag(self):
        """稳态重申段必须仍以 g_accChargeAppliedThisSession == YES 为前置条件，
        不调用 performAcccharge(YES)，避免重新引入「开 app 秒进 LPM」回归。"""
        # 截取稳态重申段：从 "} while(false);" 之后到 "if (is_adaptor_new_disconnected)"
        start = SRC.find("} while(false);")
        self.assertGreater(start, 0)
        end = SRC.find("if (is_adaptor_new_disconnected)", start)
        self.assertGreater(end, 0)
        seg = self._strip_comments(SRC[start:end])
        self.assertIn("g_accChargeAppliedThisSession", seg)
        self.assertNotIn("performAcccharge(YES)", seg)
        # 仍按需重拉被外部清除的 LPM
        self.assertIn("setLPMEnable(YES)", seg)


if __name__ == "__main__":
    unittest.main()

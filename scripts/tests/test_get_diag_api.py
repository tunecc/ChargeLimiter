import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DAEMON = REPO / "ChargeLimiter" / "daemon.mm"


class GetDiagApiContractTests(unittest.TestCase):
    def setUp(self):
        self.src = DAEMON.read_text(encoding="utf-8")

    def test_helper_exists(self):
        self.assertRegex(
            self.src,
            r"static\s+NSDictionary\s*\*\s*getIOPMPSServDiagnostics\s*\(\s*void\s*\)",
        )

    def test_handle_req_get_diag_branch(self):
        self.assertIn('@"get_diag"', self.src)
        # 分支必须返回 status + data
        idx = self.src.find('@"get_diag"')
        body = self.src[idx : idx + 800]
        self.assertIn('"status"', body)
        self.assertIn('"data"', body)

    def test_helper_is_readonly_no_set_properties(self):
        start = self.src.find("getIOPMPSServDiagnostics")
        self.assertGreater(start, -1)
        # 取函数体到下一个 static/函数边界
        body = self.src[start : start + 2500]
        self.assertNotIn("IORegistryEntrySetCFProperties", body)
        self.assertNotIn("exit(", body)
        self.assertNotIn("kill(", body)
        # 允许读 getIOPMPSServ / IORegistryEntryCreateCFProperties
        self.assertIn("IORegistryEntryCreateCFProperties", body)

    def test_helper_reports_required_keys(self):
        start = self.src.find("getIOPMPSServDiagnostics")
        body = self.src[start : start + 2500]
        for key in [
            "service_name",
            "published_keys",
            "key_present",
            "iokit_return",
            "use_smart",
            "serv_boot",
            "libjailbreak_loaded",
            "jbtype",
        ]:
            self.assertIn(f'@"{key}"', body, f"missing data key {key}")

    def test_key_present_checks_five_critical(self):
        start = self.src.find("getIOPMPSServDiagnostics")
        body = self.src[start : start + 2500]
        for k in ["CurrentCapacity", "Amperage", "Voltage", "IsCharging", "Temperature"]:
            self.assertIn(f'@"{k}"', body)


if __name__ == "__main__":
    unittest.main()

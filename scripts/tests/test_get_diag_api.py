import re
import unittest

from _helpers import REPO_ROOT as REPO, function_body, source_for
DAEMON = REPO / "ChargeLimiter" / "daemon.mm"


class GetDiagApiContractTests(unittest.TestCase):
    def setUp(self):
        self.src = source_for(DAEMON)
        self.body = function_body(self.src, "getIOPMPSServDiagnostics")

    def test_helper_exists(self):
        self.assertRegex(
            self.src,
            r"static\s+NSDictionary\s*\*\s*getIOPMPSServDiagnostics\s*\(\s*void\s*\)",
        )

    def test_handle_req_get_diag_branch(self):
        self.assertIn('@"get_diag"', self.src)
        idx = self.src.find('@"get_diag"')
        body = self.src[idx : idx + 800]
        self.assertIn('"status"', body)
        self.assertIn('"data"', body)

    def test_helper_is_readonly_no_set_properties(self):
        self.assertNotIn("IORegistryEntrySetCFProperties", self.body)
        self.assertNotIn("exit(", self.body)
        self.assertNotIn("kill(", self.body)
        self.assertIn("IORegistryEntryCreateCFProperties", self.body)

    def test_helper_reports_required_keys(self):
        for key in [
            "service_name",
            "published_keys",
            "key_present",
            "iokit_return",
            "use_smart",
            "serv_boot",
            "libjailbreak_loaded",
            "libjailbreak_status",
            "exe_path",
            "data_root",
            "current_capacity",
            "jbtype",
        ]:
            self.assertIn(f'@"{key}"', self.body, f"missing data key {key}")

    def test_key_present_checks_five_critical(self):
        for k in ["CurrentCapacity", "Amperage", "Voltage", "IsCharging", "Temperature"]:
            self.assertIn(f'@"{k}"', self.body)


if __name__ == "__main__":
    unittest.main()

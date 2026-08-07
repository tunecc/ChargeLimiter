import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DAEMON = REPO / "ChargeLimiter" / "daemon.mm"


def _helper_body(src: str) -> str:
    """Slice getIOPMPSServDiagnostics body up to the next top-level static function."""
    start = src.find("static NSDictionary* getIOPMPSServDiagnostics")
    if start < 0:
        start = src.find("getIOPMPSServDiagnostics")
    assert start >= 0
    # Find opening brace of this function
    brace = src.find("{", start)
    assert brace > start
    depth = 0
    i = brace
    while i < len(src):
        ch = src[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[start : i + 1]
        i += 1
    return src[start : start + 8000]


class GetDiagApiContractTests(unittest.TestCase):
    def setUp(self):
        self.src = DAEMON.read_text(encoding="utf-8")
        self.body = _helper_body(self.src)

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

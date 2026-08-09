# scripts/tests/test_daemon_link_bridge.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
U = REPO / "ChargeLimiter" / "utils.mm"


class DaemonLinkBridgeTests(unittest.TestCase):
    def setUp(self):
        self.u = U.read_text(encoding="utf-8") if U.exists() else ""

    def test_log_path_export(self):
        self.assertIn("getLogPath_C", self.u)

    def test_daemon_path_helper(self):
        self.assertIn("CLDaemonPathForApp", self.u)

    def test_jbroot_helper(self):
        self.assertIn("CLDaemonJbRootPath", self.u)

    def test_log_tail_helper(self):
        self.assertIn("CLReadDaemonLogTail", self.u)


if __name__ == "__main__":
    unittest.main()
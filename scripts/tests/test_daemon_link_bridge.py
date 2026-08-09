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

    def test_probe_is_read_only(self):
        idx = self.u.find("clDaemonLaunchProbe_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for kw in ("killall", "launchctl", "bootout", "bootstrap", "posix_spawn"):
            self.assertNotIn(kw, body, f"探针只读，不应含 {kw}")

    def test_probe_returns_keys(self):
        idx = self.u.find("clDaemonLaunchProbe_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for key in ("daemon_path", "daemon_exists", "initial_port_open", "log_tail"):
            self.assertIn(f'@"{key}"', body, f"probe 缺 key {key}")


if __name__ == "__main__":
    unittest.main()
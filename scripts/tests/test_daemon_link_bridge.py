# scripts/tests/test_daemon_link_bridge.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
U = REPO / "ChargeLimiter" / "utils.mm"
SERVER = REPO / "ChargeLimiter" / "CLSimpleHTTPServer.m"
DAEMON = REPO / "ChargeLimiter" / "daemon.mm"


class DaemonLinkBridgeTests(unittest.TestCase):
    def setUp(self):
        self.u = U.read_text(encoding="utf-8") if U.exists() else ""
        self.server = SERVER.read_text(encoding="utf-8") if SERVER.exists() else ""
        self.daemon = DAEMON.read_text(encoding="utf-8") if DAEMON.exists() else ""

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
        for key in ("daemon_path", "daemon_exists", "initial_port_open",
                    "log_path", "log_exists", "log_tail"):
            self.assertIn(f'@"{key}"', body, f"probe 缺 key {key}")

    def test_probe_returns_process_file_and_port_evidence(self):
        idx = self.u.find("clDaemonLaunchProbe_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for key in ("daemon_process_pid", "daemon_executable", "daemon_mode",
                    "daemon_owner_uid", "daemon_group_gid", "log_size",
                    "log_mtime", "log_read_error", "log_writable",
                    "log_parent_writable", "log_mode", "log_owner_uid",
                    "port_probe"):
            self.assertIn(f'@"{key}"', body, f"probe 缺运行证据 {key}")

    def test_local_port_probe_records_socket_boundaries(self):
        self.assertIn("CLLocalPortProbe", self.u)
        for key in ("socket_errno", "connect_rc", "connect_errno",
                    "select_rc", "select_errno", "so_error"):
            self.assertIn(f'@"{key}"', self.u)

    def test_repair_export_and_steps(self):
        self.assertIn("clRepairDaemonForApp_C", self.u)
        idx = self.u.find("clRepairDaemonForApp_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for kw in ("killall", "launchctl", "bootstrap", "--app-docs"):
            self.assertIn(kw, body, f"repair 应含 {kw}")

    def test_repair_returns_keys(self):
        idx = self.u.find("clRepairDaemonForApp_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for key in ("repair_result", "root_spawn_rc", "nonroot_spawn_rc",
                    "port_after_spawn", "final_port_open", "log_tail"):
            self.assertIn(f'@"{key}"', body, f"repair 缺 key {key}")

    def test_repair_records_child_lifecycle(self):
        idx = self.u.find("clRepairDaemonForApp_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for key in ("root_spawn_pid", "nonroot_spawn_pid", "child_alive",
                    "child_wait_status", "child_exit_code", "child_signal",
                    "child_probe_errno"):
            self.assertIn(f'@"{key}"', body, f"repair 缺子进程字段 {key}")
        self.assertIn("waitpid", self.u)

    def test_repair_records_launchctl_candidates(self):
        idx = self.u.find("clRepairDaemonForApp_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for key in ("launchctl_path", "launchctl_exists", "plist_candidates",
                    "plist_existing", "launchctl_path_candidates",
                    "launchctl_print_attempted", "launchctl_print_rc",
                    "launchctl_print_out", "kill_rc"):
            self.assertIn(f'@"{key}"', body, f"repair 缺 launchd 字段 {key}")

    def test_repair_waits_for_killall_before_spawn(self):
        start = self.u.find("// 1) 杀残留 daemon")
        end = self.u.find("// 2) spawn daemon", start)
        section = self.u[start:end] if start >= 0 and end > start else ""
        self.assertIn("killall", section)
        self.assertNotIn("SPAWN_FLAG_NOWAIT", section)

    def test_socket_start_reports_each_failure_stage(self):
        for stage in ("socket", "setsockopt", "bind", "listen"):
            self.assertIn(stage, self.server, f"缺少 {stage} 阶段诊断")
        self.assertIn("errno", self.server)
        self.assertIn("strerror", self.server)

    def test_socket_start_reports_ready_context(self):
        self.assertIn("listen_ready", self.server)
        self.assertIn("getuid", self.server)
        self.assertIn("geteuid", self.server)
        self.assertIn("getpid", self.server)

    def test_daemon_logs_structured_server_failure(self):
        self.assertIn("NSFileErrorLog", self.daemon)
        self.assertIn("serve failed", self.daemon)
        self.assertIn("startup_stage", self.daemon)

    def test_daemon_retries_only_address_in_use(self):
        self.assertIn("EADDRINUSE", self.daemon)
        self.assertIn("usleep", self.daemon)

    def test_daemon_records_entry_privilege_and_codesign(self):
        self.assertIn("daemon_entry", self.daemon)
        self.assertIn("platformize_rc", self.daemon)
        self.assertIn("memlimit_rc", self.daemon)
        self.assertIn("csops_rc", self.daemon)
        self.assertIn("csflags", self.daemon)

    def test_daemon_file_log_avoids_raw_executable_path(self):
        self.assertNotIn(" exe=%@", self.daemon)


if __name__ == "__main__":
    unittest.main()

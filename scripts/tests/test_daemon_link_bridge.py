# scripts/tests/test_daemon_link_bridge.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
U = REPO / "ChargeLimiter" / "utils.mm"
U_H = REPO / "ChargeLimiter" / "utils.h"
SERVER = REPO / "ChargeLimiter" / "CLSimpleHTTPServer.m"
DAEMON = REPO / "ChargeLimiter" / "daemon.mm"
UI = REPO / "ChargeLimiter" / "ui.mm"


class DaemonLinkBridgeTests(unittest.TestCase):
    def setUp(self):
        self.u = U.read_text(encoding="utf-8") if U.exists() else ""
        self.u_h = U_H.read_text(encoding="utf-8") if U_H.exists() else ""
        self.server = SERVER.read_text(encoding="utf-8") if SERVER.exists() else ""
        self.daemon = DAEMON.read_text(encoding="utf-8") if DAEMON.exists() else ""
        self.ui = UI.read_text(encoding="utf-8") if UI.exists() else ""

    def test_log_path_export(self):
        # getLogPath_C（dlsym 时代的 C 链接导出）已在 8a22707 改直接调用后无调用者，
        # 实际 app 侧日志路径走 clDaemonLaunchProbe_C 的 log_path 键（test_probe_returns_keys 覆盖）。
        # 这里断言存活的日志路径函数仍导出。
        self.assertIn("getLogPath()", self.u)

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

    def test_roothide_launchdaemon_plist_self_heal_contract(self):
        self.assertIn("CLRepairRoothideLaunchDaemonPlist", self.u_h)
        start = self.u.find("int CLRepairRoothideLaunchDaemonPlist(void)")
        end = self.u.find("static NSString* resolveRoothidePathByAPI", start)
        body = self.u[start:end] if start >= 0 and end > start else ""
        self.assertTrue(body)
        for token in (
            "JBTYPE_ROOTHIDE",
            "geteuid()",
            "resolveJbRootFromSelfExe()",
            '@"/Applications/ChargeLimiter.app/ChargeLimiterDaemon"',
            '@"Library/LaunchDaemons/com.chargelimiter.mod.plist"',
            "NSPropertyListSerialization",
            '@"Program"',
            '@"ProgramArguments"',
            "isKindOfClass:[NSString class]",
            "isKindOfClass:[NSArray class]",
            "chown(",
            "chmod(",
        ):
            self.assertIn(token, body)

    def test_daemon_repairs_roothide_plist_after_platformize_before_serve(self):
        main_start = self.daemon.find("int main(int argc, char** argv) { // daemon_main")
        main = self.daemon[main_start:] if main_start >= 0 else ""
        platformize = main.find("platformize_me()")
        repair = main.find("CLRepairRoothideLaunchDaemonPlist()")
        serve = main.find("[Service.inst serve]")
        self.assertGreaterEqual(platformize, 0)
        self.assertGreater(repair, platformize)
        self.assertGreater(serve, repair)

    def test_url_scheme_charge_commands_use_daemon_run(self):
        self.assertIn('daemonRun(@[@"set_charge", @"1"]);', self.ui)
        self.assertIn('daemonRun(@[@"set_charge", @"0"]);', self.ui)

    def test_daemon_run_avoids_root_persona_on_roothide(self):
        start = self.ui.find("void daemonRun(NSArray* argv)")
        end = self.ui.find("static void start_daemon()", start)
        body = self.ui[start:end] if start >= 0 and end > start else ""
        self.assertIn("g_jbtype != JBTYPE_TROLLSTORE", body)
        self.assertIn("g_jbtype != JBTYPE_ROOTHIDE", body)
        self.assertIn("spawnFlags |= SPAWN_FLAG_ROOT", body)

    def test_daemon_file_log_avoids_raw_executable_path(self):
        self.assertNotIn(" exe=%@", self.daemon)


if __name__ == "__main__":
    unittest.main()

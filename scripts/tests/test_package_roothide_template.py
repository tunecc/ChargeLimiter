import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


from _helpers import REPO_ROOT, source_for
ROOTHIDE_CTRL = REPO_ROOT / "ChargeLimiter/Package_roothide/DEBIAN/control"
ROOTHIDE_POST = REPO_ROOT / "ChargeLimiter/Package_roothide/DEBIAN/postinst"
ROOTHIDE_PRERM = REPO_ROOT / "ChargeLimiter/Package_roothide/DEBIAN/prerm"
ROOTFUL_POSTRM = REPO_ROOT / "ChargeLimiter/Package/DEBIAN/postrm"
ROOTFUL_PLIST = REPO_ROOT / "ChargeLimiter/Package/Library/LaunchDaemons/com.chargelimiter.mod.plist"
BUILD_SCRIPT = REPO_ROOT / "scripts/build_packages.sh"


class PackageRoothideTemplateTests(unittest.TestCase):
    def run_postinst(self, *, real_daemon=None, plutil_status=0,
                     bootstrap_status=0, load_status=0, include_jbroot=True):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            call_log = tmp_path / "calls.log"

            commands = ["chown", "chmod", "killall", "rm", "plutil", "launchctl", "uicache"]
            if include_jbroot:
                commands.append("jbroot")

            mock = """#!/bin/sh
printf '%s %s\\n' "${0##*/}" "$*" >> "$MOCK_CALL_LOG"
case "${0##*/}:$1" in
    jbroot:*) printf '%s\\n' "$MOCK_REAL_DAEMON"; exit "$MOCK_JBROOT_STATUS" ;;
    plutil:*)
        case " $* " in
            *" -json "*) exit 64 ;;
        esac
        exit "$MOCK_PLUTIL_STATUS"
        ;;
    launchctl:bootstrap) exit "$MOCK_BOOTSTRAP_STATUS" ;;
    launchctl:load) exit "$MOCK_LOAD_STATUS" ;;
esac
exit 0
"""
            for command in commands:
                command_path = bin_dir / command
                command_path.write_text(mock, encoding="utf-8")
                command_path.chmod(0o755)

            if real_daemon is None:
                real_daemon_path = tmp_path / "rootfs/.jbroot-TEST/Applications/ChargeLimiter.app/ChargeLimiterDaemon"
            else:
                real_daemon_path = tmp_path / real_daemon
            real_daemon_path.parent.mkdir(parents=True, exist_ok=True)
            real_daemon_path.write_text("#!/bin/sh\n", encoding="utf-8")
            real_daemon_path.chmod(0o755)

            env = os.environ.copy()
            env.update({
                "PATH": str(bin_dir),
                "MOCK_CALL_LOG": str(call_log),
                "MOCK_REAL_DAEMON": str(real_daemon_path),
                "MOCK_JBROOT_STATUS": "0",
                "MOCK_PLUTIL_STATUS": str(plutil_status),
                "MOCK_BOOTSTRAP_STATUS": str(bootstrap_status),
                "MOCK_LOAD_STATUS": str(load_status),
            })
            result = subprocess.run(
                ["/bin/sh", str(ROOTHIDE_POST)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            calls = call_log.read_text(encoding="utf-8") if call_log.exists() else ""
            return result, calls

    def run_prerm(self, *, rooted_data_path=None, daemon_cleanup_status=1):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            call_log = tmp_path / "calls.log"
            app_dir = tmp_path / "Applications/ChargeLimiter.app"
            app_dir.mkdir(parents=True)
            daemon = app_dir / "ChargeLimiterDaemon"
            daemon.write_text(
                """#!/bin/sh
printf 'daemon %s\\n' "$*" >> "$MOCK_CALL_LOG"
[ "$1" = "cleanup_data_container" ] && exit "$MOCK_DAEMON_CLEANUP_STATUS"
exit 0
""",
                encoding="utf-8",
            )
            daemon.chmod(0o755)

            if rooted_data_path is None:
                data_dir = tmp_path / "rootfs/.jbroot-TEST/var/mobile/ChargeLimiter"
            else:
                data_dir = tmp_path / rooted_data_path
            data_dir.mkdir(parents=True)
            (data_dir / "aldente.log").write_text("test\n", encoding="utf-8")

            mock = """#!/bin/sh
printf '%s %s\\n' "${0##*/}" "$*" >> "$MOCK_CALL_LOG"
if [ "${0##*/}" = "jbroot" ]; then
    printf '%s\\n' "$MOCK_ROOTED_DATA_PATH"
fi
exit 0
"""
            for command in ("launchctl", "killall", "uicache", "jbroot"):
                command_path = bin_dir / command
                command_path.write_text(mock, encoding="utf-8")
                command_path.chmod(0o755)

            plist_path = tmp_path / "Library/LaunchDaemons/com.chargelimiter.mod.plist"
            cache_path = tmp_path / "var/mobile/Library/Preferences/containerpath"
            script = source_for(ROOTHIDE_PRERM)
            script = script.replace(
                'APP_DIR="/Applications/ChargeLimiter.app"',
                f'APP_DIR="{app_dir}"',
            ).replace(
                'DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"',
                f'DAEMON_PLIST="{plist_path}"',
            ).replace(
                'CACHE="/var/mobile/Library/Preferences/com.chargelimiter.mod.containerpath"',
                f'CACHE="{cache_path}"',
            )
            script_path = tmp_path / "prerm"
            script_path.write_text(script, encoding="utf-8")
            script_path.chmod(0o755)

            env = os.environ.copy()
            env.update({
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "MOCK_CALL_LOG": str(call_log),
                "MOCK_ROOTED_DATA_PATH": str(data_dir),
                "MOCK_DAEMON_CLEANUP_STATUS": str(daemon_cleanup_status),
            })
            result = subprocess.run(
                ["/bin/sh", str(script_path), "remove"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            calls = call_log.read_text(encoding="utf-8") if call_log.exists() else ""
            return result, data_dir.exists(), calls

    def test_control_arch(self):
        c = source_for(ROOTHIDE_CTRL)
        self.assertIn("Architecture: iphoneos-arm64e", c)
        self.assertIn("Package: com.chargelimiter.mod", c)

    def test_postinst_permissions_and_paths(self):
        s = source_for(ROOTHIDE_POST)
        self.assertIn('APP_DIR="/Applications/ChargeLimiter.app"', s)
        self.assertIn('DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"', s)
        self.assertIn("repair_shared_data_permissions", s)

    def test_shared_roothide_files_are_staged_from_rootful_canonical(self):
        script = source_for(BUILD_SCRIPT)
        self.assertIn('cp -p "$PKG_ROOTFUL_DIR/DEBIAN/postrm" "$STAGE_ROOTHIDE_DIR/DEBIAN/postrm"', script)
        self.assertIn('"$PKG_ROOTFUL_DIR/Library/LaunchDaemons/com.chargelimiter.mod.plist"', script)
        self.assertIn('chmod 755 "$STAGE_ROOTHIDE_DIR/DEBIAN/postrm"', script)
        self.assertIn('chmod 644 "$STAGE_ROOTHIDE_DIR/Library/LaunchDaemons/com.chargelimiter.mod.plist"', script)

    def test_shared_roothide_files_match_rootful_canonical(self):
        self.assertTrue(ROOTFUL_POSTRM.exists())
        self.assertTrue(ROOTFUL_PLIST.exists())
        self.assertIn("uicache -p", source_for(ROOTFUL_POSTRM))
        self.assertIn("/Applications/ChargeLimiter.app/ChargeLimiterDaemon", source_for(ROOTFUL_PLIST))
        self.assertNotIn("/var/jb/", source_for(ROOTFUL_PLIST))

    def test_launchdaemon_rootful_shape(self):
        raw = ROOTFUL_PLIST.read_bytes()
        self.assertIn(b"/Applications/ChargeLimiter.app/ChargeLimiterDaemon", raw)
        self.assertNotIn(b"/var/jb/", raw)

    def test_postinst_rejects_missing_jbroot(self):
        result, _ = self.run_postinst(include_jbroot=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("jbroot", result.stderr)

    def test_postinst_uses_device_compatible_program_arguments_update(self):
        result, calls = self.run_postinst()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("plutil -replace ProgramArguments.0 -string", calls)
        self.assertNotIn(" -json ", calls)

    def test_postinst_rejects_invalid_physical_daemon_path(self):
        result, calls = self.run_postinst(
            real_daemon="rootfs/Applications/ChargeLimiter.app/ChargeLimiterDaemon"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid", result.stderr.lower())
        self.assertNotIn("launchctl bootstrap", calls)

    def test_postinst_fails_when_plist_update_fails(self):
        result, calls = self.run_postinst(plutil_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("plist", result.stderr.lower())
        self.assertNotIn("launchctl bootstrap", calls)

    def test_postinst_fails_when_launchctl_cannot_load_daemon(self):
        result, calls = self.run_postinst(bootstrap_status=1, load_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("launchctl", result.stderr.lower())
        self.assertIn("launchctl bootstrap", calls)
        self.assertIn("launchctl load", calls)

    def test_prerm_fallback_removes_valid_roothide_data_path(self):
        result, data_exists, calls = self.run_prerm()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(data_exists)
        self.assertIn("daemon cleanup_data_container", calls)
        self.assertIn("jbroot /var/mobile/ChargeLimiter", calls)
        self.assertNotIn("Failed to remove", result.stderr)

    def test_prerm_fallback_rejects_path_without_jbroot_marker(self):
        result, data_exists, _ = self.run_prerm(
            rooted_data_path="rootfs/var/mobile/ChargeLimiter"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(data_exists)
        self.assertIn("stage=resolve_roothide_data", result.stderr)


if __name__ == "__main__":
    unittest.main()

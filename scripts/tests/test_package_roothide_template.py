import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
ROOTHIDE_CTRL = REPO_ROOT / "ChargeLimiter/Package_roothide/DEBIAN/control"
ROOTHIDE_POST = REPO_ROOT / "ChargeLimiter/Package_roothide/DEBIAN/postinst"
ROOTHIDE_PLIST = REPO_ROOT / "ChargeLimiter/Package_roothide/Library/LaunchDaemons/com.chargelimiter.mod.plist"


class PackageRoothideTemplateTests(unittest.TestCase):
    def test_control_arch(self):
        c = ROOTHIDE_CTRL.read_text(encoding="utf-8")
        self.assertIn("Architecture: iphoneos-arm64e", c)
        self.assertIn("Package: com.chargelimiter.mod", c)

    def test_postinst_permissions_and_paths(self):
        s = ROOTHIDE_POST.read_text(encoding="utf-8")
        self.assertIn('APP_DIR="/Applications/ChargeLimiter.app"', s)
        self.assertIn('DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"', s)
        self.assertIn("repair_shared_data_permissions", s)
        self.assertIn("/var/mobile/ChargeLimiter", s)
        self.assertNotIn("/var/jb/", s)

    def test_launchdaemon_rootful_shape(self):
        raw = ROOTHIDE_PLIST.read_bytes()
        self.assertIn(b"/Applications/ChargeLimiter.app/ChargeLimiterDaemon", raw)
        self.assertNotIn(b"/var/jb/", raw)


if __name__ == "__main__":
    unittest.main()

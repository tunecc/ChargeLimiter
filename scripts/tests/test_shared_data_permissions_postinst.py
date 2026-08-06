import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
ROOTFUL_POSTINST = REPO_ROOT / "ChargeLimiter" / "Package" / "DEBIAN" / "postinst"
ROOTLESS_POSTINST = REPO_ROOT / "ChargeLimiter" / "Package_rootless" / "DEBIAN" / "postinst"
ROOTHIDE_POSTINST = REPO_ROOT / "ChargeLimiter" / "Package_roothide" / "DEBIAN" / "postinst"
BUILD_SCRIPT = REPO_ROOT / "scripts" / "build_packages.sh"


def convert_postinst_to_roothide(source: str) -> str:
    """Apply the maintainer-script rewriting rules used by build_packages.sh.

    Note: this conversion is legacy (rootless→roothide rewrite) and is no longer
    the default packaging path once native Package_roothide is used.
    """
    build_source = BUILD_SCRIPT.read_text(encoding="utf-8")
    start = build_source.index("rewrite_roothide_maintainer_script()")
    end = build_source.index("rewrite_roothide_launchdaemon_plist()", start)
    body = build_source[start:end]
    patterns = re.findall(r"-e 's\|([^|]*)\|([^|]*)\|g'", body)

    converted = source
    for old, new in patterns:
        converted = converted.replace(old, new)
    return converted


class SharedDataPermissionsPostinstTests(unittest.TestCase):
    def test_rootful_postinst_repairs_exact_shared_data_permissions(self):
        source = ROOTFUL_POSTINST.read_text(encoding="utf-8")

        self.assertIn('DATA_DIR="/var/mobile/ChargeLimiter"', source)
        self.assertRegex(source, r'chown mobile:mobile "\$DATA_DIR"')
        self.assertRegex(source, r'chmod 0750 "\$DATA_DIR"')
        self.assertRegex(source, r'chown mobile:mobile "\$conf_path"')
        self.assertRegex(source, r'chmod 0640 "\$conf_path"')
        self.assertIn("repair_shared_data_permissions", source)
        self.assertNotIn('chown -R mobile:mobile "$DATA_DIR"', source)

    def test_rootless_postinst_resolves_and_repairs_shared_data(self):
        source = ROOTLESS_POSTINST.read_text(encoding="utf-8")

        self.assertIn('DATA_DIR_LOGICAL="/var/mobile/ChargeLimiter"', source)
        self.assertRegex(source, r'\$cmd "\$DATA_DIR_LOGICAL"')
        self.assertRegex(source, r'chown mobile:mobile "\$data_root"')
        self.assertRegex(source, r'chmod 0750 "\$data_root"')
        self.assertRegex(source, r'chown mobile:mobile "\$conf_path"')
        self.assertRegex(source, r'chmod 0640 "\$conf_path"')
        self.assertNotIn('chown -R mobile:mobile "$data_root"', source)

    def test_roothide_postinst_repairs_shared_data_permissions(self):
        source = ROOTHIDE_POSTINST.read_text(encoding="utf-8")

        self.assertIn('DATA_DIR="/var/mobile/ChargeLimiter"', source)
        self.assertIn("repair_shared_data_permissions", source)
        self.assertRegex(source, r'chown mobile:mobile "\$DATA_DIR"')
        self.assertRegex(source, r'chmod 0750 "\$DATA_DIR"')
        self.assertRegex(source, r'chown mobile:mobile "\$conf_path"')
        self.assertRegex(source, r'chmod 0640 "\$conf_path"')
        self.assertNotIn('chown -R mobile:mobile "$DATA_DIR"', source)
        self.assertNotIn("/var/jb/", source)
        self.assertNotIn("/rootfs/var/mobile/ChargeLimiter", source)
        self.assertIn('APP_DIR="/Applications/ChargeLimiter.app"', source)
        self.assertIn('DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"', source)

    def test_roothide_conversion_preserves_jbroot_logical_data_path(self):
        # Legacy conversion still exercised for rootless→roothide rewrite path;
        # native Package_roothide is the preferred packaging source going forward.
        converted = convert_postinst_to_roothide(ROOTLESS_POSTINST.read_text(encoding="utf-8"))

        self.assertIn('DATA_DIR_LOGICAL="/var/mobile/ChargeLimiter"', converted)
        self.assertIn('$cmd "$DATA_DIR_LOGICAL"', converted)
        self.assertNotIn('/rootfs/var/mobile/ChargeLimiter', converted)
        self.assertIn('APP_DIR="/Applications/ChargeLimiter.app"', converted)
        self.assertIn('DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"', converted)


if __name__ == "__main__":
    unittest.main()

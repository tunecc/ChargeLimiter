import unittest


from _helpers import REPO_ROOT, source_for
ROOTFUL_POSTINST = REPO_ROOT / "ChargeLimiter" / "Package" / "DEBIAN" / "postinst"
ROOTLESS_POSTINST = REPO_ROOT / "ChargeLimiter" / "Package_rootless" / "DEBIAN" / "postinst"
ROOTHIDE_POSTINST = REPO_ROOT / "ChargeLimiter" / "Package_roothide" / "DEBIAN" / "postinst"


class SharedDataPermissionsPostinstTests(unittest.TestCase):
    def test_rootful_postinst_repairs_exact_shared_data_permissions(self):
        source = source_for(ROOTFUL_POSTINST)

        self.assertIn('DATA_DIR="/var/mobile/ChargeLimiter"', source)
        self.assertRegex(source, r'chown mobile:mobile "\$DATA_DIR"')
        self.assertRegex(source, r'chmod 0750 "\$DATA_DIR"')
        self.assertRegex(source, r'chown mobile:mobile "\$conf_path"')
        self.assertRegex(source, r'chmod 0640 "\$conf_path"')
        self.assertIn("repair_shared_data_permissions", source)
        self.assertNotIn('chown -R mobile:mobile "$DATA_DIR"', source)

    def test_rootless_postinst_resolves_and_repairs_shared_data(self):
        source = source_for(ROOTLESS_POSTINST)

        self.assertIn('DATA_DIR_LOGICAL="/var/mobile/ChargeLimiter"', source)
        self.assertRegex(source, r'\$cmd "\$DATA_DIR_LOGICAL"')
        self.assertRegex(source, r'chown mobile:mobile "\$data_root"')
        self.assertRegex(source, r'chmod 0750 "\$data_root"')
        self.assertRegex(source, r'chown mobile:mobile "\$conf_path"')
        self.assertRegex(source, r'chmod 0640 "\$conf_path"')
        self.assertNotIn('chown -R mobile:mobile "$data_root"', source)

    def test_roothide_postinst_repairs_shared_data_permissions(self):
        source = source_for(ROOTHIDE_POSTINST)

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


if __name__ == "__main__":
    unittest.main()

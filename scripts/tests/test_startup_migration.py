import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UI_MM = REPO_ROOT / "ChargeLimiter" / "ui.mm"
UTILS_MM = REPO_ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = REPO_ROOT / "ChargeLimiter" / "utils.h"


class StartupMigrationTests(unittest.TestCase):
    def test_shared_migrate_called_at_launch(self):
        s = UI_MM.read_text(encoding="utf-8")
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", s)
        self.assertIn("CLApplyLanguageFromSettings", s)
        self.assertNotIn("[[CLAppSettingsStore shared] migrateIfNeeded", s)

    def test_migration_failure_only_logs_no_save_alert(self):
        s = UI_MM.read_text(encoding="utf-8")
        # Failure path must log; must not present save-failed alert from the migration branch.
        self.assertIn("shared settings migration had write failures", s)
        launch_idx = s.find("didFinishLaunchingWithOptions")
        self.assertGreater(launch_idx, -1)
        launch_end = s.index("return YES", launch_idx)
        launch_block = s[launch_idx:launch_end]
        # Migration NO branch should not construct UIAlertController.
        migrate_idx = launch_block.find("CLMigrateAppSettingsToSharedStoreIfNeeded")
        self.assertGreater(migrate_idx, -1)
        after_migrate = launch_block[migrate_idx:]
        # Between migrate call and CLApplyLanguage, only NSLog2 is allowed for the failure path.
        apply_lang_idx = after_migrate.find("CLApplyLanguageFromSettings")
        self.assertGreater(apply_lang_idx, -1)
        between = after_migrate[:apply_lang_idx]
        self.assertNotIn("UIAlertController", between)
        self.assertNotIn("CLL(@\"保存失败\")", between)

    def test_migrate_function_declared_and_defined(self):
        h = UTILS_H.read_text(encoding="utf-8")
        mm = UTILS_MM.read_text(encoding="utf-8")
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", h)
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", mm)


if __name__ == "__main__":
    unittest.main()

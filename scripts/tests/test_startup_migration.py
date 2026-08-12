import unittest

from _helpers import REPO_ROOT, source_for
UI_MM = REPO_ROOT / "ChargeLimiter" / "ui.mm"
UTILS_MM = REPO_ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = REPO_ROOT / "ChargeLimiter" / "utils.h"


class StartupMigrationTests(unittest.TestCase):
    def test_shared_migrate_called_at_launch(self):
        s = source_for(UI_MM)
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", s)
        self.assertIn("CLApplyLanguageFromSettings", s)
        self.assertNotIn("[[CLAppSettingsStore shared] migrateIfNeeded", s)

    def test_migration_failure_only_logs_no_save_alert(self):
        s = source_for(UI_MM)
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
        h = source_for(UTILS_H)
        mm = source_for(UTILS_MM)
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", h)
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", mm)

    def test_migration_suppresses_config_write_failed_notification(self):
        """Migration write failure must not post CLConfigWriteFailedNotification.

        ui.mm registers the save-failed observer before migrate runs; without a
        suppress flag in apply, setlocalKVChecked failures during migration would
        still surface the user-facing save-failed alert. Contract:
        - a named suppress mechanism exists (CLSuppressConfigWriteFailedNotification)
        - migrate sets/clears it around writes
        - apply checks it before posting the notification
        """
        mm = source_for(UTILS_MM)
        self.assertIn(
            "CLSuppressConfigWriteFailedNotification",
            mm,
            "utils.mm must define a suppress flag for migration write failures",
        )

        migrate_idx = mm.find("BOOL CLMigrateAppSettingsToSharedStoreIfNeeded")
        self.assertGreater(migrate_idx, -1)
        # Next top-level function after migrate (extern "C" setlocalKV_C or similar)
        migrate_end = mm.find("\nextern \"C\"", migrate_idx + 1)
        if migrate_end < 0:
            migrate_end = mm.find("\nvoid reloadLocalKVFromDisk", migrate_idx + 1)
        self.assertGreater(migrate_end, migrate_idx)
        migrate_body = mm[migrate_idx:migrate_end]
        self.assertIn(
            "CLSuppressConfigWriteFailedNotification",
            migrate_body,
            "CLMigrateAppSettingsToSharedStoreIfNeeded must enable suppress around writes",
        )
        # Must not call setlocalKVChecked without suppress in scope of migration
        self.assertIn("setlocalKVChecked", migrate_body)

        apply_idx = mm.find("- (BOOL)apply")
        self.assertGreater(apply_idx, -1)
        post_idx = mm.find("postNotificationName:CLConfigWriteFailedNotification", apply_idx)
        self.assertGreater(post_idx, apply_idx)
        apply_fail_path = mm[apply_idx:post_idx]
        self.assertIn(
            "CLSuppressConfigWriteFailedNotification",
            apply_fail_path,
            "apply must check suppress flag before posting CLConfigWriteFailedNotification",
        )

    def test_migrate_sets_suppress_before_any_store_access(self):
        """Suppress must be YES before first getlocalKV/store touch in migrate.

        getlocalKV constructs CLSettingsStore and init may apply legacy
        UserDefaults migration; if suppress is still NO and UI already
        registered the save-failed observer, that apply can pop an alert.
        """
        import re

        mm = source_for(UTILS_MM)
        migrate_idx = mm.find("BOOL CLMigrateAppSettingsToSharedStoreIfNeeded")
        self.assertGreater(migrate_idx, -1)
        migrate_end = mm.find("\nextern \"C\"", migrate_idx + 1)
        if migrate_end < 0:
            migrate_end = mm.find("\nvoid reloadLocalKVFromDisk", migrate_idx + 1)
        body = mm[migrate_idx:migrate_end]

        suppress_on = body.find("CLSuppressConfigWriteFailedNotification = YES")
        self.assertGreater(
            suppress_on,
            -1,
            "migrate must set CLSuppressConfigWriteFailedNotification = YES",
        )
        # Match real calls only (ignore comments that mention getlocalKV).
        call_matches = list(re.finditer(r"(?<![\w/])getlocalKV\s*\(", body))
        self.assertTrue(call_matches, "migrate uses getlocalKV(...)")
        first_get = call_matches[0].start()
        self.assertLess(
            suppress_on,
            first_get,
            "suppress=YES must precede any getlocalKV (store init / apply side effects)",
        )
        self.assertIn("@finally", body, "suppress must be cleared in @finally")
        self.assertIn(
            "CLSuppressConfigWriteFailedNotification = NO",
            body,
            "migrate must clear suppress flag",
        )


if __name__ == "__main__":
    unittest.main()

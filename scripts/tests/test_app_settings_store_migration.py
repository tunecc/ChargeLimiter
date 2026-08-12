import re
import unittest

from _helpers import REPO_ROOT, source_for
UTILS_MM = REPO_ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = REPO_ROOT / "ChargeLimiter" / "utils.h"


class SharedStoreMigrationContractTests(unittest.TestCase):
    def test_migrate_function_exists_in_utils(self):
        h = source_for(UTILS_H)
        mm = source_for(UTILS_MM)
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", h)
        self.assertRegex(mm, r"BOOL\s+CLMigrateAppSettingsToSharedStoreIfNeeded\s*\(\s*void\s*\)")

    def test_four_keys_migrated_via_shared_kv(self):
        mm = source_for(UTILS_MM)
        # Locate the migration function body approximately.
        idx = mm.find("CLMigrateAppSettingsToSharedStoreIfNeeded")
        self.assertGreater(idx, -1)
        # Use a generous slice of the function region.
        body = mm[idx:idx + 4000]
        for key in ["AppLanguage", "AppAppearance", "SliderHapticStyle", "StopChargePresetValue"]:
            self.assertIn(f'@"{key}"', body, f"migration must handle key {key}")
        self.assertIn("setlocalKVChecked", body, "writes must go through setlocalKVChecked")
        self.assertIn("getlocalKV", body, "must check shared store before writing")

    def test_cascade_priority_appdata_then_standard_then_default(self):
        mm = source_for(UTILS_MM)
        idx = mm.find("CLMigrateAppSettingsToSharedStoreIfNeeded")
        self.assertGreater(idx, -1)
        body = mm[idx:idx + 4000]
        # Source cascade: appdata suite then standardUserDefaults.
        self.assertTrue(
            "com.chargelimiter.mod.appdata" in body or "getAppUserDefaults" in body,
            "must read old appdata suite",
        )
        self.assertIn("standardUserDefaults", body, "must fall back to standardUserDefaults")

    def test_migration_marker_and_old_suite_cleanup(self):
        mm = source_for(UTILS_MM)
        idx = mm.find("CLMigrateAppSettingsToSharedStoreIfNeeded")
        self.assertGreater(idx, -1)
        body = mm[idx:idx + 4000]
        self.assertIn("CLAppSettingsMigratedToShared", body, "must write shared migration marker")
        self.assertIn("removeObjectForKey", body, "must best-effort clear old suite keys")

    def test_returns_no_only_on_needed_write_failure(self):
        mm = source_for(UTILS_MM)
        idx = mm.find("CLMigrateAppSettingsToSharedStoreIfNeeded")
        self.assertGreater(idx, -1)
        body = mm[idx:idx + 4000]
        # Must have an explicit failure return when setlocalKVChecked fails.
        self.assertTrue(
            re.search(r"setlocalKVChecked[\s\S]{0,200}return\s+NO", body)
            or re.search(r"!\s*setlocalKVChecked[\s\S]{0,120}return\s+NO", body)
            or ("writeFailed" in body and "return NO" in body)
            or ("hadWriteFailure" in body and "return NO" in body),
            "must return NO when a required shared write fails",
        )
        # Success / empty path returns YES.
        self.assertIn("return YES", body)


if __name__ == "__main__":
    unittest.main()

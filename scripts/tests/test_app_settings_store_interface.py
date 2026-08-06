import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UTILS_MM = REPO_ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = REPO_ROOT / "ChargeLimiter" / "utils.h"
H = REPO_ROOT / "ChargeLimiter" / "UIKit" / "CLAppSettingsStore.h"
M = REPO_ROOT / "ChargeLimiter" / "UIKit" / "CLAppSettingsStore.m"
PBXPROJ = REPO_ROOT / "ChargeLimiter.xcodeproj" / "project.pbxproj"
TEST_APP = REPO_ROOT / "ChargeLimiter" / "UIKit" / "CLTestApp.m"


class AppSettingsStoreAbsentTests(unittest.TestCase):
    def test_store_files_removed(self):
        self.assertFalse(H.exists(), "CLAppSettingsStore.h must be removed")
        self.assertFalse(M.exists(), "CLAppSettingsStore.m must be removed")

    def test_shared_migration_remains_authoritative_in_utils(self):
        h = UTILS_H.read_text(encoding="utf-8")
        mm = UTILS_MM.read_text(encoding="utf-8")
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", h)
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", mm)
        self.assertIn("setlocalKVChecked", mm)

    def test_no_store_symbol_in_sources_or_pbxproj(self):
        mm = UTILS_MM.read_text(encoding="utf-8")
        test_app = TEST_APP.read_text(encoding="utf-8")
        pbx = PBXPROJ.read_text(encoding="utf-8")
        self.assertNotIn("CLAppSettingsStore", mm)
        self.assertNotIn("CLRunAppSettingsStoreSelfTest", mm)
        self.assertNotIn("CLAppSettingsStore", test_app)
        self.assertNotIn("CLRunAppSettingsStoreSelfTest", test_app)
        self.assertNotIn("CLAppSettingsStore", pbx)


if __name__ == "__main__":
    unittest.main()

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UTILS_MM = REPO_ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = REPO_ROOT / "ChargeLimiter" / "utils.h"
# Store files remain until Task 5; migration authority is now utils.
H = REPO_ROOT / "ChargeLimiter" / "UIKit" / "CLAppSettingsStore.h"
M = REPO_ROOT / "ChargeLimiter" / "UIKit" / "CLAppSettingsStore.m"


class AppSettingsStoreInterfaceTests(unittest.TestCase):
    def test_shared_migration_is_authoritative_in_utils(self):
        h = UTILS_H.read_text(encoding="utf-8")
        mm = UTILS_MM.read_text(encoding="utf-8")
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", h)
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", mm)
        self.assertIn("setlocalKVChecked", mm)

    def test_store_files_still_present_for_task5(self):
        """Task 4 keeps store files; Task 5 deletes/empties them."""
        self.assertTrue(H.exists(), "CLAppSettingsStore.h should remain until Task 5")
        self.assertTrue(M.exists(), "CLAppSettingsStore.m should remain until Task 5")
        m = M.read_text(encoding="utf-8")
        for k in ["AppLanguage", "AppAppearance", "SliderHapticStyle", "StopChargePresetValue"]:
            self.assertIn(f'@"{k}"', m)


if __name__ == "__main__":
    unittest.main()

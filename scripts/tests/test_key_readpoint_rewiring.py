import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UI_MM = REPO_ROOT / "ChargeLimiter/ui.mm"
SVC_M = REPO_ROOT / "ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m"
LOC_M = REPO_ROOT / "ChargeLimiter/CLLocalization.m"


class KeyReadPointRewiringTests(unittest.TestCase):
    def test_clsettings_uses_shared_kv(self):
        s = SVC_M.read_text(encoding="utf-8")
        self.assertIn("getlocalKV", s,
                      "CLLocalIntegerForKey must read via shared getlocalKV / getlocalKV_C")
        self.assertTrue(
            "setlocalKVChecked" in s or "setlocalKV_C" in s or "setlocalKV(" in s,
            "CLSetLocalIntegerForKey must write via shared setlocalKVChecked / setlocalKV_C",
        )
        self.assertNotIn("[[CLAppSettingsStore shared] integerForKey", s,
                         "CLLocalIntegerForKey must not read from CLAppSettingsStore")
        self.assertNotIn("[[CLAppSettingsStore shared] setIntegerForKey", s,
                         "CLSetLocalIntegerForKey must not write via CLAppSettingsStore")

    def test_languagetapped_checks_return_value(self):
        s = SVC_M.read_text(encoding="utf-8")
        # Accept either if (CLSetAppLanguage ...) or if (!CLSetAppLanguage ...)
        self.assertTrue(
            "if (CLSetAppLanguage" in s or "if (!CLSetAppLanguage" in s,
            "languageTapped handler must check CLSetAppLanguage return value",
        )
        self.assertIn("CLSetAppLanguage", s)
        self.assertIn("CLConfigWriteFailedNotification", s)

    def test_appearance_uses_shared_kv(self):
        s = UI_MM.read_text(encoding="utf-8")
        self.assertNotIn('[[CLAppSettingsStore shared] integerForKey:@"AppAppearance"', s,
                         "AppAppearance must not be read from CLAppSettingsStore")
        self.assertTrue(
            "AppAppearance" in s and ("getlocalKV" in s or "readIntForKey" in s or "getInt" in s or "getLocalInt" in s),
            "AppAppearance must be read via shared KV helpers",
        )

    def test_localization_uses_shared_kv(self):
        s = LOC_M.read_text(encoding="utf-8")
        self.assertNotIn("[[CLAppSettingsStore shared] integerForKey", s,
                         "CLGetAppLanguage must not read from CLAppSettingsStore")
        self.assertNotIn("[[CLAppSettingsStore shared] setIntegerForKey", s,
                         "CLSetAppLanguage must not write via CLAppSettingsStore")
        self.assertTrue(
            "getlocalKV" in s,
            "CLGetAppLanguage must read AppLanguage via getlocalKV / getlocalKV_C",
        )
        self.assertTrue(
            "setlocalKVChecked" in s or "setlocalKV_C" in s or "setlocalKV(" in s,
            "CLSetAppLanguage must write AppLanguage via shared KV",
        )


if __name__ == "__main__":
    unittest.main()

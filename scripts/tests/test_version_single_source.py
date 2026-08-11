import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
INFO = REPO / "ChargeLimiter" / "Info.plist"
PBX = REPO / "ChargeLimiter.xcodeproj" / "project.pbxproj"
API = REPO / "ChargeLimiter" / "UIKit" / "CLAPIClient.m"
PACKAGE_CONTROLS = [
    REPO / "ChargeLimiter" / "Package" / "DEBIAN" / "control",
    REPO / "ChargeLimiter" / "Package_rootless" / "DEBIAN" / "control",
    REPO / "ChargeLimiter" / "Package_roothide" / "DEBIAN" / "control",
]
EXPECTED_VERSION = "1.15.0"


class VersionSingleSourceTests(unittest.TestCase):
    def test_info_plist_uses_marketing_version_var(self):
        text = INFO.read_text(encoding="utf-8")
        self.assertIn("<key>CFBundleShortVersionString</key>", text)
        # 必须是 Xcode 变量，不能再写死 1.x.y
        self.assertRegex(
            text,
            r"<key>CFBundleShortVersionString</key>\s*<string>\$\(MARKETING_VERSION\)</string>",
        )
        self.assertNotRegex(
            text,
            r"<key>CFBundleShortVersionString</key>\s*<string>\d+\.\d+",
        )

    def test_pbxproj_has_marketing_version(self):
        text = PBX.read_text(encoding="utf-8")
        self.assertRegex(text, r"MARKETING_VERSION = \d+\.\d+")

    def test_release_version_is_consistent(self):
        project_versions = set(
            re.findall(r"MARKETING_VERSION = ([^;]+);", PBX.read_text(encoding="utf-8"))
        )
        self.assertEqual(project_versions, {EXPECTED_VERSION})
        for control in PACKAGE_CONTROLS:
            match = re.search(
                r"^Version:\s*(\S+)\s*$",
                control.read_text(encoding="utf-8"),
                re.MULTILINE,
            )
            self.assertIsNotNone(match, f"missing Version field in {control}")
            self.assertEqual(match.group(1), EXPECTED_VERSION, str(control))

    def test_apiclient_does_not_hardcode_old_ver(self):
        text = API.read_text(encoding="utf-8")
        self.assertNotRegex(text, r'@"ver"\s*:\s*@"1\.\d+')
        self.assertTrue(
            "CFBundleShortVersionString" in text or "MARKETING_VERSION" in text or "shortVersion" in text.lower()
            or re.search(r'objectForInfoDictionaryKey:@\"CFBundleShortVersionString\"', text),
            "CLAPIClient should read version from bundle (or equivalent), not hardcode",
        )


if __name__ == "__main__":
    unittest.main()

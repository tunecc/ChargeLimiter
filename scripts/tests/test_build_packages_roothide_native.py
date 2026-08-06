import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = REPO / "scripts" / "build_packages.sh"


class BuildPackagesRoothideNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = BUILD_SCRIPT.read_text(encoding="utf-8")

    def test_default_not_legacy_convert(self):
        s = self.source
        self.assertIn("ChargeLimiter roothide", s)
        self.assertIn("Package_roothide", s)
        # 默认不应再警告「will be built by converting」为唯一路径
        self.assertIn("--legacy-roothide-convert", s)
        self.assertIn("BUILD_NATIVE_ROOTHIDE", s)
        # Default must prefer native over conversion.
        self.assertRegex(
            s,
            r'BUILD_NATIVE_ROOTHIDE="\$\{CHARGELIMITER_BUILD_NATIVE_ROOTHIDE:-1\}"',
        )
        self.assertRegex(
            s,
            r'BUILD_LEGACY_ROOTHIDE="\$\{CHARGELIMITER_BUILD_LEGACY_ROOTHIDE:-0\}"',
        )

    def test_stages_native_roothide_scheme(self):
        s = self.source
        self.assertRegex(
            s,
            r'-scheme\s+"ChargeLimiter roothide"|-scheme "ChargeLimiter roothide"',
        )
        self.assertIn("BUILD_ROOTHIDE", s)
        self.assertIn("PKG_ROOTHIDE_DIR", s)
        self.assertIn("STAGE_ROOTHIDE", s)
        # Native path merges roothide entitlements onto executables.
        self.assertRegex(s, r'ldid\s+-M\s+.*roothide\.entitlements|ldid -M "-S\$ROOTHIDE_MERGE_ENT"')

    def test_default_path_does_not_call_convert(self):
        s = self.source
        # convert remains available for --legacy-roothide-convert only.
        self.assertIn("convert_rootless_stage_to_roothide", s)
        self.assertIn("--skip-roothide", s)
        # The conversion warning must not be the unconditional default path text.
        # It should only appear under the legacy branch / flag, not as sole default.
        self.assertNotRegex(
            s,
            r'(?m)^[^#\n]*echo "\[WARN\] roothide package will be built by converting the rootless staging tree because this project still has no native roothide',
        )

    def test_usage_mentions_native_default(self):
        s = self.source
        usage_match = re.search(r"usage\(\)\s*\{(.*?)^\}", s, re.S | re.M)
        self.assertIsNotNone(usage_match)
        usage = usage_match.group(1)
        self.assertIn("--legacy-roothide-convert", usage)
        self.assertIn("--skip-roothide", usage)
        self.assertRegex(usage, r"native|Package_roothide|ChargeLimiter roothide", re.I)


if __name__ == "__main__":
    unittest.main()

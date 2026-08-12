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
        self.assertIn("BUILD_NATIVE_ROOTHIDE", s)
        # Native is the default and only roothide path.
        self.assertRegex(
            s,
            r'BUILD_NATIVE_ROOTHIDE="\$\{CHARGELIMITER_BUILD_NATIVE_ROOTHIDE:-1\}"',
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
        self.assertIn("--skip-roothide", s)
        # The conversion warning must not be the unconditional default path text.
        self.assertNotRegex(
            s,
            r'(?m)^[^#\n]*echo "\[WARN\] roothide package will be built by converting the rootless staging tree because this project still has no native roothide',
        )

    def test_usage_mentions_native_default(self):
        s = self.source
        usage_match = re.search(r"usage\(\)\s*\{(.*?)^\}", s, re.S | re.M)
        self.assertIsNotNone(usage_match)
        usage = usage_match.group(1)
        self.assertIn("--skip-roothide", usage)
        self.assertRegex(usage, r"native|Package_roothide|ChargeLimiter roothide", re.I)

    def test_check_roothide_stage_rejects_var_jb_load_paths(self):
        """After binaries exist, reject residual /var/jb load paths via otool.

        Native roothide may be rootful-shaped (system libs only) — that is OK.
        Residual /var/jb/* load commands are not.
        """
        s = self.source
        fn_idx = s.find("check_roothide_stage()")
        self.assertGreater(fn_idx, -1)
        # Take a large slice; function is long and not followed by another foo().
        body = s[fn_idx:fn_idx + 8000]
        # Truncate at the closing of this function before the next top-level echo/step.
        close_idx = body.find('\necho "[10/10]')
        if close_idx > 0:
            body = body[:close_idx]

        self.assertRegex(
            body,
            r"otool\s+-L|xcrun\s+otool\s+-L",
            "check_roothide_stage must otool -L app/daemon binaries",
        )
        self.assertTrue(
            "/var/jb" in body,
            "check_roothide_stage must reject residual /var/jb load paths",
        )
        # Should inspect both app and daemon binaries
        self.assertTrue(
            "ChargeLimiter" in body and "ChargeLimiterDaemon" in body,
            "link check should cover app and daemon executables",
        )


if __name__ == "__main__":
    unittest.main()

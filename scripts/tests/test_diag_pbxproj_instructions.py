# scripts/tests/test_diag_pbxproj_instructions.py
import unittest

from _helpers import REPO_ROOT as REPO, source_for
DOC = REPO / "scripts" / "wire_diagnostic_collector_pbxproj.md"


class PbxprojInstructionsTests(unittest.TestCase):
    def test_doc_exists(self):
        self.assertTrue(DOC.exists())

    def test_doc_mentions_targets_and_macros(self):
        t = source_for(DOC)
        self.assertIn("CLDiagnosticCollector", t)
        self.assertIn("CL_PACKAGE_ROOTHIDE", t)
        self.assertIn("CL_PACKAGE_ROOTLESS", t)
        self.assertIn("ChargeLimiter_roothide", t)
        self.assertIn("Daemon", t)  # 明确说不要加 daemon
        self.assertIn("xcodebuild", t)


if __name__ == "__main__":
    unittest.main()

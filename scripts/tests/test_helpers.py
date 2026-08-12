import unittest

try:
    from _helpers import function_body, source_for
except ImportError:
    from scripts.tests._helpers import function_body, source_for


class HelperTests(unittest.TestCase):
    def test_source_for_reads_repo_relative_utf8(self):
        self.assertIn("def source_for", source_for("scripts/tests/_helpers.py"))

    def test_function_body_skips_declaration_and_matches_nested_braces(self):
        source = "void sample(void);\nvoid sample(void) { if (ready) { run(); } }"
        self.assertEqual(function_body(source, "void sample(void)"), " if (ready) { run(); } ")


if __name__ == "__main__":
    unittest.main()

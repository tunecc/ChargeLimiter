from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TestFileLogPolicy(unittest.TestCase):
    def test_compile_and_run(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            out = Path(tmpdir) / "test_file_log_policy"
            result = subprocess.run(
                [
                    "xcrun", "clang",
                    "-std=c11",
                    "-Wall", "-Werror",
                    "-I", str(ROOT / "ChargeLimiter"),
                    "-o", str(out),
                    str(ROOT / "tests" / "test_file_log_policy.c"),
                ],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode, 0,
                msg=f"compilation failed:\n{result.stderr}",
            )
            run = subprocess.run(
                [str(out)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(run.returncode, 0)


if __name__ == "__main__":
    unittest.main()
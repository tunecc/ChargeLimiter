import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "generate_release_notes.py"


class GenerateReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.repo_dir = Path(tempfile.mkdtemp(prefix="chargelimiter-release-notes-"))
        self._git("init")
        self._git("config", "user.name", "Test User")
        self._git("config", "user.email", "test@example.com")

    def _git(self, *args, check=True):
        return subprocess.run(
            ["git", *args],
            cwd=self.repo_dir,
            check=check,
            capture_output=True,
            text=True,
        )

    def _write(self, relative_path, content):
        target = self.repo_dir / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def _commit(self, message, files):
        for relative_path, content in files.items():
            self._write(relative_path, content)
        self._git("add", ".")
        self._git("commit", "-m", message)

    def _run_script(self, current_tag):
        output_path = self.repo_dir / "release-notes.md"
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--current-tag",
                current_tag,
                "--repo",
                "tunecc/ChargeLimiter",
                "--output",
                str(output_path),
            ],
            cwd=self.repo_dir,
            check=False,
            capture_output=True,
            text=True,
        )
        return result, output_path

    def test_prefers_version_specific_manual_notes_file(self):
        self._commit(
            "chore: bootstrap repository",
            {
                "README.md": "# Test Repo\n",
                "CHANGELOG.md": "# CHANGELOG\n",
            },
        )
        self._git("tag", "v1.0.0")
        self._commit(
            "feat(ui): 新增停充预设快捷入口",
            {
                "app.txt": "feature\n",
            },
        )
        self._commit(
            "fix(daemon): 修复停充失败自动回退",
            {
                "daemon.txt": "fix\n",
                "CHANGELOG.md": textwrap.dedent(
                    """\
                    # CHANGELOG

                    ## v1.1.0 - 2026-01-01

                    ### 新增

                    - 新增停充预设快捷入口

                    ### 修复

                    - 修复停充失败自动回退
                    """
                ),
            },
        )
        self._git("tag", "v1.1.0")

        result, output_path = self._run_script("v1.1.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        notes = output_path.read_text(encoding="utf-8")
        self.assertIn("## 维护者摘要", notes)
        self.assertIn("新增停充预设快捷入口", notes)
        self.assertIn("## 功能新增", notes)
        self.assertIn("## 问题修复", notes)
        self.assertIn("https://github.com/tunecc/ChargeLimiter/compare/v1.0.0...v1.1.0", notes)

    def test_falls_back_to_changelog_section_when_manual_file_is_missing(self):
        self._commit(
            "chore: bootstrap repository",
            {
                "README.md": "# Test Repo\n",
                "CHANGELOG.md": "# CHANGELOG\n",
            },
        )
        self._git("tag", "v1.1.0")
        self._commit(
            "优化限流控制的切换",
            {
                "throttle.txt": "improve\n",
                "CHANGELOG.md": textwrap.dedent(
                    """\
                    # CHANGELOG

                    ## v1.12.0 - 2026-01-02

                    ### 优化

                    - 优化限流控制的切换
                    """
                ),
            },
        )
        self._git("tag", "v1.12.0")

        result, output_path = self._run_script("v1.12.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        notes = output_path.read_text(encoding="utf-8")
        self.assertIn("## 维护者摘要", notes)
        self.assertIn("优化限流控制的切换", notes)
        self.assertIn("## 改进优化", notes)
        self.assertIn("## 完整提交列表", notes)
        self.assertIn("`v1.1.0...v1.12.0`", notes)

    def test_allows_current_tag_to_be_unborn_when_releasing_head(self):
        self._commit(
            "chore: bootstrap repository",
            {
                "README.md": "# Test Repo\n",
                "CHANGELOG.md": "# CHANGELOG\n",
            },
        )
        self._git("tag", "v1.12.4")
        self._commit(
            "feat: 默认开启智能停充并修正文案",
            {
                "feature.txt": "head release\n",
                "CHANGELOG.md": textwrap.dedent(
                    """\
                    # CHANGELOG

                    ## v1.12.5 - 2026-01-03

                    ### 新增

                    - 默认开启智能停充并修正文案
                    """
                ),
            },
        )

        result, output_path = self._run_script("v1.12.5")

        self.assertEqual(result.returncode, 0, result.stderr)
        notes = output_path.read_text(encoding="utf-8")
        self.assertIn("默认开启智能停充并修正文案", notes)
        self.assertIn("https://github.com/tunecc/ChargeLimiter/compare/v1.12.4...v1.12.5", notes)


if __name__ == "__main__":
    unittest.main()

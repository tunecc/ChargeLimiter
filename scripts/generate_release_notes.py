#!/usr/bin/env python3
"""Generate GitHub Release notes from git history and CHANGELOG.md."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


CATEGORY_ORDER = [
    "功能新增",
    "问题修复",
    "改进优化",
    "发布维护",
    "文档与其他",
]

TYPE_TO_CATEGORY = {
    "feat": "功能新增",
    "feature": "功能新增",
    "fix": "问题修复",
    "bugfix": "问题修复",
    "refactor": "改进优化",
    "perf": "改进优化",
    "optimize": "改进优化",
    "improve": "改进优化",
    "chore": "发布维护",
    "build": "发布维护",
    "ci": "发布维护",
    "release": "发布维护",
    "docs": "文档与其他",
    "doc": "文档与其他",
    "test": "文档与其他",
    "style": "文档与其他",
}


def run_git(repo_root: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", *args],
        cwd=repo_root,
        text=True,
    ).strip()


def normalize_version(tag: str) -> str:
    return tag[1:] if tag.startswith("v") else tag


def find_previous_tag(repo_root: Path, current_tag: str) -> str | None:
    tags_output = run_git(repo_root, "tag", "--sort=version:refname")
    tags = [line.strip() for line in tags_output.splitlines() if line.strip()]
    ordered_tags = list(tags)
    if current_tag not in ordered_tags:
        ordered_tags.append(current_tag)
        ordered_tags.sort(key=version_sort_key)
    index = ordered_tags.index(current_tag)
    if index == 0:
        return None
    return ordered_tags[index - 1]


def version_sort_key(tag: str) -> tuple:
    normalized = normalize_version(tag)
    parts: list[object] = []
    for part in re.split(r"([0-9]+)", normalized):
        if not part:
            continue
        if part.isdigit():
            parts.append(int(part))
        else:
            parts.append(part)
    return tuple(parts)


def git_ref_exists(repo_root: Path, ref: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", ref],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def load_manual_summary(repo_root: Path, current_tag: str) -> str:
    return load_changelog_section(repo_root, current_tag)


def load_changelog_section(repo_root: Path, current_tag: str) -> str:
    changelog_path = repo_root / "CHANGELOG.md"
    if not changelog_path.is_file():
        return ""

    content = changelog_path.read_text(encoding="utf-8")
    pattern = re.compile(
        rf"(?ms)^##\s+{re.escape(current_tag)}\s+-\s+\d{{4}}-\d{{2}}-\d{{2}}\s*\n(.*?)(?=^##\s+v?[\w.\-]+\s+-\s+\d{{4}}-\d{{2}}-\d{{2}}|\Z)"
    )
    match = pattern.search(content)
    if not match:
        return ""
    section = match.group(1).strip()
    lines = [line for line in section.splitlines() if not line.startswith("## ")]
    return "\n".join(lines).strip()


def classify_commit(subject: str) -> tuple[str, str]:
    trimmed = subject.strip()
    match = re.match(r"(?i)^([a-z]+)(?:\(([^)]+)\))?:\s*(.+)$", trimmed)
    if match:
        kind = match.group(1).lower()
        scope = match.group(2)
        detail = match.group(3).strip()
        category = TYPE_TO_CATEGORY.get(kind, "文档与其他")
        if kind == "chore" and scope == "release":
            category = "发布维护"
        return category, detail

    lowered = trimmed.lower()
    if "修复" in trimmed or lowered.startswith("fix"):
        return "问题修复", trimmed
    if "新增" in trimmed or lowered.startswith("add"):
        return "功能新增", trimmed
    if "优化" in trimmed or "改进" in trimmed or lowered.startswith("improve"):
        return "改进优化", trimmed
    return "文档与其他", trimmed


def collect_commits(repo_root: Path, previous_tag: str | None, current_tag: str) -> tuple[list[tuple[str, str]], str]:
    current_ref = current_tag if git_ref_exists(repo_root, current_tag) else "HEAD"
    if previous_tag:
        revspec = f"{previous_tag}...{current_ref}"
    else:
        revspec = current_ref
    output = run_git(repo_root, "log", "--no-merges", "--pretty=format:%s", revspec)
    commits = []
    for line in output.splitlines():
        subject = line.strip()
        if not subject:
            continue
        commits.append(classify_commit(subject))
    return commits, revspec


def render_notes(repo: str, current_tag: str, previous_tag: str | None, summary: str, commits: list[tuple[str, str]], revspec: str) -> str:
    compare_range = f"{previous_tag}...{current_tag}" if previous_tag else current_tag
    compare_url = (
        f"https://github.com/{repo}/compare/{previous_tag}...{current_tag}"
        if previous_tag
        else f"https://github.com/{repo}/releases/tag/{current_tag}"
    )

    lines: list[str] = []
    lines.append(f"# {current_tag}")
    lines.append("")

    if summary:
        lines.append("## 维护者摘要")
        lines.append(summary)
        lines.append("")

    categorized: dict[str, list[str]] = {category: [] for category in CATEGORY_ORDER}
    for category, detail in commits:
        categorized.setdefault(category, []).append(detail)

    for category in CATEGORY_ORDER:
        items = categorized.get(category, [])
        if not items:
            continue
        lines.append(f"## {category}")
        for item in items:
            lines.append(f"- {item}")
        lines.append("")

    lines.append("## 完整提交列表")
    lines.append(f"- 比较范围：`{compare_range}`")
    lines.append(f"- 对比链接：{compare_url}")
    lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate GitHub release notes.")
    parser.add_argument("--current-tag", required=True, help="Current release tag, e.g. v1.12.5")
    parser.add_argument("--repo", required=True, help="GitHub repository slug, e.g. tunecc/ChargeLimiter")
    parser.add_argument("--output", required=True, help="Output markdown path")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    output_path = Path(args.output)

    previous_tag = find_previous_tag(repo_root, args.current_tag)
    summary = load_manual_summary(repo_root, args.current_tag)
    commits, revspec = collect_commits(repo_root, previous_tag, args.current_tag)
    notes = render_notes(args.repo, args.current_tag, previous_tag, summary, commits, revspec)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(notes, encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

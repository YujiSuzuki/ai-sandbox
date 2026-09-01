#!/usr/bin/env python3
# claude-data.py
# Lists Claude local data (memory, plans, latest-session scratchpad, optionally settings
# and recent session transcripts) by default; --copy backs up memory/plans (not scratchpad
# or session transcripts, which are per-session throwaway/log data).
# @advertise: true
# ---
# Claude のローカルデータ（memory、plans、直近セッションの scratchpad、任意で settings と
# 直近セッションのトランスクリプト）をデフォルトで一覧表示する。--copy は memory/plans のみ
# バックアップする（scratchpad とセッショントランスクリプトはセッション単位のログのため対象外）。

import glob as globmod
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

CLAUDE_DIR = Path("/home/node/.claude")
WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
# Claude Code names a project's dir under ~/.claude/projects/ (and its /tmp
# scratchpad dir) by replacing "/" with "-" in the workspace path, e.g.
# /workspace -> -workspace.
PROJECT_DIR_NAME = str(WORKSPACE).replace("/", "-")
MEMORY_SRC = CLAUDE_DIR / "projects" / PROJECT_DIR_NAME / "memory"
PLANS_SRC = CLAUDE_DIR / "plans"
SETTINGS_SRC = CLAUDE_DIR / "settings.json"
PLUGINS_SRC = CLAUDE_DIR / "plugins"
SCRATCHPAD_DIR_GLOB = f"/tmp/claude-*/{PROJECT_DIR_NAME}/*/scratchpad"
SESSIONS_DIR = CLAUDE_DIR / "projects" / PROJECT_DIR_NAME
RECENT_SESSIONS_COUNT = 5


def usage_text(prog: str) -> str:
    return f"""Usage: {prog} [--with-settings] [--with-scratchpad-history] [--with-recent-sessions]
       {prog} --copy <dest-dir> [--with-settings]

Options:
  --copy <dest-dir>          Copy source files to dest-dir instead of listing them
  --with-settings            Also list/copy settings.json and plugins/
  --with-scratchpad-history  Also list older scratchpad sessions (collapsed to
                              "dir (N file(s))"); omitted by default
  --with-recent-sessions     Also list the {RECENT_SESSIONS_COUNT} most recently modified
                              session transcripts (*.jsonl); omitted by default
  -h, --help                 Show this help

Listed by default:
  memory/       ({MEMORY_SRC})
  plans/        ({PLANS_SRC})
  scratchpad/*  ({SCRATCHPAD_DIR_GLOB}/*)
                (only the most recently active session, listed file-by-file)

Copied by --copy (scratchpad and session transcripts are excluded — per-session log data):
  memory/
  plans/

With --with-settings:
  settings.json
  plugins/

With --with-recent-sessions:
  *.jsonl       ({SESSIONS_DIR}/*.jsonl)
                ({RECENT_SESSIONS_COUNT} most recently modified, listed with mtime)

Example:
  {prog}
  {prog} --with-scratchpad-history
  {prog} --with-recent-sessions
  {prog} --with-settings
  {prog} --copy ~/backup/claude
  {prog} --copy ~/backup/claude --with-settings
"""


def exit_with_usage(prog: str) -> None:
    print(usage_text(prog), end="")
    sys.exit(1)


def list_path(path: Path) -> list[str]:
    if path.is_dir():
        return sorted(str(p) for p in path.rglob("*") if p.is_file())
    if path.is_file():
        return [str(path)]
    return []


def list_scratchpads(include_history: bool) -> list[str]:
    """Most-recently-active scratchpad dir listed file-by-file (clickable paths).
    With include_history, older ones are also shown, collapsed to one line each
    (dir path + file count) — the dir path is itself a clickable link that opens
    the folder in VS Code. Without it, older sessions are omitted entirely."""
    dirs = [Path(p) for p in globmod.glob(SCRATCHPAD_DIR_GLOB) if Path(p).is_dir()]

    def files_of(d: Path) -> list[Path]:
        return sorted(f for f in d.rglob("*") if f.is_file())

    def latest_mtime(d: Path, files: list[Path]) -> float:
        return max((f.stat().st_mtime for f in files), default=d.stat().st_mtime)

    dirs_with_files = [(d, files_of(d)) for d in dirs]
    dirs_with_files = [(d, files) for d, files in dirs_with_files if files]
    dirs_with_files.sort(key=lambda item: latest_mtime(*item), reverse=True)

    lines: list[str] = []
    for i, (d, files) in enumerate(dirs_with_files):
        if i == 0:
            lines.extend(str(f) for f in files)
        elif include_history:
            lines.append(f"{d}  ({len(files)} file(s))")
        else:
            break
    return lines


def list_recent_sessions(count: int) -> list[str]:
    """Most recently modified session transcripts (*.jsonl), newest first, each
    annotated with its mtime since the filename (a session UUID) gives no clue
    on its own which one is which."""
    files = [p for p in SESSIONS_DIR.glob("*.jsonl") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)

    lines: list[str] = []
    for p in files[:count]:
        mtime = datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
        lines.append(f"{p}  ({mtime})")
    return lines


def show_diff_if_changed(src: Path, dest: Path) -> None:
    if not dest.is_file():
        return
    same = subprocess.run(["diff", "-q", str(src), str(dest)], capture_output=True).returncode == 0
    if same:
        return
    print(f"    [diff: {dest}]")
    diff = subprocess.run(
        ["diff", "--color=always", "-u", str(dest), str(src)],
        capture_output=True,
        text=True,
    )
    for line in diff.stdout.splitlines():
        print(f"    {line}")


def copy_dir(src: Path, dest: Path, label: str) -> None:
    if not src.is_dir():
        print(f"  skip: {label} (not found: {src})")
        return

    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    for file in sorted(src.rglob("*")):
        if not file.is_file():
            continue
        dest_file = dest / file.relative_to(src)
        dest_file.parent.mkdir(parents=True, exist_ok=True)
        show_diff_if_changed(file, dest_file)
        shutil.copy2(file, dest_file)
        count += 1
    print(f"  {label}: {count} file(s) → {dest}")


def copy_file(src: Path, dest: Path, label: str) -> None:
    if not src.is_file():
        print(f"  skip: {label} (not found: {src})")
        return

    dest.parent.mkdir(parents=True, exist_ok=True)
    show_diff_if_changed(src, dest)
    shutil.copy2(src, dest)
    print(f"  {label} → {dest}")


def main() -> None:
    prog = Path(sys.argv[0]).name
    argv = sys.argv[1:]

    with_settings = False
    with_scratchpad_history = False
    with_recent_sessions = False
    copy = False
    dest: str | None = None

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--copy":
            copy = True
            i += 1
            if i >= len(argv) or argv[i].startswith("-") or argv[i] == "":
                print("Error: --copy requires a dest-dir argument", file=sys.stderr)
                exit_with_usage(prog)
            dest = argv[i]
            i += 1
        elif arg == "--with-settings":
            with_settings = True
            i += 1
        elif arg == "--with-scratchpad-history":
            with_scratchpad_history = True
            i += 1
        elif arg == "--with-recent-sessions":
            with_recent_sessions = True
            i += 1
        elif arg in ("-h", "--help"):
            exit_with_usage(prog)
        else:
            print(f"Error: Unknown option: {arg}", file=sys.stderr)
            exit_with_usage(prog)

    if not copy:
        for line in list_path(MEMORY_SRC):
            print(line)
        for line in list_path(PLANS_SRC):
            print(line)
        for line in list_scratchpads(with_scratchpad_history):
            print(line)
        if with_settings:
            for line in list_path(SETTINGS_SRC):
                print(line)
            for line in list_path(PLUGINS_SRC):
                print(line)
        if with_recent_sessions:
            for line in list_recent_sessions(RECENT_SESSIONS_COUNT):
                print(line)
        sys.exit(0)

    assert dest is not None
    dest_path = Path(dest)
    dest_path.mkdir(parents=True, exist_ok=True)

    copy_dir(MEMORY_SRC, dest_path / "memory", "memory")
    copy_dir(PLANS_SRC, dest_path / "plans", "plans")

    if with_settings:
        copy_file(SETTINGS_SRC, dest_path / "settings.json", "settings.json")
        copy_dir(PLUGINS_SRC, dest_path / "plugins", "plugins")

    print(f"Done → {dest_path}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# claude-data.py
# Lists Claude local data (memory, plans, optionally settings) by default; copies with --copy.
# @advertise: true
# ---
# Claude のローカルデータ（memory、plans、任意で settings）をデフォルトで一覧表示し、--copy 指定時のみコピーする。

import shutil
import subprocess
import sys
from pathlib import Path

CLAUDE_DIR = Path("/home/node/.claude")
MEMORY_SRC = CLAUDE_DIR / "projects" / "-workspace" / "memory"
PLANS_SRC = CLAUDE_DIR / "plans"
SETTINGS_SRC = CLAUDE_DIR / "settings.json"
PLUGINS_SRC = CLAUDE_DIR / "plugins"


def usage_text(prog: str) -> str:
    return f"""Usage: {prog} [--with-settings]
       {prog} --copy <dest-dir> [--with-settings]

Options:
  --copy <dest-dir>  Copy source files to dest-dir instead of listing them
  --with-settings    Also list/copy settings.json and plugins/
  -h, --help         Show this help

Listed/copied by default:
  memory/   ({MEMORY_SRC})
  plans/    ({PLANS_SRC})

With --with-settings:
  settings.json
  plugins/

Example:
  {prog}
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
        if with_settings:
            for line in list_path(SETTINGS_SRC):
                print(line)
            for line in list_path(PLUGINS_SRC):
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

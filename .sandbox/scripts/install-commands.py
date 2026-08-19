#!/usr/bin/env python3
# install-commands.py
# Install custom slash commands from .sandbox/commands/ into .claude/commands/
# @advertise: true
#
# Lists available custom commands and installs selected ones (or all) as
# Claude Code slash commands. Installed commands appear as /command-name.
#
# Usage:
#   .sandbox/scripts/install-commands.py [options] [command-name...]
#
# Options:
#   --list         List available commands without installing
#   --all          Install all available commands
#   --uninstall    Remove installed commands (that originated from .sandbox/commands/)
#   --help, -h     Show this help
#
# Arguments:
#   command-name   Name(s) of commands to install (without .md extension)
#                  If omitted and --all not specified, shows interactive selection
#
# Examples:
#   .sandbox/scripts/install-commands.py --list           # List available commands
#   .sandbox/scripts/install-commands.py ais-local-review     # Install ais-local-review command
#   .sandbox/scripts/install-commands.py --all            # Install all commands
#   .sandbox/scripts/install-commands.py --uninstall      # Remove installed commands
#
# AI Workflow:
#   1. Run install-commands.py --list to show available commands
#   2. Run install-commands.py --all or install-commands.py <name> to install
#   3. Restart Claude Code to recognize the new commands
# ---
# .sandbox/commands/ のカスタムスラッシュコマンドを .claude/commands/ にインストール
#
# 利用可能なカスタムコマンドを一覧表示し、選択したもの（または全て）を
# Claude Code のスラッシュコマンドとしてインストールします。
# インストール後は /command-name として使えます。
#
# 使用法:
#   .sandbox/scripts/install-commands.py [options] [command-name...]
#
# オプション:
#   --list         インストールせずに利用可能なコマンドを一覧表示
#   --all          全コマンドをインストール
#   --uninstall    インストール済みコマンド（.sandbox/commands/ 由来）を削除
#   --help, -h     ヘルプ表示
#
# 引数:
#   command-name   インストールするコマンド名（.md 拡張子なし）
#                  省略かつ --all 未指定の場合、対話的に選択
#
# 例:
#   .sandbox/scripts/install-commands.py --list           # 一覧表示
#   .sandbox/scripts/install-commands.py ais-local-review     # ais-local-review をインストール
#   .sandbox/scripts/install-commands.py --all            # 全コマンドをインストール
#   .sandbox/scripts/install-commands.py --uninstall      # インストール済みを削除
#
# AI ワークフロー:
#   1. install-commands.py --list で利用可能なコマンドを確認
#   2. install-commands.py --all または install-commands.py <name> でインストール
#   3. Claude Code を再起動して新しいコマンドを認識させる

import os
import re
import sys
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent.parent
COMMANDS_SRC_DIR = WORKSPACE_ROOT / ".sandbox" / "commands"
COMMANDS_DIR = WORKSPACE_ROOT / ".claude" / "commands"


def is_lang_ja() -> bool:
    return os.environ.get("LANG", "").startswith("ja_JP") or os.environ.get("LC_ALL", "").startswith("ja_JP")


def pick(lang_ja: bool, en: str, ja: str) -> str:
    return ja if lang_ja else en


def msg(lang_ja: bool, en: str, ja: str) -> None:
    print(pick(lang_ja, en, ja))


# ─── Help / ヘルプ ─────────────────────────────────────────────────────────

def show_help(lang_ja: bool) -> None:
    if lang_ja:
        print("""使用法: install-commands.py [options] [command-name...]

.sandbox/commands/ のカスタムコマンドを .claude/commands/ にインストールします。

オプション:
  --list         利用可能なコマンドを一覧表示
  --all          全コマンドをインストール
  --uninstall    インストール済みコマンドを削除
  --help, -h     このヘルプを表示

例:
  install-commands.py --list           # 一覧表示
  install-commands.py ais-local-review     # ais-local-review をインストール
  install-commands.py --all            # 全コマンドをインストール""")
    else:
        print("""Usage: install-commands.py [options] [command-name...]

Install custom commands from .sandbox/commands/ into .claude/commands/.

Options:
  --list         List available commands without installing
  --all          Install all available commands
  --uninstall    Remove installed commands
  --help, -h     Show this help

Examples:
  install-commands.py --list           # List available commands
  install-commands.py ais-local-review     # Install ais-local-review command
  install-commands.py --all            # Install all commands""")


# ─── Front matter helpers / フロントマター・ヘルパー ─────────────────────────────────────────

def extract_field(path: Path, field: str) -> str:
    lines = path.read_text().split("\n")
    if not lines or not lines[0].startswith("---"):
        return ""
    matches = []
    for line in lines[1:]:
        if line == "---":
            break
        if line.startswith(f"{field}:"):
            matches.append(line[len(field) + 1:].lstrip(" "))
    return "\n".join(matches)


def get_description(path: Path, lang_ja: bool) -> str:
    if lang_ja:
        ja_desc = extract_field(path, "description-ja")
        if ja_desc:
            return ja_desc
    return extract_field(path, "description")


def localize_file(path: Path, lang_ja: bool) -> str:
    ja_desc = extract_field(path, "description-ja") if lang_ja else ""
    out = []
    for line in path.read_text().split("\n"):
        if line.startswith("description-ja:"):
            continue
        if ja_desc and line.startswith("description:"):
            out.append(f"description: {ja_desc}")
            continue
        out.append(line)
    return "\n".join(out).rstrip("\n")


# ─── List available commands / 利用可能なコマンド一覧 ──────────────────────────────────────

def list_commands(lang_ja: bool) -> None:
    if not COMMANDS_SRC_DIR.is_dir():
        msg(lang_ja, f"No commands directory found at {COMMANDS_SRC_DIR}",
            f"コマンドディレクトリが見つかりません: {COMMANDS_SRC_DIR}")
        sys.exit(1)

    files = sorted(COMMANDS_SRC_DIR.glob("*.md"))
    if not files:
        msg(lang_ja, f"No commands available in {COMMANDS_SRC_DIR}",
            f"利用可能なコマンドがありません: {COMMANDS_SRC_DIR}")
        sys.exit(0)

    msg(lang_ja, "Available commands:", "利用可能なコマンド:")
    print()

    for f in files:
        name = f.stem
        desc = get_description(f, lang_ja)
        status = pick(lang_ja, " [installed]", " [インストール済]") if (COMMANDS_DIR / f"{name}.md").is_file() else ""
        print(f"  {'/' + name:<20} {desc}{status}")

    print()
    msg(lang_ja, "Install with: .sandbox/scripts/install-commands.py <command-name>",
        "インストール: .sandbox/scripts/install-commands.py <コマンド名>")
    msg(lang_ja, "Install all:  .sandbox/scripts/install-commands.py --all",
        "全てインストール: .sandbox/scripts/install-commands.py --all")


# ─── Install commands / コマンドのインストール ─────────────────────────────────────────────

def install_command(name: str, lang_ja: bool) -> int:
    src = COMMANDS_SRC_DIR / f"{name}.md"

    if not src.is_file():
        msg(lang_ja, f"Command not found: {name} (no file at {src})",
            f"コマンドが見つかりません: {name} ({src} が存在しません)")
        return 1

    COMMANDS_DIR.mkdir(parents=True, exist_ok=True)

    translated = localize_file(src, lang_ja)
    dest = COMMANDS_DIR / f"{name}.md"

    if dest.is_file():
        if translated + "\n" == dest.read_text():
            msg(lang_ja, f"  {name}: already up to date", f"  {name}: 最新です")
            return 2
        msg(lang_ja, f"  {name}: updating (overwriting existing)", f"  {name}: 更新（既存を上書き）")
    else:
        msg(lang_ja, f"  {name}: installing", f"  {name}: インストール中")

    dest.write_text(translated + "\n")
    return 0


def install_all(lang_ja: bool) -> None:
    files = sorted(COMMANDS_SRC_DIR.glob("*.md"))
    if not files:
        msg(lang_ja, "No commands available to install", "インストール可能なコマンドがありません")
        sys.exit(0)

    count = 0
    for f in files:
        if install_command(f.stem, lang_ja) == 0:
            count += 1

    print()
    msg(lang_ja, f"Installed {count} command(s) to {COMMANDS_DIR}",
        f"{count} 個のコマンドを {COMMANDS_DIR} にインストールしました")
    print()
    msg(lang_ja, "Restart Claude Code to use the new commands.",
        "新しいコマンドを使うには Claude Code を再起動してください。")


# ─── Uninstall / アンインストール ────────────────────────────────────────────────────

def uninstall_commands(lang_ja: bool) -> None:
    if not COMMANDS_DIR.is_dir():
        msg(lang_ja, "No commands directory found", "コマンドディレクトリがありません")
        sys.exit(0)

    count = 0
    for f in sorted(COMMANDS_SRC_DIR.glob("*.md")):
        name = f.stem
        target = COMMANDS_DIR / f"{name}.md"
        if target.is_file():
            target.unlink()
            msg(lang_ja, f"  Removed: {name}", f"  削除: {name}")
            count += 1

    if count == 0:
        msg(lang_ja, "No installed commands to remove", "削除するインストール済みコマンドがありません")
    else:
        print()
        msg(lang_ja, f"Removed {count} command(s)", f"{count} 個のコマンドを削除しました")

    if COMMANDS_DIR.is_dir() and not any(COMMANDS_DIR.iterdir()):
        COMMANDS_DIR.rmdir()


# ─── Interactive selection / 対話選択 ────────────────────────────────────────

def interactive_select(lang_ja: bool) -> None:
    files = sorted(COMMANDS_SRC_DIR.glob("*.md"))
    if not files:
        msg(lang_ja, "No commands available to install", "インストール可能なコマンドがありません")
        sys.exit(0)

    print()
    msg(lang_ja, "Available commands:", "利用可能なコマンド:")
    print()

    names = []
    for i, f in enumerate(files, start=1):
        name = f.stem
        names.append(name)
        desc = get_description(f, lang_ja)
        status = pick(lang_ja, " [installed]", " [インストール済]") if (COMMANDS_DIR / f"{name}.md").is_file() else ""
        print(f"  {i}) {'/' + name:<20} {desc}{status}")

    all_index = len(files) + 1
    print(f"  {all_index}) {pick(lang_ja, 'All', '全て'):<20}")
    print()

    prompt = "インストールするコマンドを選択（番号）: " if lang_ja else "Select command to install (number): "
    selection = input(prompt).strip()

    if selection == str(all_index):
        install_all(lang_ja)
    elif re.fullmatch(r"[0-9]+", selection) and 1 <= int(selection) < all_index:
        install_command(names[int(selection) - 1], lang_ja)
        print()
        msg(lang_ja, "Restart Claude Code to use the new command.",
            "新しいコマンドを使うには Claude Code を再起動してください。")
    else:
        msg(lang_ja, "Invalid selection", "無効な選択です")
        sys.exit(1)


# ─── Main / メイン ─────────────────────────────────────────────────────────

def main() -> None:
    argv = sys.argv[1:]
    lang_ja = is_lang_ja()

    if not argv:
        interactive_select(lang_ja)
        sys.exit(0)

    first = argv[0]
    if first in ("--help", "-h"):
        show_help(lang_ja)
        sys.exit(0)
    elif first == "--list":
        list_commands(lang_ja)
        sys.exit(0)
    elif first == "--all":
        install_all(lang_ja)
        sys.exit(0)
    elif first == "--uninstall":
        uninstall_commands(lang_ja)
        sys.exit(0)
    elif first.startswith("--"):
        msg(lang_ja, f"Unknown option: {first}", f"不明なオプション: {first}")
        print()
        show_help(lang_ja)
        sys.exit(1)
    else:
        count = 0
        errors = 0
        for name in argv:
            name = name[:-3] if name.endswith(".md") else name
            rc = install_command(name, lang_ja)
            if rc == 0:
                count += 1
            elif rc == 1:
                errors += 1
        print()
        if count > 0:
            msg(lang_ja, f"Installed {count} command(s). Restart Claude Code to use them.",
                f"{count} 個のコマンドをインストールしました。使うには Claude Code を再起動してください。")
        if errors > 0:
            sys.exit(1)


if __name__ == "__main__":
    main()

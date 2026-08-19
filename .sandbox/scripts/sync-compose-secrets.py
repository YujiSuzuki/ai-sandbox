#!/usr/bin/env python3
# sync-compose-secrets.py
# Sync secret hiding configuration between DevContainer and CLI Sandbox docker-compose.yml
#
# This script finds differences in secret hiding config between the two docker-compose.yml
# files and offers to sync them (add missing entries to each file).
#
# IMPORTANT: Must run inside AI Sandbox container (not on host OS).
# @env: container
# ---
# DevContainer と CLI Sandbox の docker-compose.yml 間で秘匿設定を同期
# 2つの docker-compose.yml 間の秘匿設定の差異を見つけ、同期を提案します
# （不足しているエントリを各ファイルに追加）。

import os
import re
import sys
from pathlib import Path

from _python_common import backup_file, cleanup_backups, is_lang_ja, load_startup_config
from _secret_tag import secret_tag_prefix_regex

# ─── Host OS guard / ホストOSガード ─────────────────────────────

if not os.environ.get("SANDBOX_ENV") and not os.path.isfile("/.dockerenv"):
    if is_lang_ja():
        print("❌ このスクリプトはホストOSでは実行できません。")
        print()
        print("以下のいずれかの環境で実行してください：")
        print("  • AI Sandbox のターミナル")
        print("  • cli_sandbox/ai_sandbox.sh")
    else:
        print("❌ This script cannot be run on the host OS.")
        print()
        print("Please run in one of these environments:")
        print("  • AI Sandbox terminal")
        print("  • cli_sandbox/ai_sandbox.sh")
    sys.exit(1)

WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
WORKSPACE_STR = str(WORKSPACE)
WORKSPACE_RE = re.escape(WORKSPACE_STR)

DEVCONTAINER_COMPOSE = WORKSPACE / ".devcontainer" / "docker-compose.yml"
CLI_SANDBOX_COMPOSE = WORKSPACE / "cli_sandbox" / "docker-compose.yml"

# Short display paths
# 表示用の短いパス
DEVCONTAINER_COMPOSE_SHORT = ".devcontainer/docker-compose.yml"
CLI_SANDBOX_COMPOSE_SHORT = "cli_sandbox/docker-compose.yml"


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "🔧 docker-compose.yml 秘匿設定同期ツール",
            "CHECKING": "差異をチェック中...",
            "FILE_NOT_FOUND": "ファイルが見つかりません:",
            "ALL_SYNCED": "✅ 両方の docker-compose.yml は同期されています。差異はありません。",
            "FOUND_HEADER": "以下の差異が見つかりました:",
            "VOLUMES": "/dev/null マウント (volumes)",
            "TMPFS": "tmpfs マウント",
            "ONLY_IN": "のみに存在:",
            "PROMPT": "どうしますか？",
            "YES_ALL": "すべて同期",
            "YES_EACH": "個別確認",
            "NO": "同期しない",
            "PREVIEW": "プレビュー表示",
            "CONFIRM": "追加しますか？",
            "ADDING": "追加中:",
            "ADDED": "✅ 追加しました",
            "SKIPPED": "⏭️  スキップしました",
            "DONE_HEADER": "完了！",
            "DONE_ADDED": "同期されたエントリ:",
            "DONE_NONE": "同期されたエントリはありません",
            "REBUILD": "変更を反映するにはコンテナをリビルドしてください:",
            "REBUILD_DC": "  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'",
            "REBUILD_CLI": "  CLI: docker-compose で再起動",
            "BACKUP": "バックアップを作成しました:",
            "PREVIEW_HEADER": "以下を追加します:",
            "PREVIEW_VOLUMES": "📄 volumes セクションに追加:",
            "PREVIEW_TMPFS": "📁 tmpfs セクションに追加:",
            "TO_FILE": "追加先:",
        }
    return {
        "TITLE": "🔧 docker-compose.yml Secret Config Sync Tool",
        "CHECKING": "Checking for differences...",
        "FILE_NOT_FOUND": "File not found:",
        "ALL_SYNCED": "✅ Both docker-compose.yml files are in sync. No differences found.",
        "FOUND_HEADER": "The following differences were found:",
        "VOLUMES": "/dev/null mounts (volumes)",
        "TMPFS": "tmpfs mounts",
        "ONLY_IN": "only in:",
        "PROMPT": "What would you like to do?",
        "YES_ALL": "Sync all",
        "YES_EACH": "Review each",
        "NO": "Don't sync",
        "PREVIEW": "Preview changes",
        "CONFIRM": "Add this entry?",
        "ADDING": "Adding:",
        "ADDED": "✅ Added",
        "SKIPPED": "⏭️  Skipped",
        "DONE_HEADER": "Done!",
        "DONE_ADDED": "Synced entries:",
        "DONE_NONE": "No entries were synced",
        "REBUILD": "Rebuild containers to apply changes:",
        "REBUILD_DC": "  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'",
        "REBUILD_CLI": "  CLI: Restart with docker-compose",
        "BACKUP": "Backup created:",
        "PREVIEW_HEADER": "The following will be added:",
        "PREVIEW_VOLUMES": "📄 Add to volumes section:",
        "PREVIEW_TMPFS": "📁 Add to tmpfs section:",
        "TO_FILE": "Target file:",
    }


# ─── Prompting / プロンプト ──────────────────────────────────────

def prompt(text: str) -> str:
    """Read one line of input. Mirrors bash's `read -rp`: the prompt text is
    only actually shown (to stderr, without a trailing newline) when stdin
    is a real terminal -- bash suppresses it entirely when stdin is piped,
    it does not merely redirect it (confirmed empirically; also documented
    `read` behavior). Python's input() always writes its prompt to stdout
    regardless, so this bypasses input()'s own prompt handling to match.

    1行読み込む。bashの`read -rp`を再現する: プロンプト文字列は、stdinが
    実端末のときだけ実際に（標準エラーへ、改行なしで）表示される -- bashは
    stdinがパイプの場合、単にリダイレクトするのではなく完全に抑制する
    （実測で確認済み。`read`のドキュメントにも記載の挙動）。Pythonの
    input()は常にプロンプトを標準出力へ書いてしまうため、input()自体の
    プロンプト処理を使わずにこれを再現する。
    """
    if sys.stdin.isatty():
        sys.stderr.write(text)
        sys.stderr.flush()
    try:
        return input()
    except EOFError:
        sys.exit(1)


# ─── Extraction / 抽出 ──────────────────────────────────────────

def extract_devnull_mounts(compose_file: Path) -> list:
    """Extract /dev/null volume mounts.

    /dev/null マウントを抽出
    """
    results = []
    for line in compose_file.read_text().splitlines():
        if re.match(r"^\s*-\s*/dev/null:", line):
            results.append(re.sub(r"^\s*-\s*", "", line))
    return sorted(results)


def extract_tmpfs_mounts(compose_file: Path) -> list:
    """Extract tmpfs mounts ($WORKSPACE paths tagged with "# @secret"); see
    _secret_tag.py for the shared matching regex used by the Python-migrated
    secret-sync scripts.

    tmpfs マウントを抽出（$WORKSPACE パスで "# @secret" タグ付き）。共通の
    マッチング正規表現は _secret_tag.py を参照（Python移行済みの
    secret-sync系スクリプトで共有）。
    """
    prefix_re = secret_tag_prefix_regex(WORKSPACE_RE)
    in_tmpfs = False
    results = set()

    for line in compose_file.read_text().splitlines():
        if re.match(r"^\s*tmpfs:", line):
            in_tmpfs = True
            continue
        if in_tmpfs and re.match(r"^\s*[a-z_]+:", line) and not re.match(r"^\s*-", line):
            in_tmpfs = False
            continue
        if in_tmpfs and re.search(prefix_re, line):
            results.add(re.sub(r"^\s*-\s*", "", line))

    return sorted(results)


def only_in_a(a: list, b: list) -> list:
    b_set = set(b)
    return [x for x in a if x not in b_set]


# ─── docker-compose.yml edit helpers / 編集ヘルパー ──────────────

def add_devnull_mount(mount: str, compose_file: Path) -> bool:
    lines = compose_file.read_text().splitlines()
    last_idx = None
    for i, line in enumerate(lines):
        if "/dev/null:" in line:
            last_idx = i
    if last_idx is None:
        print(f"Warning: Could not find existing /dev/null mounts in {compose_file}")
        return False
    lines.insert(last_idx + 1, f"      - {mount}")
    compose_file.write_text("\n".join(lines) + "\n")
    return True


def add_tmpfs_mount(mount: str, compose_file: Path) -> bool:
    lines = compose_file.read_text().splitlines()
    in_tmpfs = False
    last_tmpfs_idx = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*tmpfs:", line):
            in_tmpfs = True
            continue
        if in_tmpfs and re.match(r"^\s*-\s*" + WORKSPACE_RE, line):
            last_tmpfs_idx = i
        if in_tmpfs and re.match(r"^\s*[a-z_]+:", line) and not re.match(r"^\s*-", line):
            in_tmpfs = False

    if last_tmpfs_idx is None:
        print(f"Warning: Could not find tmpfs section in {compose_file}")
        return False
    lines.insert(last_tmpfs_idx + 1, f"      - {mount}")
    compose_file.write_text("\n".join(lines) + "\n")
    return True


def create_backups(backup_keep_count: str, msgs: dict) -> None:
    print()
    print(msgs["BACKUP"])

    backup_dc = backup_file(str(DEVCONTAINER_COMPOSE), "devcontainer")
    print(f"   {DEVCONTAINER_COMPOSE_SHORT} → {backup_dc}")
    cleanup_backups("devcontainer.docker-compose.yml.*", backup_keep_count)

    backup_cli = backup_file(str(CLI_SANDBOX_COMPOSE), "cli_sandbox")
    print(f"   {CLI_SANDBOX_COMPOSE_SHORT} → {backup_cli}")
    cleanup_backups("cli_sandbox.docker-compose.yml.*", backup_keep_count)

    print()


# ─── Main / メイン処理 ──────────────────────────────────────────

def main() -> None:
    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    backup_keep_count = load_startup_config()["backup_keep_count"]

    print()
    print("━" * 60)
    print(msgs["TITLE"])
    print("━" * 60)
    print()

    missing = False
    if not DEVCONTAINER_COMPOSE.is_file():
        print(f"{msgs['FILE_NOT_FOUND']} {DEVCONTAINER_COMPOSE}")
        missing = True
    if not CLI_SANDBOX_COMPOSE.is_file():
        print(f"{msgs['FILE_NOT_FOUND']} {CLI_SANDBOX_COMPOSE}")
        missing = True
    if missing:
        sys.exit(1)

    print(msgs["CHECKING"])
    print()

    dc_volumes = extract_devnull_mounts(DEVCONTAINER_COMPOSE)
    cli_volumes = extract_devnull_mounts(CLI_SANDBOX_COMPOSE)
    dc_tmpfs = extract_tmpfs_mounts(DEVCONTAINER_COMPOSE)
    cli_tmpfs = extract_tmpfs_mounts(CLI_SANDBOX_COMPOSE)

    volumes_only_in_dc = only_in_a(dc_volumes, cli_volumes)
    volumes_only_in_cli = only_in_a(cli_volumes, dc_volumes)
    tmpfs_only_in_dc = only_in_a(dc_tmpfs, cli_tmpfs)
    tmpfs_only_in_cli = only_in_a(cli_tmpfs, dc_tmpfs)

    has_diff = bool(volumes_only_in_dc or volumes_only_in_cli or tmpfs_only_in_dc or tmpfs_only_in_cli)

    if not has_diff:
        print(msgs["ALL_SYNCED"])
        print()
        sys.exit(0)

    print(msgs["FOUND_HEADER"])
    print()

    if volumes_only_in_dc or volumes_only_in_cli:
        print(f"📁 {msgs['VOLUMES']}")
        if volumes_only_in_dc:
            print(f"   DevContainer {msgs['ONLY_IN']} ({DEVCONTAINER_COMPOSE_SHORT})")
            for line in volumes_only_in_dc:
                print(f"      - {line}")
        if volumes_only_in_cli:
            print(f"   CLI Sandbox {msgs['ONLY_IN']} ({CLI_SANDBOX_COMPOSE_SHORT})")
            for line in volumes_only_in_cli:
                print(f"      - {line}")
        print()

    if tmpfs_only_in_dc or tmpfs_only_in_cli:
        print(f"📁 {msgs['TMPFS']}")
        if tmpfs_only_in_dc:
            print(f"   DevContainer {msgs['ONLY_IN']} ({DEVCONTAINER_COMPOSE_SHORT})")
            for line in tmpfs_only_in_dc:
                print(f"      - {line}")
        if tmpfs_only_in_cli:
            print(f"   CLI Sandbox {msgs['ONLY_IN']} ({CLI_SANDBOX_COMPOSE_SHORT})")
            for line in tmpfs_only_in_cli:
                print(f"      - {line}")
        print()

    print("─" * 59)
    print(msgs["PROMPT"])
    print()
    print(f"  1) {msgs['YES_ALL']}")
    print(f"  2) {msgs['YES_EACH']}")
    print(f"  3) {msgs['NO']}")
    print(f"  4) {msgs['PREVIEW']}")
    print()
    # Not localized in the bash original -- kept verbatim for parity.
    # bash版でも常に英語（他プロンプトと違いローカライズされていない）--
    # パリティのためそのまま維持。
    choice = prompt("Select [1/2/3/4]: ")

    synced_entries = []

    def sync_all() -> None:
        create_backups(backup_keep_count, msgs)

        for mount in volumes_only_in_dc:
            print(f"{msgs['ADDING']} {mount}")
            print(f"   {msgs['TO_FILE']} {CLI_SANDBOX_COMPOSE_SHORT}")
            if add_devnull_mount(mount, CLI_SANDBOX_COMPOSE):
                print(f"   {msgs['ADDED']}")
                synced_entries.append(mount)

        for mount in tmpfs_only_in_dc:
            print(f"{msgs['ADDING']} {mount}")
            print(f"   {msgs['TO_FILE']} {CLI_SANDBOX_COMPOSE_SHORT}")
            if add_tmpfs_mount(mount, CLI_SANDBOX_COMPOSE):
                print(f"   {msgs['ADDED']}")
                synced_entries.append(mount)

        for mount in volumes_only_in_cli:
            print(f"{msgs['ADDING']} {mount}")
            print(f"   {msgs['TO_FILE']} {DEVCONTAINER_COMPOSE_SHORT}")
            if add_devnull_mount(mount, DEVCONTAINER_COMPOSE):
                print(f"   {msgs['ADDED']}")
                synced_entries.append(mount)

        for mount in tmpfs_only_in_cli:
            print(f"{msgs['ADDING']} {mount}")
            print(f"   {msgs['TO_FILE']} {DEVCONTAINER_COMPOSE_SHORT}")
            if add_tmpfs_mount(mount, DEVCONTAINER_COMPOSE):
                print(f"   {msgs['ADDED']}")
                synced_entries.append(mount)

    def sync_each() -> None:
        create_backups(backup_keep_count, msgs)

        def review(mounts: list, icon: str, target_file: Path, target_short: str, add_fn) -> None:
            for mount in mounts:
                print()
                print(f"{icon} {mount}")
                print(f"   {msgs['TO_FILE']} {target_short}")
                confirm = prompt(f"   {msgs['CONFIRM']} [y/N]: ")
                if re.match(r"^[Yy]$", confirm):
                    if add_fn(mount, target_file):
                        print(f"   {msgs['ADDED']}")
                        synced_entries.append(mount)
                else:
                    print(f"   {msgs['SKIPPED']}")

        review(volumes_only_in_dc, "📄", CLI_SANDBOX_COMPOSE, CLI_SANDBOX_COMPOSE_SHORT, add_devnull_mount)
        review(tmpfs_only_in_dc, "📁", CLI_SANDBOX_COMPOSE, CLI_SANDBOX_COMPOSE_SHORT, add_tmpfs_mount)
        review(volumes_only_in_cli, "📄", DEVCONTAINER_COMPOSE, DEVCONTAINER_COMPOSE_SHORT, add_devnull_mount)
        review(tmpfs_only_in_cli, "📁", DEVCONTAINER_COMPOSE, DEVCONTAINER_COMPOSE_SHORT, add_tmpfs_mount)

    def show_preview() -> None:
        if volumes_only_in_dc or tmpfs_only_in_dc:
            print()
            print("━" * 60)
            print(f"{msgs['PREVIEW_HEADER']} {CLI_SANDBOX_COMPOSE_SHORT}")
            print("━" * 60)
            if volumes_only_in_dc:
                print()
                print(msgs["PREVIEW_VOLUMES"])
                for mount in volumes_only_in_dc:
                    print(f"      - {mount}")
            if tmpfs_only_in_dc:
                print()
                print(msgs["PREVIEW_TMPFS"])
                for mount in tmpfs_only_in_dc:
                    print(f"      - {mount}")

        if volumes_only_in_cli or tmpfs_only_in_cli:
            print()
            print("━" * 60)
            print(f"{msgs['PREVIEW_HEADER']} {DEVCONTAINER_COMPOSE_SHORT}")
            print("━" * 60)
            if volumes_only_in_cli:
                print()
                print(msgs["PREVIEW_VOLUMES"])
                for mount in volumes_only_in_cli:
                    print(f"      - {mount}")
            if tmpfs_only_in_cli:
                print()
                print(msgs["PREVIEW_TMPFS"])
                for mount in tmpfs_only_in_cli:
                    print(f"      - {mount}")
        print()

    if choice == "1":
        sync_all()
    elif choice == "2":
        sync_each()
    elif choice == "3":
        print()
        print(msgs["SKIPPED"])
        sys.exit(0)
    elif choice == "4":
        show_preview()
        sys.exit(0)
    else:
        print()
        print(msgs["SKIPPED"])
        sys.exit(0)

    print()
    print("━" * 60)
    print(msgs["DONE_HEADER"])
    print()

    if synced_entries:
        print(msgs["DONE_ADDED"])
        for entry in synced_entries:
            print(f"   ✅ {entry}")
        print()
        print("─" * 59)
        print(msgs["REBUILD"])
        print(msgs["REBUILD_DC"])
        print(msgs["REBUILD_CLI"])
    else:
        print(msgs["DONE_NONE"])
    print("━" * 60)
    print()


if __name__ == "__main__":
    main()

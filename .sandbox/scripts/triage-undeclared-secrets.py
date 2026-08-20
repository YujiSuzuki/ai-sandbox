#!/usr/bin/env python3
# triage-undeclared-secrets.py
# Interactively triage findings from check-undeclared-secrets.py: per item, the user judges
# it a real secret (hide via docker-compose.yml), not a secret (add to sync-ignore), or skip.
#
# Usage: .sandbox/scripts/triage-undeclared-secrets.py [--dry-run]
#   --dry-run: Show what each finding would become without prompting or writing anything
#
# IMPORTANT: Must run inside AI Sandbox container (not on host OS).
#
# Parses check-undeclared-secrets.py's --format json output with Python's
# own json module; has no jq dependency.
# @env: container
# ---
# check-undeclared-secrets.py の検出結果を1件ずつ対話式に処理する:
# ユーザーが中身を確認し、本物の秘密なら docker-compose.yml で隠蔽 / 秘密でなければ
# sync-ignore に追記 / 判断しないならスキップ、を選ぶ。
#
# 使用法: .sandbox/scripts/triage-undeclared-secrets.py [--dry-run]
#   --dry-run: プロンプトも書き込みも行わず、各検出結果がどう処理されるかのみ表示
#
# check-undeclared-secrets.py の --format json 出力の解析にPythonの
# json モジュールを使う。jqへの依存はない。

import json
import os
import re
import subprocess
import sys
from pathlib import Path

from _python_common import add_sync_ignore_pattern, backup_file, cleanup_backups, is_lang_ja, load_startup_config, print_footer, print_title
from _secret_tag import secret_tag_exact_regex

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

CHECK_SCRIPT = Path(os.environ.get("CHECK_SCRIPT", str(WORKSPACE / ".sandbox" / "scripts" / "check-undeclared-secrets.py")))

DEVCONTAINER_COMPOSE = WORKSPACE / ".devcontainer" / "docker-compose.yml"
CLI_SANDBOX_COMPOSE = WORKSPACE / "cli_sandbox" / "docker-compose.yml"
LABEL_DC = "DevContainer"
LABEL_CLI = "CLI Sandbox"

SYNC_IGNORE_FILE = WORKSPACE / ".sandbox" / "config" / "sync-ignore"

DRY_RUN = len(sys.argv) > 1 and sys.argv[1] == "--dry-run"


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "🕵️  未宣言シークレットのトリアージ",
            "DISCLAIMER": "名前パターンによる検出結果です。1件ずつ確認しながら処理してください。",
            "COMPOSE_FOUND": "検出された docker-compose.yml:",
            "NO_COMPOSE": "docker-compose.yml が見つかりません（両方とも）",
            "NONE_FOUND": "✅ 対処が必要な未宣言ファイルはありません。",
            "FOUND_COUNT": "件の未宣言ファイルが見つかりました。1件ずつ確認します。",
            "CLAUDE_ONLY_NOTE": "（.claude/settings.json では既にカバー済み。sync-secrets.py で対処できます）",
            "FILE_TYPE": "File",
            "DIR_TYPE": "Dir",
            "CONFIRM_WARNING": "⚠️  ファイル名からの自動判定です。選択前に中身を確認してください",
            "OPT_HIDE": "1) 本物の秘密だと判断 → docker-compose.yml で隠蔽",
            "OPT_IGNORE": "2) 秘密ではないと判断 → sync-ignore に追加",
            "OPT_SKIP": "3) 今は判断しない → スキップ",
            "PROMPT": "選択 [1/2/3]: ",
            "HIDDEN": "✅ 隠蔽しました",
            "IGNORED_ACTION": "✅ sync-ignore に追加しました",
            "SKIPPED": "⏭️  スキップしました",
            "BACKUP": "バックアップを作成しました:",
            "HIDE_FAILED": "⚠️  隠蔽に失敗しました（手動で追加してください）",
            "SUMMARY_HEADER": "完了！",
            "SUMMARY_HIDDEN": "隠蔽したファイル:",
            "SUMMARY_IGNORED": "sync-ignore に追加したファイル:",
            "SUMMARY_SKIPPED": "スキップした件数:",
            "SUMMARY_NONE": "変更はありませんでした",
            "REBUILD": "変更を反映するにはコンテナをリビルドしてください:",
            "REBUILD_CMD": "  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'",
            "REBUILD_CLI": "  CLI: ./cli_sandbox/build.sh",
            "DRY_RUN_HEADER": "🔍 ドライラン: 変更は行われません",
            "DRY_RUN_HIDE": "  隠蔽する場合 →",
            "DRY_RUN_IGNORE": "  無視する場合 →",
        }
    return {
        "TITLE": "🕵️  Undeclared Secrets Triage",
        "DISCLAIMER": "Based on name-pattern detection -- review each item as you go.",
        "COMPOSE_FOUND": "Detected docker-compose.yml:",
        "NO_COMPOSE": "docker-compose.yml not found (neither file exists)",
        "NONE_FOUND": "✅ No undeclared files need action.",
        "FOUND_COUNT": "undeclared file(s) found. Reviewing one at a time.",
        "CLAUDE_ONLY_NOTE": "(already covered by .claude/settings.json -- can also be handled by sync-secrets.py)",
        "FILE_TYPE": "File",
        "DIR_TYPE": "Dir",
        "CONFIRM_WARNING": "⚠️  Detected by filename only -- check the file's actual content before choosing",
        "OPT_HIDE": "1) Judged as a real secret -> hide via docker-compose.yml",
        "OPT_IGNORE": "2) Judged as not a secret -> add to sync-ignore",
        "OPT_SKIP": "3) Not decided yet -> skip",
        "PROMPT": "Select [1/2/3]: ",
        "HIDDEN": "✅ Hidden",
        "IGNORED_ACTION": "✅ Added to sync-ignore",
        "SKIPPED": "⏭️  Skipped",
        "BACKUP": "Backup created:",
        "HIDE_FAILED": "⚠️  Failed to hide (please add manually)",
        "SUMMARY_HEADER": "Done!",
        "SUMMARY_HIDDEN": "Hidden:",
        "SUMMARY_IGNORED": "Added to sync-ignore:",
        "SUMMARY_SKIPPED": "Skipped:",
        "SUMMARY_NONE": "No changes were made",
        "REBUILD": "Rebuild containers to apply changes:",
        "REBUILD_CMD": "  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'",
        "REBUILD_CLI": "  CLI: ./cli_sandbox/build.sh",
        "DRY_RUN_HEADER": "🔍 Dry-run: no changes will be made",
        "DRY_RUN_HIDE": "  If hidden ->",
        "DRY_RUN_IGNORE": "  If ignored ->",
    }


# ============================================================
# docker-compose.yml edit helpers
#
# Intentionally duplicated from sync-secrets.py rather than extracted into
# a shared lib: check-undeclared-secrets.py already has its own independent
# compose-detection logic (is_path_hidden_by_compose) rather than reusing
# sync-secrets.py's, so per-script duplication of this straightforward
# text editing is the existing convention here -- only the "# @secret" tag
# regex that all the secret-sync scripts must agree on byte-for-byte lives
# in a shared file (_secret_tag.py). If a third caller needs this logic,
# extract it then.
#
# sync-secrets.py から意図的に複製している（共通ライブラリへは切り出さない）:
# check-undeclared-secrets.py も sync-secrets.py とは別に独自の compose 検出
# ロジック(is_path_hidden_by_compose)を持っており、この程度のテキスト編集は
# スクリプトごとに複製するのがこのプロジェクトの既存の流儀。すべての
# secret-sync系スクリプトが完全一致で合意する必要がある "# @secret" タグの
# 正規表現だけが共通ファイル (_secret_tag.py) にある。3箇所目の呼び出しが
# 必要になったら切り出す。
# ============================================================

def is_file_in_compose(file_path: str, compose_file: Path) -> bool:
    escaped_file_path = re.escape(file_path)
    devnull_re = re.compile(r"^\s*-\s*/dev/null:" + escaped_file_path + r"(:ro)?$")
    try:
        compose_lines = compose_file.read_text().splitlines()
    except OSError:
        compose_lines = []
    for line in compose_lines:
        if devnull_re.search(line):
            return True

    # Start at file_path itself, not its parent -- file_path may itself be a
    # directory that's already tagged (e.g. hidden in one compose file but
    # not the other), and that exact-path match must be checked before
    # walking ancestors.
    # file_path自身から開始する（親ディレクトリからではない）--
    # file_path自体がタグ付き済みのディレクトリである場合があり
    # （例: 一方のcomposeファイルでは既に隠蔽済みだがもう一方では未隠蔽）、
    # 祖先を辿る前にこの完全一致をチェックする必要がある。
    dir_path = file_path
    while dir_path != WORKSPACE_STR and dir_path != "/":
        escaped_dir_path = re.escape(dir_path)
        tmpfs_re = re.compile(secret_tag_exact_regex(escaped_dir_path))
        for line in compose_lines:
            if tmpfs_re.search(line):
                return True
        dir_path = os.path.dirname(dir_path)

    return False


def add_file_to_compose(file_path: str, compose_file: Path) -> bool:
    lines = compose_file.read_text().splitlines()
    last_idx = None
    for i, line in enumerate(lines):
        if "/dev/null:" in line:
            last_idx = i
    if last_idx is None:
        print(f"Warning: Could not find existing /dev/null mounts in {compose_file}")
        print(f"Please add manually: - /dev/null:{file_path}:ro")
        return False
    lines.insert(last_idx + 1, f"      - /dev/null:{file_path}:ro")
    compose_file.write_text("\n".join(lines) + "\n")
    return True


def add_dir_to_compose(dir_path: str, compose_file: Path) -> bool:
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
        print(f"Please add manually under tmpfs: - {dir_path}  # @secret")
        return False
    lines.insert(last_tmpfs_idx + 1, f"      - {dir_path}  # @secret")
    compose_file.write_text("\n".join(lines) + "\n")
    return True


def get_compose_label(compose_file: Path) -> str:
    if compose_file == DEVCONTAINER_COMPOSE:
        return LABEL_DC
    if compose_file == CLI_SANDBOX_COMPOSE:
        return LABEL_CLI
    return str(compose_file)


# Hide one path via compose in every compose file where it's still missing.
# Backs up each compose file at most once per run, only on its first actual
# write (lazy -- a run where every item is skipped creates zero backups).
# 未宣言のすべての compose ファイルにパスを隠蔽する。各 compose ファイルの
# バックアップは実行中に初めて書き込みが発生した時点で1回だけ作る
# （遅延方式 -- 全件スキップされた実行ではバックアップは作られない）。
_BACKED_UP_COMPOSE = set()


def hide_path_in_composes(path: str, is_dir: bool, compose_files: list, backup_keep_count: str, msgs: dict) -> bool:
    any_success = False
    for compose_file in compose_files:
        if is_file_in_compose(path, compose_file):
            continue

        if compose_file not in _BACKED_UP_COMPOSE:
            label = get_compose_label(compose_file)
            backup_label = label.lower().replace(" ", "_")
            backup_path = backup_file(str(compose_file), backup_label)
            print(f"   {msgs['BACKUP']} {backup_path}")
            cleanup_backups(f"{backup_label}.docker-compose.yml.*", backup_keep_count)
            _BACKED_UP_COMPOSE.add(compose_file)

        success = add_dir_to_compose(path, compose_file) if is_dir else add_file_to_compose(path, compose_file)
        any_success = any_success or success

    return any_success


# Add to sync-ignore, backing it up at most once per run on first write.
# sync-ignore に追加。バックアップは実行中の初回書き込み時に1回だけ作る。
_BACKED_UP_SYNC_IGNORE = False


def ignore_path(rel_path: str, backup_keep_count: str, msgs: dict) -> None:
    global _BACKED_UP_SYNC_IGNORE
    if not _BACKED_UP_SYNC_IGNORE and SYNC_IGNORE_FILE.is_file():
        backup_path = backup_file(str(SYNC_IGNORE_FILE), "sync_ignore")
        print(f"   {msgs['BACKUP']} {backup_path}")
        cleanup_backups("sync_ignore.sync-ignore.*", backup_keep_count)
        _BACKED_UP_SYNC_IGNORE = True

    add_sync_ignore_pattern(rel_path)


# ─── Main / メイン処理 ──────────────────────────────────────────

def main() -> None:
    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    verbosity = load_startup_config()["verbosity"]
    backup_keep_count = load_startup_config()["backup_keep_count"]

    print_title(msgs["TITLE"], verbosity)
    print(msgs["DISCLAIMER"])
    print()

    compose_files = []
    compose_labels = []
    if DEVCONTAINER_COMPOSE.is_file():
        compose_files.append(DEVCONTAINER_COMPOSE)
        compose_labels.append(LABEL_DC)
    if CLI_SANDBOX_COMPOSE.is_file():
        compose_files.append(CLI_SANDBOX_COMPOSE)
        compose_labels.append(LABEL_CLI)

    if not compose_files:
        print(f"❌ {msgs['NO_COMPOSE']}")
        sys.exit(1)

    print(msgs["COMPOSE_FOUND"])
    for label, compose_file in zip(compose_labels, compose_files):
        print(f"   📄 {label}: {compose_file}")
    print()

    if not os.access(CHECK_SCRIPT, os.X_OK):
        print(f"❌ {CHECK_SCRIPT} not found or not executable")
        sys.exit(1)

    scan_result = subprocess.run([str(CHECK_SCRIPT), "--format", "json"], capture_output=True, text=True)
    if scan_result.returncode != 0:
        print(f"❌ {CHECK_SCRIPT} exited with an error:")
        print(scan_result.stderr.strip())
        sys.exit(1)
    try:
        scan_json = json.loads(scan_result.stdout)
    except json.JSONDecodeError:
        print(f"❌ {CHECK_SCRIPT} did not produce valid JSON output")
        sys.exit(1)
    undeclared_rel = scan_json["undeclared"]
    claude_only_rel = set(scan_json["claude_only"])

    if not undeclared_rel:
        print(msgs["NONE_FOUND"])
        print_footer(verbosity)
        sys.exit(0)

    if DRY_RUN:
        print(msgs["DRY_RUN_HEADER"])
        print()
        sync_ignore_rel = str(SYNC_IGNORE_FILE)[len(WORKSPACE_STR) + 1:]
        for rel_path in undeclared_rel:
            local_path = WORKSPACE / rel_path
            print(f"📄 {rel_path}")
            if local_path.is_dir():
                print(f"{msgs['DRY_RUN_HIDE']}      - {local_path}  # @secret")
            else:
                print(f"{msgs['DRY_RUN_HIDE']}      - /dev/null:{local_path}:ro")
            print(f"{msgs['DRY_RUN_IGNORE']}    {rel_path}  ({sync_ignore_rel})")
            print()
        print_footer(verbosity)
        sys.exit(0)

    print(f"{len(undeclared_rel)} {msgs['FOUND_COUNT']}")
    print()

    hidden_list = []
    ignored_list = []
    skipped_count = 0

    for rel_path in undeclared_rel:
        local_path = WORKSPACE / rel_path
        is_dir = local_path.is_dir()
        type_label = f"[{msgs['DIR_TYPE']}]" if is_dir else f"[{msgs['FILE_TYPE']}]"

        print(f"📄 {rel_path} {type_label}")
        if rel_path in claude_only_rel:
            print(f"   {msgs['CLAUDE_ONLY_NOTE']}")
        print(f"   {msgs['CONFIRM_WARNING']}")
        print(f"   {msgs['OPT_HIDE']}")
        print(f"   {msgs['OPT_IGNORE']}")
        print(f"   {msgs['OPT_SKIP']}")
        # bash's `read -rp` only writes its prompt (to stderr, without a
        # trailing newline) when stdin is an actual terminal -- it is
        # silently suppressed entirely when stdin is piped (confirmed
        # empirically; this is also documented `read` behavior). Python's
        # input() always writes its prompt to stdout regardless, so match
        # bash by gating a manual stderr write on sys.stdin.isatty()
        # instead of passing a prompt to input().
        # bashの`read -rp`は、stdinが実端末のときだけプロンプトを（標準エラー
        # へ、改行なしで）出力し、stdinがパイプの場合は完全に抑制される
        # （実測で確認済み。`read`のドキュメントにも記載の挙動）。Pythonの
        # input()は常にプロンプトを標準出力へ書くため、input()に直接
        # プロンプトを渡すのではなく、sys.stdin.isatty()で条件分岐した
        # 標準エラーへの手動書き込みでbashに合わせる。
        if sys.stdin.isatty():
            sys.stderr.write(f"   {msgs['PROMPT']}")
            sys.stderr.flush()
        try:
            choice = input()
        except EOFError:
            sys.exit(1)

        if choice == "1":
            if hide_path_in_composes(str(local_path), is_dir, compose_files, backup_keep_count, msgs):
                print(f"   {msgs['HIDDEN']}")
                hidden_list.append(rel_path)
            else:
                print(f"   {msgs['HIDE_FAILED']}")
        elif choice == "2":
            ignore_path(rel_path, backup_keep_count, msgs)
            print(f"   {msgs['IGNORED_ACTION']}")
            ignored_list.append(rel_path)
        else:
            print(f"   {msgs['SKIPPED']}")
            skipped_count += 1
        print()

    print("━" * 60)
    print(msgs["SUMMARY_HEADER"])
    print()

    if not hidden_list and not ignored_list and skipped_count == len(undeclared_rel):
        print(msgs["SUMMARY_NONE"])
    else:
        if hidden_list:
            print(msgs["SUMMARY_HIDDEN"])
            for f in hidden_list:
                print(f"   ✅ {f}")
        if ignored_list:
            print(msgs["SUMMARY_IGNORED"])
            for f in ignored_list:
                print(f"   ✅ {f}")
        print(f"{msgs['SUMMARY_SKIPPED']} {skipped_count}")

    if hidden_list:
        print()
        print("─" * 59)
        print(msgs["REBUILD"])
        print(msgs["REBUILD_CMD"])
        print(msgs["REBUILD_CLI"])

    print_footer(verbosity)
    sys.exit(0)


if __name__ == "__main__":
    main()

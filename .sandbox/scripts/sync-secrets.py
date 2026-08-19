#!/usr/bin/env python3
# sync-secrets.py
# Interactive script to sync secret files from .claude/settings.json to docker-compose.yml
#
# This script finds files blocked in Claude settings that are not hidden in docker-compose.yml,
# and offers to add them interactively. Updates both DevContainer and CLI Sandbox configs.
#
# IMPORTANT: Must run inside AI Sandbox container (not on host OS).
#
# Note: is_file_in_compose() below escapes file_path before embedding it in
# a grep -E-equivalent regex. The bash original (and an earlier byte-for-
# byte Python port of it) did NOT escape it, unlike every other secret-sync
# script -- a real bug where a path containing a regex metacharacter (e.g.
# a "+") could be misreported as "not configured" even when it was already
# correctly declared in docker-compose.yml. Fixed here at the user's
# request rather than preserved for bash parity.
# @env: container
# ---
# .claude/settings.json から docker-compose.yml へ秘匿ファイルを同期する対話式スクリプト
# このスクリプトは Claude 設定でブロックされているが docker-compose.yml で隠蔽されていない
# ファイルを見つけ、対話式で追加を提案します。DevContainer と CLI Sandbox の両方を更新します。
#
# 注意: 下記の is_file_in_compose() は、file_pathを正規表現（grep -E相当）に
# 埋め込む前にエスケープしている。bash版（および以前のバイト単位Python移植）
# はエスケープしておらず、他のsecret-sync系スクリプトと異なる実バグだった --
# パスに正規表現メタ文字（例: "+"）が含まれると、docker-compose.ymlに正しく
# 宣言済みでも「未設定」と誤って報告されることがあった。bash版とのパリティ
# より、ユーザーの依頼によりここで修正した。

import fnmatch
import glob as globmod
import json
import os
import re
import sys
from pathlib import Path

from _python_common import add_sync_ignore_pattern, backup_file, cleanup_backups, is_lang_ja, load_startup_config, matches_sync_ignore, print_footer
from _secret_tag import secret_tag_exact_regex

# ─── Host OS guard / ホストOSガード ─────────────────────────────

if not os.environ.get("SANDBOX_ENV") and not os.path.isfile("/.dockerenv"):
    if is_lang_ja():
        print("❌ このスクリプトはホストOSでは実行できません。")
        print()
        print("以下のいずれかの環境で実行してください：")
        print("  • AI Sandbox のターミナル")
        print("  • cli_sandbox/ai_sandbox.sh")
        print()
        print("または、手動で docker-compose.yml を編集してください。")
    else:
        print("❌ This script cannot be run on the host OS.")
        print()
        print("Please run in one of these environments:")
        print("  • AI Sandbox terminal")
        print("  • cli_sandbox/ai_sandbox.sh")
        print()
        print("Or manually edit docker-compose.yml.")
    sys.exit(1)

WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
WORKSPACE_STR = str(WORKSPACE)
WORKSPACE_RE = re.escape(WORKSPACE_STR)

DEVCONTAINER_COMPOSE = WORKSPACE / ".devcontainer" / "docker-compose.yml"
CLI_SANDBOX_COMPOSE = WORKSPACE / "cli_sandbox" / "docker-compose.yml"
CLAUDE_SETTINGS = WORKSPACE / ".claude" / "settings.json"

LABEL_DC = "DevContainer"
LABEL_CLI = "CLI Sandbox"

_PRUNE_DIRS = {"node_modules", ".git", ".sandbox"}


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "🔧 シークレット設定同期ツール",
            "CHECKING": "チェック中...",
            "NO_SETTINGS": "Claude 設定ファイルが見つかりません",
            "NO_COMPOSE": "docker-compose.yml が見つかりません（両方とも）",
            "ALL_SYNCED": "✅ すべての秘匿ファイルが同期されています。追加は不要です。",
            "FOUND_HEADER": "以下のファイルが docker-compose.yml に未設定です:",
            "MISSING_FROM": "未設定:",
            "PROMPT_ALL": "これらすべてを docker-compose.yml に追加しますか？",
            "YES_ALL": "すべて追加",
            "YES_EACH": "個別確認",
            "NO": "追加しない",
            "PREVIEW": "プレビュー表示（ドライラン）",
            "CONFIRM_FILE": "追加しますか？",
            "ADDING": "追加中:",
            "ADDED": "✅ 追加しました",
            "SKIPPED": "⏭️  スキップしました",
            "DONE_HEADER": "完了！",
            "DONE_ADDED": "追加されたファイル:",
            "DONE_NONE": "追加されたファイルはありません",
            "REBUILD": "変更を反映するにはコンテナをリビルドしてください:",
            "REBUILD_CMD": "  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'",
            "REBUILD_CLI": "  CLI: ./cli_sandbox/build.sh",
            "NO_DENY": "deny 設定にファイルパターンがありません",
            "NO_FILES": "該当するファイルが見つかりませんでした",
            "BACKUP": "バックアップを作成しました:",
            "FILE_TYPE": "ファイル",
            "DIR_TYPE": "ディレクトリ",
            "PREVIEW_HEADER": "以下を docker-compose.yml に追加してください:",
            "PREVIEW_VOLUMES": "📄 volumes セクションに追加:",
            "PREVIEW_TMPFS": "📁 tmpfs セクションに追加:",
            "PREVIEW_FOOTER": "上記をコピーして docker-compose.yml に貼り付けてください",
            "TARGET_FILES": "対象ファイル:",
            "COMPOSE_FOUND": "検出された docker-compose.yml:",
            "IGNORED": "件のファイルが無視されました (sync-ignore パターンにマッチ)",
        }
    return {
        "TITLE": "🔧 Secret Config Sync Tool",
        "CHECKING": "Checking...",
        "NO_SETTINGS": "Claude settings file not found",
        "NO_COMPOSE": "docker-compose.yml not found (neither file exists)",
        "ALL_SYNCED": "✅ All secret files are synced. No additions needed.",
        "FOUND_HEADER": "The following files are NOT configured in docker-compose.yml:",
        "MISSING_FROM": "Missing from:",
        "PROMPT_ALL": "Add all of these to docker-compose.yml?",
        "YES_ALL": "Add all",
        "YES_EACH": "Review each",
        "NO": "Don't add",
        "PREVIEW": "Preview (dry-run)",
        "CONFIRM_FILE": "Add this file?",
        "ADDING": "Adding:",
        "ADDED": "✅ Added",
        "SKIPPED": "⏭️  Skipped",
        "DONE_HEADER": "Done!",
        "DONE_ADDED": "Files added:",
        "DONE_NONE": "No files were added",
        "REBUILD": "Rebuild containers to apply changes:",
        "REBUILD_CMD": "  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'",
        "REBUILD_CLI": "  CLI: ./cli_sandbox/build.sh",
        "NO_DENY": "No file patterns in deny settings",
        "NO_FILES": "No matching files found",
        "BACKUP": "Backup created:",
        "FILE_TYPE": "File",
        "DIR_TYPE": "Directory",
        "PREVIEW_HEADER": "Add the following to docker-compose.yml:",
        "PREVIEW_VOLUMES": "📄 Add to volumes section:",
        "PREVIEW_TMPFS": "📁 Add to tmpfs section:",
        "PREVIEW_FOOTER": "Copy and paste the above into your docker-compose.yml",
        "TARGET_FILES": "Target files:",
        "COMPOSE_FOUND": "Detected docker-compose.yml:",
        "IGNORED": "file(s) ignored (matched sync-ignore patterns)",
    }


# ─── Prompting / プロンプト ──────────────────────────────────────

def prompt(text: str) -> str:
    """Mirrors bash's `read -rp`: the prompt is only actually shown (to
    stderr, without a trailing newline) when stdin is a real terminal --
    suppressed entirely when piped. See sync-compose-secrets.py /
    triage-undeclared-secrets.py for the same handling.

    bashの`read -rp`を再現する: プロンプトはstdinが実端末のときだけ実際に
    表示される（標準エラーへ、改行なしで）-- パイプの場合は完全に抑制
    される。sync-compose-secrets.py / triage-undeclared-secrets.py と同じ
    処理。
    """
    if sys.stdin.isatty():
        sys.stderr.write(text)
        sys.stderr.flush()
    try:
        return input()
    except EOFError:
        sys.exit(1)


# ─── Pattern-to-files matching / パターン→ファイルのマッチング ───

def _walk_files(root: Path) -> list:
    results = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in _PRUNE_DIRS]
        for f in files:
            results.append(os.path.join(dirpath, f))
    return results


def _find_dirs_matching_suffix(workspace: Path, suffix: str) -> list:
    """All directories anywhere under workspace whose path relative to
    workspace equals `suffix` or ends with "/" + suffix -- i.e. a match at
    any depth that respects path-segment boundaries.

    workspace配下のディレクトリのうち、workspace相対パスが`suffix`と完全
    一致するか、"/" + `suffix` で終わるものすべて -- パスの区切りを尊重した
    任意の深さでのマッチ。
    """
    results = []
    workspace_str = str(workspace)
    for dirpath, dirs, _files in os.walk(workspace):
        dirs[:] = [d for d in dirs if d not in _PRUNE_DIRS]
        for d in dirs:
            full = os.path.join(dirpath, d)
            rel = full[len(workspace_str) + 1:]
            if rel == suffix or rel.endswith("/" + suffix):
                results.append(full)
    return results


def find_matching_files(pattern: str, workspace: Path) -> list:
    """Find files matching a deny pattern, scoping a specific (non-"**/"-
    prefixed) path pattern to its literal location rather than matching by
    basename anywhere in the workspace.

    Fixes two bugs present in the bash original (ported byte-for-byte in an
    earlier commit before being fixed here at the user's request): (1) any
    "/" in the pattern routed matching into an unscoped "search everywhere
    by basename" mode even for patterns with no "**" at all, so e.g.
    "demo-app/.env" incorrectly matched any ".env" file anywhere in the
    workspace, not just demo-app/.env; (2) this script's original had no
    trailing-slash directory-pattern branch at all, so a plain directory
    pattern like "secrets/" fell into that same unscoped mode and, after
    being stripped down to an empty string, matched zero files -- silently
    missing every file under that directory. This version adds the
    trailing-slash branch (matching check-secret-sync.py's, which already
    had one) and fixes the same underlying stripping bug there too.

    Convention: a "**/" prefix means "at any depth"; anything else is a
    literal path (or glob) relative to $WORKSPACE.

    deny パターンに一致するファイルを検索する。"**/"接頭辞を伴わない特定の
    パスパターンを、ワークスペース内のどこでもベース名一致させるのではなく、
    その文字通りの場所にスコープする。

    bash版に元々あった（そして以前のコミットではバイト単位でそのまま移植して
    いた）2つのバグを、ユーザーの依頼によりここで修正する: (1) パターンに
    "/"が含まれてさえいれば（"**"を一切含まないパターンでも）無スコープの
    「ワークスペース全体をベース名で検索」モードに入ってしまい、例えば
    "demo-app/.env" が demo-app/.env だけでなくワークスペース中のどの
    ".env" ファイルにも誤ってマッチしていた。(2) このスクリプトの原本には
    末尾スラッシュのディレクトリパターン分岐が元々無く、"secrets/"のような
    単純なディレクトリパターンも同じ無スコープモードに巻き込まれ、空文字列
    まで削ぎ落とされた結果ゼロ件マッチとなっていた。この版では
    check-secret-sync.py（既に分岐を持っていた）と同様に末尾スラッシュ分岐を
    追加し、そちらにあった同種の削ぎ落としバグも合わせて修正した。

    規約: "**/"接頭辞は「任意の深さで」を意味する。それ以外は $WORKSPACE
    からのリテラルなパス（またはglob）として扱う。
    """
    # Directory patterns (trailing slash) / ディレクトリパターン（末尾スラッシュ）
    if pattern.endswith("/"):
        dir_pattern = pattern[:-1]
        if dir_pattern.startswith("**/"):
            suffix = dir_pattern[3:]
            results = []
            for d in _find_dirs_matching_suffix(workspace, suffix):
                results.extend(_walk_files(Path(d)))
            return results
        full_dir = workspace / dir_pattern
        if full_dir.is_dir():
            return _walk_files(full_dir)
        return []

    # Directory-recursive-glob suffix, e.g. "secrets/**" or "**/secrets/**"
    # ディレクトリ再帰glob接尾辞（例: "secrets/**", "**/secrets/**"）
    if pattern.endswith("/**"):
        dir_part = pattern[: -len("/**")]
        if dir_part.startswith("**/"):
            suffix = dir_part[3:]
            results = []
            for d in _find_dirs_matching_suffix(workspace, suffix):
                results.extend(_walk_files(Path(d)))
            return results
        full_dir = workspace / dir_part
        if full_dir.is_dir():
            return _walk_files(full_dir)
        return []

    # Recursive file glob, e.g. "**/*.env" or "**/sub/*.key"
    # 再帰ファイルglob（例: "**/*.env", "**/sub/*.key"）
    if pattern.startswith("**/"):
        suffix = pattern[3:]
        results = []
        for dirpath, dirs, files in os.walk(workspace):
            dirs[:] = [d for d in dirs if d not in _PRUNE_DIRS]
            for f in files:
                full = os.path.join(dirpath, f)
                rel = full[len(str(workspace)) + 1:]
                if fnmatch.fnmatchcase(rel, suffix) or fnmatch.fnmatchcase(rel, "*/" + suffix):
                    results.append(full)
        return results

    # Specific path pattern relative to $WORKSPACE, e.g. "demo-app/.env", or
    # a root-level glob like "*.key" (glob.glob doesn't cross "/" boundaries,
    # so this only ever matches at the exact directory level named).
    # $WORKSPACE からの具体的パスパターン（例: "demo-app/.env"）、または
    # ルートレベルのglob（例: "*.key"。glob.globは"/"境界を越えないため、
    # 指定した階層でのみマッチする）。
    full_path = workspace / pattern
    if "*" in pattern:
        return sorted(globmod.glob(str(full_path)))
    if full_path.is_file():
        return [str(full_path)]
    if full_path.is_dir():
        return _walk_files(full_path)
    return []


def extract_deny_patterns(settings_file: Path) -> list:
    """Extract Read() patterns from .claude/settings.json.

    .claude/settings.json から Read() パターンを抽出
    """
    if not settings_file.is_file():
        return []
    try:
        data = json.loads(settings_file.read_text())
        deny = data["permissions"]["deny"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError):
        return []
    patterns = []
    for item in deny:
        if not isinstance(item, str):
            continue
        m = re.match(r"^Read\(([^)]+)\)$", item)
        if m:
            patterns.append(m.group(1))
    return sorted(set(patterns))


# ─── docker-compose.yml edit helpers / 編集ヘルパー ──────────────

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

    dir_path = os.path.dirname(file_path)
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


def get_path_type(path: str) -> str:
    return "dir" if os.path.isdir(path) else "file"


def get_compose_label(compose_file: Path) -> str:
    if compose_file == DEVCONTAINER_COMPOSE:
        return LABEL_DC
    if compose_file == CLI_SANDBOX_COMPOSE:
        return LABEL_CLI
    return str(compose_file)


def add_to_missing_composes(file: str, compose_files: list, msgs: dict) -> bool:
    path_type = get_path_type(file)
    success = False

    for compose_file in compose_files:
        if not is_file_in_compose(file, compose_file):
            label = get_compose_label(compose_file)
            if path_type == "dir":
                if add_dir_to_compose(file, compose_file):
                    print(f"   {msgs['ADDED']} ({label})")
                    success = True
            else:
                if add_file_to_compose(file, compose_file):
                    print(f"   {msgs['ADDED']} ({label})")
                    success = True

    return success


def create_backups(compose_files: list, backup_keep_count: str, msgs: dict) -> None:
    print()
    for compose_file in compose_files:
        label = get_compose_label(compose_file)
        backup_label = label.lower().replace(" ", "_")
        backup_path = backup_file(str(compose_file), backup_label)
        print(f"{msgs['BACKUP']} {label}")
        print(f"   {backup_path}")
        cleanup_backups(f"{backup_label}.docker-compose.yml.*", backup_keep_count)
    print()


# ─── Main / メイン処理 ──────────────────────────────────────────

def main() -> None:
    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    backup_keep_count = load_startup_config()["backup_keep_count"]

    compose_files = []
    compose_labels = []
    if DEVCONTAINER_COMPOSE.is_file():
        compose_files.append(DEVCONTAINER_COMPOSE)
        compose_labels.append(LABEL_DC)
    if CLI_SANDBOX_COMPOSE.is_file():
        compose_files.append(CLI_SANDBOX_COMPOSE)
        compose_labels.append(LABEL_CLI)

    print()
    print("━" * 60)
    print(msgs["TITLE"])
    print("━" * 60)
    print()

    if not CLAUDE_SETTINGS.is_file():
        print(f"{msgs['NO_SETTINGS']}: {CLAUDE_SETTINGS}")
        sys.exit(1)

    if not compose_files:
        print(msgs["NO_COMPOSE"])
        sys.exit(1)

    print(msgs["COMPOSE_FOUND"])
    for label, compose_file in zip(compose_labels, compose_files):
        print(f"   📄 {label}: {compose_file}")
    print()

    print(msgs["CHECKING"])
    print()

    patterns = extract_deny_patterns(CLAUDE_SETTINGS)
    if not patterns:
        print(msgs["NO_DENY"])
        sys.exit(0)

    all_matching = set()
    for pattern in patterns:
        all_matching.update(find_matching_files(pattern, WORKSPACE))
    all_matching_files = sorted(all_matching)

    if not all_matching_files:
        print(msgs["NO_FILES"])
        sys.exit(0)

    missing_files = []
    ignored_files = []
    missing_labels = {}

    for file in all_matching_files:
        if matches_sync_ignore(file):
            ignored_files.append(file)
            continue

        local_missing = []
        for label, compose_file in zip(compose_labels, compose_files):
            if not is_file_in_compose(file, compose_file):
                local_missing.append(label)
        if local_missing:
            missing_files.append(file)
            missing_labels[file] = ", ".join(local_missing)

    if ignored_files:
        print(f"ℹ️  {len(ignored_files)} {msgs['IGNORED']}")
        print()

    if not missing_files:
        print(msgs["ALL_SYNCED"])
        sys.exit(0)

    def rel(f: str) -> str:
        prefix = WORKSPACE_STR + "/"
        return f[len(prefix):] if f.startswith(prefix) else f

    print(msgs["FOUND_HEADER"])
    print()
    for file in missing_files:
        type_label = f"[{msgs['DIR_TYPE']}]" if os.path.isdir(file) else f"[{msgs['FILE_TYPE']}]"
        print(f"   📄 {rel(file)} {type_label}")
        print(f"      {msgs['MISSING_FROM']} {missing_labels[file]}")
    print()

    print("─" * 59)
    print(msgs["PROMPT_ALL"])
    print()
    print(f"  1) {msgs['YES_ALL']}")
    print(f"  2) {msgs['YES_EACH']}")
    print(f"  3) {msgs['NO']}")
    print(f"  4) {msgs['PREVIEW']}")
    print()
    # Not localized in the bash original -- kept verbatim for parity.
    # bash版でも常に英語（ローカライズされていない）-- パリティのためそのまま維持。
    choice = prompt("Select [1/2/3/4]: ")

    added_files = []

    if choice == "1":
        create_backups(compose_files, backup_keep_count, msgs)
        for file in missing_files:
            print(f"{msgs['ADDING']} {rel(file)}")
            if add_to_missing_composes(file, compose_files, msgs):
                added_files.append(file)

    elif choice == "2":
        create_backups(compose_files, backup_keep_count, msgs)
        for file in missing_files:
            print()
            print(f"📄 {rel(file)}")
            print(f"   {msgs['MISSING_FROM']} {missing_labels[file]}")
            confirm = prompt(f"   {msgs['CONFIRM_FILE']} [y/N]: ")
            if re.match(r"^[Yy]$", confirm):
                if add_to_missing_composes(file, compose_files, msgs):
                    added_files.append(file)
            else:
                print(f"   {msgs['SKIPPED']}")

    elif choice == "3":
        print()
        print(msgs["SKIPPED"])
        sys.exit(0)

    elif choice == "4":
        for label, compose_file in zip(compose_labels, compose_files):
            local_volumes = []
            local_tmpfs = []

            for file in missing_files:
                if not is_file_in_compose(file, compose_file):
                    if os.path.isdir(file):
                        local_tmpfs.append(file)
                    else:
                        local_volumes.append(file)

            if not local_volumes and not local_tmpfs:
                continue

            print()
            print("━" * 60)
            print(f"{msgs['PREVIEW_HEADER']} {label}")
            print(f"   {compose_file}")
            print("━" * 60)
            print()

            if local_volumes:
                print(msgs["PREVIEW_VOLUMES"])
                print()
                for file in local_volumes:
                    print(f"      - /dev/null:{file}:ro")
                print()

            if local_tmpfs:
                print(msgs["PREVIEW_TMPFS"])
                print()
                for d in local_tmpfs:
                    print(f"      - {d}  # @secret")
                print()

        print("─" * 59)
        print(msgs["PREVIEW_FOOTER"])
        print("━" * 60)
        print()
        sys.exit(0)

    else:
        print()
        print(msgs["SKIPPED"])
        sys.exit(0)

    print()
    print("━" * 60)
    print(msgs["DONE_HEADER"])
    print()

    if added_files:
        print(msgs["DONE_ADDED"])
        for file in added_files:
            print(f"   ✅ {rel(file)}")
        print()
        print("─" * 59)
        print(msgs["REBUILD"])
        print(msgs["REBUILD_CMD"])
        print(msgs["REBUILD_CLI"])
    else:
        print(msgs["DONE_NONE"])
    print("━" * 60)
    print()


if __name__ == "__main__":
    main()

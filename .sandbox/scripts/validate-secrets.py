#!/usr/bin/env python3
# validate-secrets.py
# Validate that secret files are properly hidden from AI
#
# This script automatically reads secret paths from docker-compose.yml and checks if they
# are actually inaccessible (empty, /dev/null mounted, or tmpfs mounted). Auto-detects which
# docker-compose.yml to use based on $SANDBOX_ENV (devcontainer, cli_claude, cli_gemini, cli_ai_sandbox).
# @env: container
# ---
# シークレットファイルがAIから適切に隠蔽されているか検証
# このスクリプトは docker-compose.yml から秘匿パスを自動で読み込み、
# 実際にアクセス不可（空、/dev/nullマウント、tmpfsマウント）であることを確認します

import os
import re
import sys
from pathlib import Path

from _python_common import is_lang_ja, is_quiet, is_summary, is_verbose, load_startup_config, print_error, print_footer, print_title
from _secret_tag import secret_tag_extract_path, secret_tag_prefix_regex

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
# Escaped for safe use inside a Python regex (extract_secret_dirs)
WORKSPACE_RE = re.escape(str(WORKSPACE))


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "🔍 シークレット隠蔽検証",
            "SOURCE": "設定ファイル:",
            "OK": "✅ 正常に隠蔽されています",
            "ERROR": "❌ エラー",
            "FILE_READABLE": "ファイルが読み取り可能です（内容あり）",
            "DIR_NOT_EMPTY": "ディレクトリが空ではありません",
            "EMPTY_OK": "空または存在しない（OK）",
            "ALL_OK": "すべてのシークレットが正常に隠蔽されています",
            "HAS_ERRORS": "エラーがあります - 対応が必要です",
            "NO_SECRETS": "秘匿設定が見つかりませんでした",
            "FILES_SECTION": "📄 ファイル（/dev/null マウント）",
            "DIRS_SECTION": "📁 ディレクトリ（tmpfs マウント）",
            "CHECK_CONFIG": "docker-compose.yml の volumes/tmpfs 設定を確認してください",
        }
    return {
        "TITLE": "🔍 Secret Hiding Validation",
        "SOURCE": "Config file:",
        "OK": "✅ Properly hidden",
        "ERROR": "❌ Error",
        "FILE_READABLE": "File is readable (has content)",
        "DIR_NOT_EMPTY": "Directory is not empty",
        "EMPTY_OK": "Empty or does not exist (OK)",
        "ALL_OK": "All secrets are properly hidden",
        "HAS_ERRORS": "Errors found - action required",
        "NO_SECRETS": "No secret hiding configuration found",
        "FILES_SECTION": "📄 Files (/dev/null mounts)",
        "DIRS_SECTION": "📁 Directories (tmpfs mounts)",
        "CHECK_CONFIG": "Check your docker-compose.yml volumes/tmpfs configuration",
    }


# ─── Extraction / 抽出 ──────────────────────────────────────────

def extract_secret_files(compose_file: Path) -> list:
    """Extract /dev/null volume mounts (secret files).
    Format in docker-compose.yml: - /dev/null:/workspace/path/.env:ro

    /dev/null マウントを抽出（秘匿ファイル）
    """
    results = []
    for line in compose_file.read_text().splitlines():
        if re.match(r"^\s*-\s*/dev/null:", line):
            cleaned = re.sub(r"^\s*-\s*", "", line)
            cleaned = re.sub(r"^/dev/null:", "", cleaned)
            cleaned = re.sub(r":ro$", "", cleaned)
            results.append(cleaned)
    return sorted(set(results))


def extract_secret_dirs(compose_file: Path) -> list:
    """Extract tmpfs mounts for secrets (directories). A tmpfs: entry is
    treated as a secret dir only when tagged with a trailing "# @secret"
    comment (see _secret_tag.py for the shared matching/extraction logic
    used by the Python-migrated secret-sync scripts).
    Format in docker-compose.yml: - /workspace/path/secrets  # @secret

    tmpfs マウントを抽出（秘匿ディレクトリ）。末尾に "# @secret" タグが付いている
    tmpfs: エントリのみを秘匿ディレクトリとみなす（共通のマッチング・抽出ロジックは
    _secret_tag.py を参照）。
    """
    prefix_re = secret_tag_prefix_regex(WORKSPACE_RE)
    in_tmpfs = False
    results = []

    for line in compose_file.read_text().splitlines():
        # Check if we're entering tmpfs section
        # tmpfs セクションに入るかチェック
        if re.match(r"^\s*tmpfs:", line):
            in_tmpfs = True
            continue

        # Check if we're leaving tmpfs section (new top-level key)
        # tmpfs セクションを抜けるかチェック（新しいトップレベルキー）
        if in_tmpfs and re.match(r"^\s*[a-z_]+:", line) and not re.match(r"^\s*-", line):
            in_tmpfs = False
            continue

        # If in tmpfs section, extract $WORKSPACE paths tagged with "# @secret"
        # tmpfs セクション内であれば "# @secret" タグ付きの $WORKSPACE パスを抽出
        if in_tmpfs and re.search(prefix_re, line):
            results.append(secret_tag_extract_path(line))

    return sorted(set(results))


# ─── Validation / 検証 ──────────────────────────────────────────

def validate_file(path: str, verbose: bool, msgs: dict) -> "tuple[bool, str | None]":
    """Validate a file path (should be empty or non-existent).
    Returns (validated, error_message_or_None).

    ファイルパスを検証（空または存在しないべき）。
    """
    if os.path.isfile(path):
        if os.path.getsize(path) > 0:
            # File has content - ERROR
            # ファイルに内容あり - エラー
            if verbose:
                print(f"   {path}")
                print(f"      {msgs['ERROR']}: {msgs['FILE_READABLE']}")
            return False, f"{path}: {msgs['FILE_READABLE']}"
        # File is empty (likely /dev/null mount)
        # ファイルが空（おそらく /dev/null マウント）
        if verbose:
            print(f"   {path}")
            print(f"      {msgs['OK']}")
        return True, None
    # File doesn't exist
    # ファイルが存在しない
    if verbose:
        print(f"   {path}")
        print(f"      {msgs['EMPTY_OK']}")
    return True, None


def validate_dir(path: str, verbose: bool, msgs: dict) -> "tuple[bool, str | None]":
    """Validate a directory path (should be empty or non-existent).
    Returns (validated, error_message_or_None).

    ディレクトリパスを検証（空または存在しないべき）。
    """
    if os.path.isdir(path):
        entries = os.listdir(path)
        if not entries:
            # Directory is empty (likely tmpfs mount)
            # ディレクトリが空（おそらく tmpfs マウント）
            if verbose:
                print(f"   {path}")
                print(f"      {msgs['OK']}")
            return True, None
        # Directory has files - ERROR
        # ディレクトリにファイルあり - エラー
        if verbose:
            print(f"   {path}")
            print(f"      {msgs['ERROR']}: {msgs['DIR_NOT_EMPTY']} ({len(entries)} files)")
        return False, f"{path}: {msgs['DIR_NOT_EMPTY']} ({len(entries)} files)"
    # Directory doesn't exist
    # ディレクトリが存在しない
    if verbose:
        print(f"   {path}")
        print(f"      {msgs['EMPTY_OK']}")
    return True, None


# ─── Main / メイン処理 ──────────────────────────────────────────

def main() -> None:
    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    verbosity = load_startup_config()["verbosity"]

    # Determine which docker-compose.yml to use based on environment
    # 環境に応じて使用する docker-compose.yml を決定
    # cli_sandbox environments: cli_claude, cli_gemini, cli_ai_sandbox
    sandbox_env = os.environ.get("SANDBOX_ENV", "")
    if sandbox_env.startswith("cli_"):
        compose_file = WORKSPACE / "cli_sandbox" / "docker-compose.yml"
    else:
        compose_file = WORKSPACE / ".devcontainer" / "docker-compose.yml"

    # Check if compose file exists
    # compose ファイルの存在確認
    if not compose_file.is_file():
        print_error(f"{msgs['ERROR']}: {compose_file} not found")
        sys.exit(1)

    # Extract secret paths from docker-compose.yml
    # docker-compose.yml から秘匿パスを抽出
    secret_files = extract_secret_files(compose_file)
    secret_dirs = extract_secret_dirs(compose_file)

    verbose = is_verbose(verbosity)

    errors = []
    validated_count = 0

    # Validate secret files
    # 秘匿ファイルを検証
    if secret_files:
        if verbose:
            print(msgs["FILES_SECTION"])
            print()
        for path in secret_files:
            ok, err = validate_file(path, verbose, msgs)
            if ok:
                validated_count += 1
            else:
                errors.append(err)
        if verbose:
            print()

    # Validate secret directories
    # 秘匿ディレクトリを検証
    if secret_dirs:
        if verbose:
            print(msgs["DIRS_SECTION"])
            print()
        for path in secret_dirs:
            ok, err = validate_dir(path, verbose, msgs)
            if ok:
                validated_count += 1
            else:
                errors.append(err)
        if verbose:
            print()

    total_secrets = len(secret_files) + len(secret_dirs)
    exit_code = 1 if errors else 0

    # ============================================================
    # Quiet mode: only show errors / クワイエットモード: エラーのみ表示
    # ============================================================
    if is_quiet(verbosity):
        if errors:
            print(f"❌ {msgs['HAS_ERRORS']}")
            for err in errors:
                print(f"   {err}")
        sys.exit(exit_code)

    # ============================================================
    # Summary mode: show errors + action required / サマリーモード: エラーと対応が必要な内容を表示
    # ============================================================
    if is_summary(verbosity):
        if errors:
            print()
            print(f"❌ {msgs['HAS_ERRORS']} ({len(errors)}/{total_secrets})")
            print()
            for err in errors:
                print(f"   ❌ {err}")
            print()
            print(msgs["CHECK_CONFIG"])
            print()
        elif total_secrets == 0:
            print(f"✓ Secret hiding: {msgs['NO_SECRETS']}")
        else:
            print(f"✓ Secret hiding: {validated_count}/{total_secrets} validated")
        sys.exit(exit_code)

    # ============================================================
    # Verbose mode: full output / 詳細モード: 全出力を表示
    # ============================================================
    print_title(msgs["TITLE"], verbosity)

    print(f"{msgs['SOURCE']} {compose_file}")
    print()

    # No secrets configured
    # 秘匿設定がない場合
    if total_secrets == 0:
        print(msgs["NO_SECRETS"])
        print()

    # Summary (no mid-section separator)
    # 結果サマリー（中間罫線なし）
    if errors:
        print(msgs["HAS_ERRORS"])
        print()
        for err in errors:
            print(f"  ❌ {err}")
        print()
        print(msgs["CHECK_CONFIG"])
    else:
        print(msgs["ALL_OK"])

    print_footer(verbosity)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()

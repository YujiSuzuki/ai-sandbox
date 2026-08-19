#!/usr/bin/env python3
# compare-secret-config.py
# Compare secret hiding configuration between DevContainer and CLI Sandbox
#
# This script checks if both docker-compose.yml files have the same
# secret hiding configuration (volumes with /dev/null and tmpfs mounts)
#
# Container-only: extract_tmpfs_mounts() below only picks up tmpfs entries
# that start with the literal $WORKSPACE path, but docker-compose.yml always
# declares them against the fixed in-container path /workspace/<path>. That
# filter only matches anything when $WORKSPACE is actually /workspace (i.e.
# running inside the container where that path is the live mount root) --
# otherwise the tmpfs half of the comparison silently sees nothing on both
# sides and reports a false "match".
# @env: container
# ---
# DevContainer と CLI Sandbox の秘匿設定を比較
# 両方の docker-compose.yml で秘匿設定（/dev/null volumes と tmpfs マウント）が
# 同じであることを確認します
#
# コンテナ専用: 下記の extract_tmpfs_mounts() は、$WORKSPACE で始まる
# tmpfsエントリのみを抽出するが、docker-compose.yml側は常にコンテナ内の
# 固定パス /workspace/<path> で宣言されている。このフィルタが機能するのは
# $WORKSPACE が実際に /workspace であるとき（＝コンテナ内で、そのパスが
# 実マウントのルートであるとき）のみで、そうでない場合は tmpfs側の比較が
# 両方とも無検出になり「一致」と誤判定される。

import os
import re
import sys
from pathlib import Path

from _python_common import is_lang_ja, is_quiet, is_summary, load_startup_config, print_footer, print_title
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
WORKSPACE_RE = re.escape(str(WORKSPACE))

DEVCONTAINER_COMPOSE = WORKSPACE / ".devcontainer" / "docker-compose.yml"
CLI_SANDBOX_COMPOSE = WORKSPACE / "cli_sandbox" / "docker-compose.yml"

# Short display paths for mismatch messages
# 差異表示用の短いパス
DEVCONTAINER_COMPOSE_SHORT = ".devcontainer/docker-compose.yml"
CLI_SANDBOX_COMPOSE_SHORT = "cli_sandbox/docker-compose.yml"


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "🔍 秘匿設定の整合性チェック",
            "MATCH": "✅ 両環境の秘匿設定は一致しています",
            "MISMATCH": "⚠️  秘匿設定に差異があります",
            "DEVCONTAINER": "DevContainer",
            "CLI_SANDBOX": "CLI Sandbox",
            "VOLUMES": "/dev/null マウント (volumes)",
            "TMPFS": "tmpfs マウント",
            "ONLY_IN": "のみに存在:",
            "HINT": "両方の docker-compose.yml を同期してください:",
            "FILE_NOT_FOUND": "ファイルが見つかりません:",
            "ACTION": "対処方法:",
            "ACTION1": "  手動で docker-compose.yml を編集する（ホストOS側で）",
            "ACTION2": "  または: .sandbox/scripts/sync-compose-secrets.py を実行（この環境内で）",
        }
    return {
        "TITLE": "🔍 Secret Config Consistency Check",
        "MATCH": "✅ Secret hiding config matches in both environments",
        "MISMATCH": "⚠️  Secret hiding config mismatch detected",
        "DEVCONTAINER": "DevContainer",
        "CLI_SANDBOX": "CLI Sandbox",
        "VOLUMES": "/dev/null mounts (volumes)",
        "TMPFS": "tmpfs mounts",
        "ONLY_IN": "only in:",
        "HINT": "Please sync both docker-compose.yml files:",
        "FILE_NOT_FOUND": "File not found:",
        "ACTION": "How to fix:",
        "ACTION1": "  Manually edit docker-compose.yml (on host OS)",
        "ACTION2": "  Or run: .sandbox/scripts/sync-compose-secrets.py (inside this environment)",
    }


# ─── Extraction / 抽出 ──────────────────────────────────────────

def extract_devnull_mounts(compose_file: Path) -> list:
    """Extract /dev/null volume mounts (secret hiding). Format: /dev/null:/path:ro

    /dev/null マウントを抽出（秘匿ファイル）
    """
    results = []
    for line in compose_file.read_text().splitlines():
        if re.match(r"^\s*-\s*/dev/null:", line):
            results.append(re.sub(r"^\s*-\s*", "", line))
    return sorted(results)


def extract_tmpfs_mounts(compose_file: Path) -> list:
    """Extract tmpfs mounts (secret directory hiding). A tmpfs: entry is
    treated as a secret dir only when tagged with a trailing "# @secret"
    comment; see _secret_tag.py for the shared matching regex used by the
    Python-migrated secret-sync scripts.

    tmpfs マウントを抽出（秘匿ディレクトリ）。末尾に "# @secret" タグが付いている
    tmpfs: エントリのみを秘匿ディレクトリとみなす。共通のマッチング正規表現は
    _secret_tag.py を参照（Python移行済みの secret-sync 系スクリプトで共有）。
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


# ─── Main / メイン処理 ──────────────────────────────────────────

def main() -> None:
    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    verbosity = load_startup_config()["verbosity"]

    if not DEVCONTAINER_COMPOSE.is_file():
        print(f"{msgs['FILE_NOT_FOUND']} {DEVCONTAINER_COMPOSE}")
        sys.exit(1)

    if not CLI_SANDBOX_COMPOSE.is_file():
        print(f"{msgs['FILE_NOT_FOUND']} {CLI_SANDBOX_COMPOSE}")
        sys.exit(1)

    devcontainer_volumes = extract_devnull_mounts(DEVCONTAINER_COMPOSE)
    cli_sandbox_volumes = extract_devnull_mounts(CLI_SANDBOX_COMPOSE)
    devcontainer_tmpfs = extract_tmpfs_mounts(DEVCONTAINER_COMPOSE)
    cli_sandbox_tmpfs = extract_tmpfs_mounts(CLI_SANDBOX_COMPOSE)

    volumes_match = devcontainer_volumes == cli_sandbox_volumes
    tmpfs_match = devcontainer_tmpfs == cli_sandbox_tmpfs
    has_mismatch = not volumes_match or not tmpfs_match

    # ============================================================
    # Quiet mode: only show on mismatch / クワイエットモード: 不一致がある場合のみ表示
    # ============================================================
    if is_quiet(verbosity):
        if has_mismatch:
            print(f"⚠️  {msgs['MISMATCH']}")
            if not volumes_match:
                print(f"   - {msgs['VOLUMES']}")
            if not tmpfs_match:
                print(f"   - {msgs['TMPFS']}")
            sys.exit(1)
        sys.exit(0)

    # ============================================================
    # Summary mode: show differences + action required / サマリーモード: 差分と対応が必要な内容を表示
    # ============================================================
    if is_summary(verbosity):
        if has_mismatch:
            print()
            print(msgs["MISMATCH"])
            print()

            if not volumes_match:
                print(f"📁 {msgs['VOLUMES']}")
                _print_diff(devcontainer_volumes, cli_sandbox_volumes, msgs)
                print()

            if not tmpfs_match:
                print(f"📁 {msgs['TMPFS']}")
                _print_diff(devcontainer_tmpfs, cli_sandbox_tmpfs, msgs)
                print()

            print(msgs["ACTION"])
            print(msgs["ACTION1"])
            print(msgs["ACTION2"])
            print()
            sys.exit(1)
        print(f"✓ {msgs['MATCH']}")
        sys.exit(0)

    # ============================================================
    # Verbose mode: full output / 詳細モード: 全出力を表示
    # ============================================================
    print_title(msgs["TITLE"], verbosity)

    print(f"📁 {msgs['VOLUMES']}")
    if volumes_match:
        print("   ✅ Match")
    else:
        print("   ⚠️  Mismatch")
        _print_diff(devcontainer_volumes, cli_sandbox_volumes, msgs, leading_blank=True)
    print()

    print(f"📁 {msgs['TMPFS']}")
    if tmpfs_match:
        print("   ✅ Match")
    else:
        print("   ⚠️  Mismatch")
        _print_diff(devcontainer_tmpfs, cli_sandbox_tmpfs, msgs, leading_blank=True)
    print()

    # Summary (no mid-section separator)
    # 結果サマリー（中間罫線なし）
    if has_mismatch:
        print(msgs["MISMATCH"])
        print()
        print(msgs["HINT"])
        print(f"  📄 {DEVCONTAINER_COMPOSE}")
        print(f"  📄 {CLI_SANDBOX_COMPOSE}")
        print()
        print(msgs["ACTION"])
        print(msgs["ACTION1"])
        print(msgs["ACTION2"])
    else:
        print(msgs["MATCH"])

    print_footer(verbosity)

    sys.exit(1 if has_mismatch else 0)


def _print_diff(devcontainer_list: list, cli_list: list, msgs: dict, leading_blank: bool = False) -> None:
    only_in_devcontainer = only_in_a(devcontainer_list, cli_list)
    only_in_cli = only_in_a(cli_list, devcontainer_list)

    if only_in_devcontainer:
        if leading_blank:
            print()
        print(f"   {msgs['DEVCONTAINER']} {msgs['ONLY_IN']} ({DEVCONTAINER_COMPOSE_SHORT})")
        for line in only_in_devcontainer:
            print(f"      - {line}")

    if only_in_cli:
        if leading_blank:
            print()
        print(f"   {msgs['CLI_SANDBOX']} {msgs['ONLY_IN']} ({CLI_SANDBOX_COMPOSE_SHORT})")
        for line in only_in_cli:
            print(f"      - {line}")


if __name__ == "__main__":
    main()

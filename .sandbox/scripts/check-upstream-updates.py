#!/usr/bin/env python3
# check-upstream-updates.py
# Check for updates to the upstream repository
#
# This script checks GitHub releases API for new versions and notifies the
# user if updates are available.
#
# Intentional deviation from the bash original: fetching goes through
# _python_common.py's fetch_latest_release() (stdlib urllib.request) instead
# of shelling out to curl -- see that function's docstring for the
# connect/max-time timeout approximation this implies.
# ---
# アップストリームリポジトリの更新をチェック
# このスクリプトはGitHub releases APIをチェックし、
# 更新があればユーザーに通知します。
#
# bash版からの意図的な差分: 取得は _python_common.py の
# fetch_latest_release()（標準ライブラリのurllib.request）経由で行い、
# curlは呼ばない -- タイムアウトの近似についてはその関数のdocstringを参照。

import os
import sys
from pathlib import Path

from _python_common import (
    debug_log,
    fetch_latest_release,
    get_last_notified_version,
    is_first_run,
    is_quiet,
    is_summary,
    load_startup_config,
    parse_simple_conf,
    print_footer,
    print_title,
    should_check,
    update_state,
)


def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "📦 更新チェック",
            "UPDATE_AVAILABLE": "更新があります",
            "CURRENT": "現在のバージョン",
            "LATEST": "最新バージョン",
            "RELEASE_NOTES": "リリースノート",
            "HOW_TO_UPDATE": "更新方法",
            "HOW_TO_UPDATE_1": "1. リリースノートで変更内容を確認",
            "HOW_TO_UPDATE_2": "2. 必要な変更を手動で適用",
            "AI_HINT": "💡 AIに更新を依頼できます",
            "AI_HINT_EXAMPLE": "例: 「最新バージョンに更新して」",
        }
    return {
        "TITLE": "📦 Update Check",
        "UPDATE_AVAILABLE": "Update available",
        "CURRENT": "Current version",
        "LATEST": "Latest version",
        "RELEASE_NOTES": "Release notes",
        "HOW_TO_UPDATE": "How to update",
        "HOW_TO_UPDATE_1": "1. Check release notes for changes",
        "HOW_TO_UPDATE_2": "2. Manually apply relevant updates",
        "AI_HINT": "💡 You can ask your AI assistant to help",
        "AI_HINT_EXAMPLE": 'Example: "Please update to the latest version"',
    }


def show_update_notification(previous: str, latest: str, url: str, verbosity: str, msgs: dict) -> None:
    version_display = f"{previous} → {latest}" if previous else latest

    if is_quiet(verbosity):
        print(f"📦 {msgs['UPDATE_AVAILABLE']}: {version_display}")
        return

    if is_summary(verbosity):
        print_title(msgs["TITLE"], verbosity)
        if previous:
            print(f"  {msgs['CURRENT']}:  {previous}")
        print(f"  {msgs['LATEST']}:   {latest}")
        print(f"  {msgs['RELEASE_NOTES']}:")
        print(f"    {url}")
        print()
        print(f"  {msgs['AI_HINT']}")
        print(f"    {msgs['AI_HINT_EXAMPLE']}")
        print_footer(verbosity)
        return

    # Verbose
    print_title(msgs["TITLE"], verbosity)
    if previous:
        print(f"  {msgs['CURRENT']}:  {previous}")
    print(f"  {msgs['LATEST']}:   {latest}")
    print()
    print(f"  {msgs['HOW_TO_UPDATE']}:")
    print(f"    {msgs['HOW_TO_UPDATE_1']}")
    print(f"    {msgs['HOW_TO_UPDATE_2']}")
    print()
    print(f"  {msgs['AI_HINT']}")
    print(f"    {msgs['AI_HINT_EXAMPLE']}")
    print()
    print(f"  {msgs['RELEASE_NOTES']}:")
    print(f"    {url}")
    print_footer(verbosity)


def main() -> None:
    debug = os.environ.get("DEBUG_UPDATE_CHECK", "0") == "1" or "--debug" in sys.argv[1:]

    workspace = Path(os.environ.get("WORKSPACE", "/workspace"))
    config_path = workspace / ".sandbox" / "config" / "template-source.conf"

    config = parse_simple_conf(config_path)
    if not config:
        debug_log(f"Config not found: {config_path} → skip", debug)
        return

    template_repo = config.get("TEMPLATE_REPO", "")
    check_updates = config.get("CHECK_UPDATES", "true")
    check_channel = config.get("CHECK_CHANNEL", "all")
    check_interval_hours = config.get("CHECK_INTERVAL_HOURS", "24")
    debug_log(
        f"Config loaded: REPO={template_repo}, CHANNEL={check_channel}, "
        f"UPDATES={check_updates}, INTERVAL={check_interval_hours}h",
        debug,
    )

    lang_ja = os.environ.get("LANG", "").startswith("ja_JP") or os.environ.get("LC_ALL", "").startswith("ja_JP")
    msgs = get_messages(lang_ja)

    startup_config = load_startup_config()
    verbosity = startup_config["verbosity"]

    if check_updates != "true":
        debug_log(f"CHECK_UPDATES={check_updates} → disabled, exit", debug)
        return

    if not template_repo:
        debug_log("TEMPLATE_REPO is empty → exit", debug)
        return

    state_file = Path(os.environ.get("STATE_FILE", str(workspace / ".sandbox" / ".state" / "update-check")))

    if not should_check(state_file, check_interval_hours):
        return

    mock_latest = os.environ.get("MOCK_LATEST_VERSION")
    if mock_latest:
        latest_version = mock_latest
        debug_log(f"MOCK_LATEST_VERSION set → skip API call, use '{latest_version}'", debug)
    else:
        latest_version = fetch_latest_release(template_repo, check_channel)
        if latest_version is None:
            debug_log("Fetch failed → exit", debug)
            return

    if not latest_version:
        debug_log("No release found → exit", debug)
        update_state(state_file, "")
        return

    if is_first_run(state_file):
        debug_log(f"First run → record {latest_version}, no notification", debug)
        update_state(state_file, latest_version)
        return

    last_notified = get_last_notified_version(state_file)
    debug_log(f"Compare: last_notified={last_notified}, latest={latest_version}", debug)

    if last_notified == latest_version:
        debug_log("Same version → no notification", debug)
        update_state(state_file, latest_version)
        return

    release_url = f"https://github.com/{template_repo}/releases"
    debug_log("New version → notification", debug)
    show_update_notification(last_notified, latest_version, release_url, verbosity, msgs)

    update_state(state_file, latest_version)


if __name__ == "__main__":
    main()

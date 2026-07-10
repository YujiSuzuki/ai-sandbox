#!/bin/bash
# check-upstream-updates.sh
# Check for updates to the upstream repository
#
# This script checks GitHub releases API for new versions
# and notifies the user if updates are available.
# ---
# アップストリームリポジトリの更新をチェック
# このスクリプトはGitHub releases APIをチェックし、
# 更新があればユーザーに通知します。

set -e

WORKSPACE="${WORKSPACE:-/workspace}"

# Source common startup functions
# 共通起動関数を読み込み
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_startup_common.sh"

# Configuration file path
# 設定ファイルのパス
TEMPLATE_CONFIG="${WORKSPACE}/.sandbox/config/template-source.conf"

# State file for check interval and last notified version
# チェック間隔と前回通知バージョン用の状態ファイル
# Format: <unix_timestamp>:<version>
# 形式: <UNIXタイムスタンプ>:<バージョン>
STATE_FILE="${STATE_FILE:-${WORKSPACE}/.sandbox/.state/update-check}"

# Debug mode: --debug flag or DEBUG_UPDATE_CHECK=1 environment variable
# デバッグモード: --debug フラグ または DEBUG_UPDATE_CHECK=1 環境変数
DEBUG_MODE="${DEBUG_UPDATE_CHECK:-0}"

# Parse --debug flag
# --debug フラグを解析
for arg in "$@"; do
    if [ "$arg" = "--debug" ]; then
        DEBUG_MODE=1
        break
    fi
done

# Output debug message to stderr
# デバッグメッセージを stderr に出力
debug_log() {
    if [ "$DEBUG_MODE" = "1" ]; then
        echo "[debug] $*" >&2
    fi
}

# Load template configuration
# テンプレート設定を読み込み
# Returns: 0 if config loaded, 1 if no config file
load_template_config() {
    if [ ! -f "$TEMPLATE_CONFIG" ]; then
        debug_log "Config not found: $TEMPLATE_CONFIG → skip"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$TEMPLATE_CONFIG"
    debug_log "Config loaded: REPO=$TEMPLATE_REPO, CHANNEL=${CHECK_CHANNEL:-all}, UPDATES=$CHECK_UPDATES, INTERVAL=${CHECK_INTERVAL_HOURS}h"
    return 0
}

# Language detection based on locale
# ロケールに基づく言語検出
setup_messages() {
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        MSG_TITLE="📦 更新チェック"
        MSG_UPDATE_AVAILABLE="更新があります"
        MSG_CURRENT="現在のバージョン"
        MSG_LATEST="最新バージョン"
        MSG_RELEASE_NOTES="リリースノート"
        MSG_HOW_TO_UPDATE="更新方法"
        MSG_HOW_TO_UPDATE_1="1. リリースノートで変更内容を確認"
        MSG_HOW_TO_UPDATE_2="2. 必要な変更を手動で適用"
        MSG_AI_HINT="💡 AIに更新を依頼できます"
        MSG_AI_HINT_EXAMPLE="例: 「最新バージョンに更新して」"
    else
        MSG_TITLE="📦 Update Check"
        MSG_UPDATE_AVAILABLE="Update available"
        MSG_CURRENT="Current version"
        MSG_LATEST="Latest version"
        MSG_RELEASE_NOTES="Release notes"
        MSG_HOW_TO_UPDATE="How to update"
        MSG_HOW_TO_UPDATE_1="1. Check release notes for changes"
        MSG_HOW_TO_UPDATE_2="2. Manually apply relevant updates"
        MSG_AI_HINT="💡 You can ask your AI assistant to help"
        MSG_AI_HINT_EXAMPLE="Example: \"Please update to the latest version\""
    fi
}

# Note: read_state_timestamp, get_last_notified_version, is_first_run,
# should_check, update_state, build_api_url, extract_tag_from_json, and
# fetch_latest_release are defined in _startup_common.sh (shared with
# check-sandbox-mcp-updates.sh). They read $STATE_FILE / $CHECK_CHANNEL,
# which this script sets below via config / env.
# 注: read_state_timestamp 等は _startup_common.sh で定義（check-sandbox-mcp-updates.sh
# と共有）。$STATE_FILE / $CHECK_CHANNEL を参照する。

# Main
# メイン処理
main() {
    # Load config, exit if not found
    if ! load_template_config; then
        return 0
    fi
    setup_messages

    # Check if updates are enabled
    # 更新チェックが有効か確認
    if [ "${CHECK_UPDATES:-true}" != "true" ]; then
        debug_log "CHECK_UPDATES=${CHECK_UPDATES} → disabled, exit"
        exit 0
    fi

    # Check if template repo is configured
    # リポジトリが設定されているか確認
    if [ -z "${TEMPLATE_REPO:-}" ]; then
        debug_log "TEMPLATE_REPO is empty → exit"
        exit 0
    fi

    # Check interval
    # 間隔チェック
    if ! should_check; then
        exit 0
    fi

    # Fetch latest release
    # 最新リリースを取得
    local latest_version
    if [ -n "${MOCK_LATEST_VERSION:-}" ]; then
        latest_version="$MOCK_LATEST_VERSION"
        debug_log "MOCK_LATEST_VERSION set → skip API call, use '$latest_version'"
    else
        latest_version=$(fetch_latest_release "$TEMPLATE_REPO") || {
            debug_log "Fetch failed → exit"
            exit 0
        }
    fi

    # No release found
    if [ -z "$latest_version" ]; then
        debug_log "No release found → exit"
        update_state ""
        exit 0
    fi

    # First run: record version without notification
    # 初回実行: 通知せずバージョンを記録
    if is_first_run; then
        debug_log "First run → record $latest_version, no notification"
        update_state "$latest_version"
        exit 0
    fi

    # Compare with last notified version
    # 前回通知バージョンと比較
    local last_notified
    last_notified=$(get_last_notified_version)
    debug_log "Compare: last_notified=$last_notified, latest=$latest_version"

    if [ "$last_notified" = "$latest_version" ]; then
        debug_log "Same version → no notification"
        update_state "$latest_version"
        exit 0
    fi

    # New version available - show notification
    # 新バージョンあり - 通知表示
    local release_url="https://github.com/${TEMPLATE_REPO}/releases"
    debug_log "New version → notification"
    show_update_notification "$last_notified" "$latest_version" "$release_url"

    update_state "$latest_version"
}

# Show update notification based on verbosity
# 詳細度に応じて更新通知を表示
show_update_notification() {
    local previous="$1"
    local latest="$2"
    local url="$3"

    # Build version display
    # バージョン表示を構築
    local version_display
    if [ -n "$previous" ]; then
        version_display="$previous → $latest"
    else
        version_display="$latest"
    fi

    # ============================================================
    # Quiet mode: minimal output
    # ============================================================
    if is_quiet; then
        echo "📦 $MSG_UPDATE_AVAILABLE: $version_display"
        return
    fi

    # ============================================================
    # Summary mode: summary with URL
    # ============================================================
    if is_summary; then
        print_title "$MSG_TITLE"

        if [ -n "$previous" ]; then
            echo "  $MSG_CURRENT:  $previous"
        fi
        echo "  $MSG_LATEST:   $latest"
        echo "  $MSG_RELEASE_NOTES:"
        echo "    $url"
        echo ""
        echo "  $MSG_AI_HINT"
        echo "    $MSG_AI_HINT_EXAMPLE"

        print_footer
        return
    fi

    # ============================================================
    # Verbose mode: full details
    # ============================================================
    print_title "$MSG_TITLE"

    if [ -n "$previous" ]; then
        echo "  $MSG_CURRENT:  $previous"
    fi
    echo "  $MSG_LATEST:   $latest"
    echo ""
    echo "  $MSG_HOW_TO_UPDATE:"
    echo "    $MSG_HOW_TO_UPDATE_1"
    echo "    $MSG_HOW_TO_UPDATE_2"
    echo ""
    echo "  $MSG_AI_HINT"
    echo "    $MSG_AI_HINT_EXAMPLE"
    echo ""
    echo "  $MSG_RELEASE_NOTES:"
    echo "    $url"

    print_footer
}

# Only run main if script is executed directly (not sourced)
# スクリプトが直接実行された場合のみ main を実行（source された場合は実行しない）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

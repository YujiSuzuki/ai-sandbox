#!/bin/bash
# check-sandbox-mcp-updates.sh
# Check for updates to the installed sandbox-mcp binary
#
# Unlike check-upstream-updates.sh (which only knows a new template tag
# exists), this script compares the actually installed `sandbox-mcp version`
# against the latest GitHub release tag, since we have real ground truth here.
# ---
# インストール済み sandbox-mcp バイナリの更新をチェック
# check-upstream-updates.sh（新しいタグの存在しか分からない）と異なり、
# 実際にインストールされている `sandbox-mcp version` と GitHub の最新タグを
# 直接比較する（実際のインストール済みバージョンという確かな情報源があるため）。

set -e

WORKSPACE="${WORKSPACE:-/workspace}"

# Source common startup functions (print_*, is_quiet/is_summary/is_verbose,
# and the update-check helpers: should_check, update_state, fetch_latest_release, ...)
# 共通起動関数を読み込み（print_* 系、詳細度判定、update_state 等の更新チェックヘルパー）
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_startup_common.sh"

# This is a fixed infra dependency of the template, not a swappable source,
# so it's a constant rather than a config file value (consistent with the
# already-hardcoded repo references in startup.sh).
# テンプレートに同梱される固定の依存パッケージであり、差し替え可能な設定値ではないため
# 定数として扱う（startup.sh に既にハードコードされているリポジトリ参照と同様）。
SANDBOX_MCP_REPO="YujiSuzuki/sandbox-mcp"

CHECK_CHANNEL="${CHECK_CHANNEL:-all}"
CHECK_UPDATES="${CHECK_UPDATES:-true}"
CHECK_INTERVAL_HOURS="${CHECK_INTERVAL_HOURS:-24}"

# State file for check interval (installed-version comparison needs no
# "last notified version" dedup -- unlike the template check, this script
# re-notifies every time the installed version is behind, since there's a
# real installed-version ground truth to compare against)
# 間隔スロットリング用の状態ファイル
STATE_FILE="${STATE_FILE:-${WORKSPACE}/.sandbox/.state/update-check-sandbox-mcp}"

# Auto-update: off by default (--auto-update flag or AUTO_UPDATE_SANDBOX_MCP=true env var).
# When enabled and an update is available, installs it the same way startup.sh installs
# sandbox-mcp fresh: go install if Go is available, otherwise a prebuilt binary download.
# 自動更新: デフォルト無効（--auto-update フラグ または AUTO_UPDATE_SANDBOX_MCP=true 環境変数）。
# 有効時、更新があれば startup.sh の新規インストールと同じ方式（Go があれば go install、
# なければビルド済みバイナリのダウンロード）で更新する。
AUTO_UPDATE="${AUTO_UPDATE_SANDBOX_MCP:-false}"

# Debug mode: --debug flag or DEBUG_UPDATE_CHECK=1 environment variable
# デバッグモード: --debug フラグ または DEBUG_UPDATE_CHECK=1 環境変数
DEBUG_MODE="${DEBUG_UPDATE_CHECK:-0}"

for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG_MODE=1 ;;
        --auto-update) AUTO_UPDATE="true" ;;
    esac
done

debug_log() {
    if [ "$DEBUG_MODE" = "1" ]; then
        echo "[debug] $*" >&2
    fi
}

# Language detection based on locale
# ロケールに基づく言語検出
setup_messages() {
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        MSG_TITLE="📦 sandbox-mcp 更新チェック"
        MSG_UPDATE_AVAILABLE="更新があります"
        MSG_CURRENT="現在のバージョン"
        MSG_LATEST="最新バージョン"
        MSG_HOW_TO_UPDATE="更新方法"
        MSG_HOW_TO_UPDATE_CMD=".sandbox/scripts/check-sandbox-mcp-updates.sh --auto-update"
        MSG_AUTO_UPDATING="  📥 自動更新中..."
        MSG_AUTO_UPDATE_GO="  📥 go install で更新中..."
        MSG_AUTO_UPDATE_OK="  ✅ sandbox-mcp を更新しました:"
        MSG_AUTO_UPDATE_FAILED="  ⚠️  自動更新に失敗しました。手動で更新してください: go install github.com/YujiSuzuki/sandbox-mcp@latest"
        MSG_NO_GO="  ⚠️  Go が見つかりません。GitHub Releases からビルド済みバイナリを試します"
        MSG_DOWNLOADING="  📥 sandbox-mcp のビルド済みバイナリをダウンロード中..."
        MSG_DOWNLOAD_OK="  ✅ sandbox-mcp をインストールしました:"
        MSG_DOWNLOAD_FAILED="  ⚠️  ダウンロードに失敗しました。手動でインストールしてください: go install github.com/YujiSuzuki/sandbox-mcp@latest"
    else
        MSG_TITLE="📦 sandbox-mcp Update Check"
        MSG_UPDATE_AVAILABLE="Update available"
        MSG_CURRENT="Current version"
        MSG_LATEST="Latest version"
        MSG_HOW_TO_UPDATE="How to update"
        MSG_HOW_TO_UPDATE_CMD=".sandbox/scripts/check-sandbox-mcp-updates.sh --auto-update"
        MSG_AUTO_UPDATING="  📥 Auto-updating..."
        MSG_AUTO_UPDATE_GO="  📥 Updating via go install..."
        MSG_AUTO_UPDATE_OK="  ✅ sandbox-mcp updated to:"
        MSG_AUTO_UPDATE_FAILED="  ⚠️  Auto-update failed. Update manually: go install github.com/YujiSuzuki/sandbox-mcp@latest"
        MSG_NO_GO="  ⚠️  Go not found, trying prebuilt binary from GitHub Releases instead"
        MSG_DOWNLOADING="  📥 Downloading sandbox-mcp prebuilt binary..."
        MSG_DOWNLOAD_OK="  ✅ sandbox-mcp installed to:"
        MSG_DOWNLOAD_FAILED="  ⚠️  Download failed. Install manually: go install github.com/YujiSuzuki/sandbox-mcp@latest"
    fi
}

# Update sandbox-mcp the same way startup.sh installs it fresh: go install if
# Go is available, otherwise a prebuilt binary download (install_sandbox_mcp_binary,
# shared via _startup_common.sh). Success is judged by the install command's own
# exit status, not by comparing the resulting version to $latest: a plain
# `go install pkg@latest` has no -ldflags, so the binary keeps its source default
# version ("dev") and would never match a real release tag even on success.
# startup.sh の新規インストールと同じ方式で更新する: Go があれば go install、
# なければビルド済みバイナリのダウンロード（_startup_common.sh 共有の
# install_sandbox_mcp_binary）。成功判定はインストールコマンド自体の終了コードで行う
# （バージョン文字列の一致では判定しない）: 素の `go install pkg@latest` には
# -ldflags が付かないため、バイナリはソース側のデフォルト値（"dev"）のままとなり、
# 更新に成功していても実際のリリースタグとは一致しないため。
auto_update_sandbox_mcp() {
    echo "$MSG_AUTO_UPDATING"
    local install_ok=false
    if command -v go >/dev/null 2>&1; then
        echo "$MSG_AUTO_UPDATE_GO"
        if go install github.com/YujiSuzuki/sandbox-mcp@latest; then
            install_ok=true
        fi
    else
        echo "$MSG_NO_GO"
        if install_sandbox_mcp_binary; then
            install_ok=true
        fi
    fi

    if [ "$install_ok" = true ]; then
        # Clear bash's cached PATH lookup in case `sandbox-mcp` was already
        # resolved earlier in this process at a different location.
        # このプロセス内で `sandbox-mcp` が別の場所で既に解決済みの場合に備えて
        # bash の PATH 解決キャッシュをクリアする。
        hash -r 2>/dev/null || true
        echo "$MSG_AUTO_UPDATE_OK $(get_installed_version)"
        return 0
    fi

    echo "$MSG_AUTO_UPDATE_FAILED"
    return 1
}

# Get the installed sandbox-mcp version via its `version` subcommand
# `version` サブコマンドからインストール済み sandbox-mcp のバージョンを取得
get_installed_version() {
    if [ -n "${MOCK_INSTALLED_VERSION:-}" ]; then
        echo "$MOCK_INSTALLED_VERSION"
        return 0
    fi
    sandbox-mcp version 2>/dev/null | sed 's/^sandbox-mcp //'
}

# Show update notification based on verbosity
# 詳細度に応じて更新通知を表示
show_update_notification() {
    local current="$1"
    local latest="$2"
    local version_display="${current} → ${latest}"

    if is_quiet; then
        echo "📦 $MSG_UPDATE_AVAILABLE: $version_display"
        return
    fi

    if is_summary; then
        print_title "$MSG_TITLE"
        echo "  $MSG_CURRENT:  $current"
        echo "  $MSG_LATEST:   $latest"
        print_footer
        return
    fi

    # Verbose
    print_title "$MSG_TITLE"
    echo "  $MSG_CURRENT:  $current"
    echo "  $MSG_LATEST:   $latest"
    echo ""
    echo "  $MSG_HOW_TO_UPDATE:"
    echo "    $MSG_HOW_TO_UPDATE_CMD"
    print_footer
}

main() {
    if [ "$CHECK_UPDATES" != "true" ]; then
        debug_log "CHECK_UPDATES=${CHECK_UPDATES} → disabled, exit"
        exit 0
    fi

    if ! command -v sandbox-mcp >/dev/null 2>&1 && [ -z "${MOCK_INSTALLED_VERSION:-}" ]; then
        debug_log "sandbox-mcp not on PATH → skip"
        exit 0
    fi

    local installed_version
    installed_version=$(get_installed_version)
    if [ -z "$installed_version" ]; then
        debug_log "Could not determine installed version → skip"
        exit 0
    fi

    # An explicit --auto-update / AUTO_UPDATE_SANDBOX_MCP=true request bypasses the
    # interval throttle: should_check exists to rate-limit the passive check that
    # startup.sh runs on every shell start, not a manual update the user just asked for.
    # 明示的な --auto-update / AUTO_UPDATE_SANDBOX_MCP=true はインターバルスロットリングを
    # 無視する: should_check は startup.sh が毎回実行する受動的チェックを間引くためのもので、
    # ユーザーが今まさに要求した手動更新には適用すべきでない。
    if [ "$AUTO_UPDATE" != "true" ] && ! should_check; then
        debug_log "Interval not elapsed → skip"
        exit 0
    fi

    local latest_version
    if [ -n "${MOCK_LATEST_VERSION:-}" ]; then
        latest_version="$MOCK_LATEST_VERSION"
        debug_log "MOCK_LATEST_VERSION set → skip API call, use '$latest_version'"
    elif [ -n "${MOCK_FORCE_FETCH_FAILURE:-}" ]; then
        debug_log "MOCK_FORCE_FETCH_FAILURE set → simulating fetch failure"
        exit 0
    else
        latest_version=$(fetch_latest_release "$SANDBOX_MCP_REPO") || {
            debug_log "Fetch failed → exit"
            exit 0
        }
    fi

    if [ -z "$latest_version" ]; then
        debug_log "No release found → exit"
        update_state ""
        exit 0
    fi

    setup_messages

    if [ "$installed_version" = "$latest_version" ]; then
        debug_log "Same version ($installed_version) → no notification"
        update_state "$latest_version"
        exit 0
    fi

    debug_log "Installed ($installed_version) != latest ($latest_version) → notify"
    show_update_notification "$installed_version" "$latest_version"

    if [ "$AUTO_UPDATE" = "true" ]; then
        debug_log "AUTO_UPDATE_SANDBOX_MCP → attempting update"
        auto_update_sandbox_mcp || true
    fi

    update_state "$latest_version"
}

# Only run main if script is executed directly (not sourced)
# スクリプトが直接実行された場合のみ main を実行（source された場合は実行しない）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

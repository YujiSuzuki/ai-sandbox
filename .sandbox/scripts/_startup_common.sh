#!/bin/bash
# _startup_common.sh
# Common functions for startup scripts with verbosity support
#
# Usage: source this file at the beginning of startup scripts
#
#   source "${WORKSPACE:-/workspace}/.sandbox/scripts/_startup_common.sh"
# ---
# 詳細度サポート付き起動スクリプト用共通関数
# 使用法: 起動スクリプトの冒頭でこのファイルを source する

# Configuration paths
# 設定パス
WORKSPACE="${WORKSPACE:-/workspace}"
STARTUP_CONFIG="${WORKSPACE}/.sandbox/config/startup.conf"
SYNC_IGNORE_FILE="${WORKSPACE}/.sandbox/config/sync-ignore"

# Load configuration file
# 設定ファイルの読み込み
load_startup_config() {
    # Save environment variable values before sourcing config
    # 設定ファイル読み込み前に環境変数の値を保存
    local env_verbosity="${STARTUP_VERBOSITY:-}"
    local env_readme_url="${SANDBOX_README_URL:-}"
    local env_readme_url_ja="${SANDBOX_README_URL_JA:-}"
    local env_backup_keep="${BACKUP_KEEP_COUNT:-}"

    # Load config file if exists
    # 設定ファイルが存在すれば読み込み
    if [ -f "$STARTUP_CONFIG" ]; then
        # shellcheck source=/dev/null
        source "$STARTUP_CONFIG"
    fi

    # Environment variables take precedence over config file
    # 環境変数は設定ファイルより優先
    README_URL="${env_readme_url:-${README_URL:-README.md}}"
    README_URL_JA="${env_readme_url_ja:-${README_URL_JA:-README.ja.md}}"
    STARTUP_VERBOSITY="${env_verbosity:-${STARTUP_VERBOSITY:-verbose}}"
    BACKUP_KEEP_COUNT="${env_backup_keep:-${BACKUP_KEEP_COUNT:-0}}"

    export README_URL README_URL_JA STARTUP_VERBOSITY BACKUP_KEEP_COUNT
}

# ============================================================
# README URL Functions / README URL 関数
# ============================================================

# Get README URL based on locale
# ロケールに応じた README URL を取得
get_readme_url() {
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        echo "${README_URL_JA:-README.ja.md}"
    else
        echo "${README_URL:-README.md}"
    fi
}

# Get "See README for details" message
# 「詳細はREADMEを参照」メッセージを取得
get_readme_reference_message() {
    local url
    url=$(get_readme_url)
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        echo "詳細は ${url} を参照してください。"
    else
        echo "See ${url} for details."
    fi
}

# ============================================================
# Verbosity Helper Functions / 詳細度ヘルパー関数
# ============================================================

# Check verbosity level
# 詳細度レベルをチェック
is_quiet() { [[ "$STARTUP_VERBOSITY" == "quiet" ]]; }
is_verbose() { [[ "$STARTUP_VERBOSITY" == "verbose" ]]; }
is_summary() { [[ "$STARTUP_VERBOSITY" == "summary" ]]; }

# Print script title (thick separator)
# スクリプトタイトルを出力（太線セパレータ）
print_title() {
    is_quiet && return
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    is_verbose && echo "" || true
}

# Print script footer (thick separator)
# スクリプトフッターを出力（太線セパレータ）
print_footer() {
    is_quiet && return
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Print summary line (for summary mode)
# サマリー行を出力（summary モード用）
# Usage: print_summary "emoji" "message" "OK|WARN|ERR"
print_summary() {
    local emoji="$1" msg="$2" result="$3"
    case "$result" in
        OK)
            is_quiet || echo "${emoji} ${msg}"
            ;;
        WARN)
            echo "⚠️  ${msg}"
            ;;
        ERR)
            echo "❌ ${msg}"
            ;;
    esac
}

# Print detail (verbose mode only)
# 詳細を出力（verbose モードのみ）
print_detail() {
    is_verbose && echo "$1" || true
}

# Print default (not in quiet mode)
# デフォルト出力（quiet モード以外）
print_default() {
    is_quiet || echo "$1"
    true  # Always return success for set -e compatibility
}

# Print always (warning/error)
# 常に出力（警告/エラー）
print_warning() {
    echo "⚠️  $1"
}

print_error() {
    echo "❌ $1" >&2
}

# ============================================================
# Sync-Ignore Functions / Sync-Ignore 関数
# ============================================================

# Load sync-ignore patterns
# sync-ignore パターンを読み込み
# Returns patterns one per line, comments and empty lines excluded
# パターンを1行ずつ返す（コメントと空行を除外）
load_sync_ignore_patterns() {
    [ -f "$SYNC_IGNORE_FILE" ] || return 0
    grep -v '^#' "$SYNC_IGNORE_FILE" | grep -v '^[[:space:]]*$' || true
}

# Check if a file matches any sync-ignore pattern
# ファイルが sync-ignore パターンにマッチするかチェック
# Usage: matches_sync_ignore "/workspace/path/to/file"
# Returns: 0 if matches (should ignore), 1 if not
matches_sync_ignore() {
    local file_path="$1"
    local rel_path="${file_path#$WORKSPACE/}"
    local filename
    filename=$(basename "$file_path")
    local pattern

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue

        # Handle ** patterns (recursive matching)
        # ** パターンを処理（再帰マッチング）
        if [[ "$pattern" == "**/"* ]]; then
            # **/*.example -> matches any file ending with .example
            # **/*.sample -> matches any file ending with .sample
            local suffix="${pattern#\*\*/}"

            # If suffix contains *, use glob matching on filename
            # suffix に * が含まれる場合、ファイル名に対してグロブマッチング
            if [[ "$suffix" == "*"* ]]; then
                # Extract the extension part (e.g., ".example" from "*.example")
                local ext="${suffix#\*}"
                if [[ "$filename" == *"$ext" ]]; then
                    return 0
                fi
            elif [[ "$rel_path" == *"$suffix" ]]; then
                return 0
            fi
        elif [[ "$pattern" == *"/**" ]]; then
            # path/** -> matches anything under path/
            local prefix="${pattern%/\*\*}"
            if [[ "$rel_path" == "$prefix/"* ]]; then
                return 0
            fi
        elif [[ "$pattern" == *"*"* ]]; then
            # Simple wildcard matching on the full path
            # パス全体に対する単純なワイルドカードマッチング
            # shellcheck disable=SC2053
            if [[ "$rel_path" == $pattern ]]; then
                return 0
            fi
        else
            # Exact match
            # 完全一致
            if [[ "$rel_path" == "$pattern" ]]; then
                return 0
            fi
        fi
    done < <(load_sync_ignore_patterns)

    return 1
}

# ============================================================
# Backup Utility Functions / バックアップユーティリティ関数
# ============================================================

# Backup directory
# バックアップ保存先ディレクトリ
BACKUP_DIR="${WORKSPACE}/.sandbox/backups"

# Create a backup of a file in .sandbox/backups/
# .sandbox/backups/ にファイルのバックアップを作成
#
# Usage: backup_file "/path/to/file" "label"
# Example: backup_file "$COMPOSE_FILE" "devcontainer"
#   -> .sandbox/backups/devcontainer.docker-compose.yml.20260130123456
#
# Returns: backup file path via stdout
backup_file() {
    local file="$1"
    local label="${2:-}"
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)

    mkdir -p "$BACKUP_DIR"

    local file_basename
    file_basename=$(basename "$file")
    local backup_name
    if [ -n "$label" ]; then
        backup_name="${label}.${file_basename}.${timestamp}"
    else
        backup_name="${file_basename}.${timestamp}"
    fi

    local backup_path="${BACKUP_DIR}/${backup_name}"
    cp "$file" "$backup_path"
    echo "$backup_path"
}

# Clean up old backups, keeping only the most recent N
# 古いバックアップを削除し、直近 N 件のみ保持
#
# Usage: cleanup_backups "label.docker-compose.yml.*" [count]
#   count defaults to BACKUP_KEEP_COUNT (0 = unlimited, no cleanup)
cleanup_backups() {
    local pattern="$1"
    local keep="${2:-$BACKUP_KEEP_COUNT}"

    # 0 or non-numeric means unlimited
    # 0 または数値以外は無制限
    if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -le 0 ]; then
        return 0
    fi
    [ ! -d "$BACKUP_DIR" ] && return 0

    # List matching files sorted by modification time (newest first)
    # 更新日時の降順でマッチするファイルを一覧
    local count=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        count=$((count + 1))
        if [ "$count" -gt "$keep" ]; then
            rm -f "$f"
        fi
    done < <(ls -1t "${BACKUP_DIR}"/${pattern} 2>/dev/null)
}

# ============================================================
# Update Check Helpers / 更新チェックヘルパー
# ============================================================
# Shared by check-upstream-updates.sh and check-sandbox-mcp-updates.sh.
# Callers set $STATE_FILE and $CHECK_CHANNEL before invoking these.
# check-upstream-updates.sh と check-sandbox-mcp-updates.sh で共有。
# 呼び出し側は事前に $STATE_FILE と $CHECK_CHANNEL を設定すること。

# Read timestamp from state file
# 状態ファイルからタイムスタンプを読み取り
read_state_timestamp() {
    if [ -f "$STATE_FILE" ]; then
        cut -d: -f1 "$STATE_FILE" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Read last notified version from state file
# 状態ファイルから前回通知バージョンを読み取り
get_last_notified_version() {
    if [ -f "$STATE_FILE" ]; then
        cut -d: -f2- "$STATE_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Check if this is the first run (no state file)
# 初回実行かどうか（状態ファイルがない）
is_first_run() {
    [ ! -f "$STATE_FILE" ]
}

# Check if enough time has passed since last check
# 前回のチェックから十分な時間が経過したか確認
should_check() {
    local interval_hours="${CHECK_INTERVAL_HOURS:-24}"

    # Validate: must be a non-negative integer, fallback to 24 if invalid
    # バリデーション: 非負整数でなければ24にフォールバック
    if ! [[ "$interval_hours" =~ ^[0-9]+$ ]]; then
        interval_hours=24
    fi

    # 0 means check every time
    # 0 は毎回チェック
    if [ "$interval_hours" -eq 0 ]; then
        debug_log "Interval: 0 (always check)"
        return 0
    fi

    local interval_seconds=$((interval_hours * 3600))
    local last_check
    last_check=$(read_state_timestamp)

    if [ "$last_check" != "0" ]; then
        local now
        now=$(date +%s)
        local elapsed=$((now - last_check))

        if [ $elapsed -lt $interval_seconds ]; then
            debug_log "Interval: ${elapsed}s elapsed < ${interval_seconds}s required → skip"
            return 1
        fi
        debug_log "Interval: ${elapsed}s elapsed >= ${interval_seconds}s required → check"
    else
        debug_log "Interval: no state file → first check"
    fi

    return 0
}

# Update state file with timestamp and version
# 状態ファイルをタイムスタンプとバージョンで更新
update_state() {
    local version="${1:-}"
    local state_dir
    state_dir=$(dirname "$STATE_FILE")
    mkdir -p "$state_dir" 2>/dev/null || true
    echo "$(date +%s):${version}" > "$STATE_FILE" 2>/dev/null || true
}

# Build GitHub API URL based on channel setting
# チャンネル設定に応じた GitHub API URL を構築
build_api_url() {
    local repo="$1"
    local channel="${CHECK_CHANNEL:-all}"

    case "$channel" in
        stable)
            # Official releases only (non-prerelease, non-draft)
            # 正式リリースのみ（プレリリース・ドラフト除外）
            echo "https://api.github.com/repos/${repo}/releases/latest"
            ;;
        *)
            # All releases including pre-releases (default)
            # プレリリースを含む全リリース（デフォルト）
            echo "https://api.github.com/repos/${repo}/releases?per_page=1"
            ;;
    esac
}

# Extract tag_name from API response JSON
# APIレスポンスJSONからtag_nameを抽出
extract_tag_from_json() {
    local json_file="$1"
    local channel="${CHECK_CHANNEL:-all}"

    # /releases?per_page=1 returns an array, /releases/latest returns an object
    # /releases?per_page=1 は配列、/releases/latest はオブジェクトを返す
    local jq_expr
    if [ "$channel" = "stable" ]; then
        jq_expr='.tag_name // empty'
    else
        jq_expr='.[0].tag_name // empty'
    fi

    if command -v jq &>/dev/null; then
        jq -r "$jq_expr" "$json_file" 2>/dev/null
    else
        # Fallback: grep for first tag_name (works for both array and object)
        # フォールバック: 最初の tag_name を grep（配列・オブジェクト両対応）
        grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$json_file" 2>/dev/null | \
            sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1
    fi
}

# Fetch latest release from GitHub API
# GitHub API から最新リリースを取得
fetch_latest_release() {
    local repo="$1"
    local api_url
    api_url=$(build_api_url "$repo")
    local tmp_file
    tmp_file=$(mktemp)

    # Fetch with timeout, capture HTTP status
    # タイムアウト付きで取得、HTTPステータスをキャプチャ
    local http_code
    http_code=$(curl -s \
        --connect-timeout 1 \
        --max-time 3 \
        -w "%{http_code}" \
        -o "$tmp_file" \
        "$api_url" 2>/dev/null) || http_code="000"

    debug_log "API: $api_url → HTTP $http_code"

    # Check HTTP status
    case "$http_code" in
        200)
            # Success - extract tag_name
            # 成功 - tag_name を抽出
            local tag
            tag=$(extract_tag_from_json "$tmp_file")
            debug_log "API: tag_name=$tag"
            echo "$tag"
            rm -f "$tmp_file" 2>/dev/null
            return 0
            ;;
        *)
            # 404: No releases, 403: Rate limit, others: Network error
            # All cases: skip silently
            debug_log "API: failed (HTTP $http_code) → skip"
            rm -f "$tmp_file" 2>/dev/null
            return 1
            ;;
    esac
}

# Download prebuilt sandbox-mcp binary from GitHub Releases (used when Go is unavailable)
# Callers set $MSG_DOWNLOADING, $MSG_DOWNLOAD_OK, $MSG_DOWNLOAD_FAILED before invoking (same
# convention as $STATE_FILE / $CHECK_CHANNEL above).
# GitHub Releases からビルド済み sandbox-mcp バイナリをダウンロード（Go がない場合に使用）
# 呼び出し側は事前に $MSG_DOWNLOADING 等を設定すること（上記 $STATE_FILE 等と同じ規約）。
install_sandbox_mcp_binary() {
    local os arch filename install_dir install_path url

    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *) os=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
    esac
    arch=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
    filename="sandbox-mcp_${os}_${arch}"
    [ "$os" = "windows" ] && filename="${filename}.exe"

    install_dir="$HOME/.local/bin"
    install_path="$install_dir/sandbox-mcp"

    echo "$MSG_DOWNLOADING"
    mkdir -p "$install_dir"

    url="https://github.com/YujiSuzuki/sandbox-mcp/releases/latest/download/${filename}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$install_path" 2>&1 || { rm -f "$install_path"; echo "$MSG_DOWNLOAD_FAILED"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$install_path" 2>&1 || { rm -f "$install_path"; echo "$MSG_DOWNLOAD_FAILED"; return 1; }
    else
        echo "$MSG_DOWNLOAD_FAILED"
        return 1
    fi

    if [ ! -s "$install_path" ]; then
        rm -f "$install_path"
        echo "$MSG_DOWNLOAD_FAILED"
        return 1
    fi

    chmod +x "$install_path"
    echo "$MSG_DOWNLOAD_OK $install_path"

    # Make discoverable for the rest of this script / このスクリプト内で使えるようにする
    export PATH="$install_dir:$PATH"
    return 0
}

# ============================================================
# Initialization / 初期化
# ============================================================

# Auto-load configuration when sourced
# source 時に自動で設定を読み込み
load_startup_config

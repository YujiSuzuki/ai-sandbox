#!/bin/bash
# check-secret-sync.sh
# Check if files blocked in AI settings are also hidden in docker-compose.yml
#
# This script runs at AI Sandbox startup and warns if there are files that should
# be hidden from AI but are not configured in docker-compose.yml volume mounts.
#
# Supported AI settings files:
#   - .claude/settings.json  (Claude Code)
#   - .aiexclude             (Gemini Code Assist)
#   - .geminiignore          (Gemini CLI)
#
# .gitignore is intentionally NOT supported because it contains many non-secret patterns
# (node_modules/, dist/, *.log, .DS_Store) that would create noise in the sync check.
# AI exclusion files should explicitly list only secrets, keeping intent clear.
#
# Container-only: the docker-compose.yml hidden-file declarations it checks
# against always target the fixed in-container path /workspace/<path>, not
# wherever the repo happens to live on the host, so this comparison is only
# meaningful when $WORKSPACE is actually /workspace (i.e. running inside the
# container where that path is the live mount root).
# @env: container
# ---
# AI設定でブロックされたファイルが docker-compose.yml でも隠蔽されているかチェック
# このスクリプトは AI Sandbox 起動時に実行され、AI から隠すべきファイルが
# docker-compose.yml のボリュームマウントに設定されていない場合に警告します。
#
# 対応するAI設定ファイル:
#   - .claude/settings.json  (Claude Code)
#   - .aiexclude             (Gemini Code Assist)
#   - .geminiignore          (Gemini CLI)
#
# 注意: .gitignore は意図的にサポートしていません。
#
# 理由:
#   .gitignore には秘匿情報以外のパターン（node_modules/, dist/, *.log 等）が
#   多く含まれ、同期チェックでノイズになります。AI除外ファイルには秘匿情報のみを
#   明示的に記載することで、意図が明確になりメンテナンスも容易になります。
#
# コンテナ専用: 照合対象の docker-compose.yml の隠蔽宣言は常にコンテナ内の
# 固定パス /workspace/<path> を指しており、リポジトリがホスト上のどこに
# あるかとは無関係。そのため $WORKSPACE が実際に /workspace であるとき
# （＝コンテナ内で、そのパスが実マウントのルートであるとき）のみ、
# この照合は意味を持つ。

set -e

# Check if running on host OS (not in container)
# ホストOSで実行されていないかチェック
if [[ -z "${SANDBOX_ENV:-}" ]] && [[ ! -f "/.dockerenv" ]]; then
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        echo "❌ このスクリプトはホストOSでは実行できません。"
        echo ""
        echo "以下のいずれかの環境で実行してください："
        echo "  • AI Sandbox のターミナル"
        echo "  • cli_sandbox/ai_sandbox.sh"
    else
        echo "❌ This script cannot be run on the host OS."
        echo ""
        echo "Please run in one of these environments:"
        echo "  • AI Sandbox terminal"
        echo "  • cli_sandbox/ai_sandbox.sh"
    fi
    exit 1
fi

WORKSPACE="${WORKSPACE:-/workspace}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common startup functions
# 共通起動関数を読み込み
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_startup_common.sh"
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_secret-tag.sh"

# Determine which docker-compose.yml to use based on environment
# 環境に応じて使用する docker-compose.yml を決定
if [[ "$SANDBOX_ENV" == cli_* ]]; then
    COMPOSE_FILE="$WORKSPACE/cli_sandbox/docker-compose.yml"
else
    COMPOSE_FILE="$WORKSPACE/.devcontainer/docker-compose.yml"
fi

CLAUDE_SETTINGS="$WORKSPACE/.claude/settings.json"

# Language detection based on locale
# ロケールに基づく言語検出
if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    MSG_TITLE="🔄 シークレット設定同期チェック"
    MSG_CHECKING="チェック中..."
    MSG_NO_SETTINGS="Claude 設定ファイルが見つかりません"
    MSG_NO_COMPOSE="docker-compose.yml が見つかりません"
    MSG_ALL_SYNCED="✅ すべての秘匿ファイルが docker-compose.yml に設定されています"
    MSG_MISSING_HEADER="⚠️  以下のファイルが docker-compose.yml に未設定です:"
    MSG_MISSING_FOOTER="これらのファイルはいずれかの AI設定でブロックされていますが、"
    MSG_MISSING_FOOTER2="docker-compose.yml のボリュームマウントに設定されていません。"
    MSG_MISSING_FOOTER3="AI Sandbox 内では AI がこれらのファイルを読める可能性があります。"
    MSG_ACTION="対処方法:"
    MSG_ACTION1="  手動で docker-compose.yml を編集する（ホストOS側で）"
    MSG_ACTION2="  または: .sandbox/scripts/sync-secrets.sh を実行（シェル環境で）"
    MSG_ACTION3="  秘匿不要なら: .sandbox/config/sync-ignore にパターンを追加"
    MSG_NO_DENY="AI設定にファイルパターンがありません"
    MSG_NO_FILES="該当するファイルが見つかりませんでした"
    MSG_QUIET_MISSING="⚠️  %d 個のファイルが docker-compose.yml に未設定です"
    MSG_SUMMARY_OK="✓ Secret sync: 全件設定済み（%d 件チェック、%d 件無視）"
    MSG_IGNORED_HEADER="無視されたファイル (sync-ignore パターンにマッチ):"
else
    MSG_TITLE="🔄 Secret Config Sync Check"
    MSG_CHECKING="Checking..."
    MSG_NO_SETTINGS="Claude settings file not found"
    MSG_NO_COMPOSE="docker-compose.yml not found"
    MSG_ALL_SYNCED="✅ All secret files are configured in docker-compose.yml"
    MSG_MISSING_HEADER="⚠️  The following files are NOT configured in docker-compose.yml:"
    MSG_MISSING_FOOTER="These files are blocked in one or more AI settings but"
    MSG_MISSING_FOOTER2="not configured in docker-compose.yml volume mounts."
    MSG_MISSING_FOOTER3="AI may be able to read these files inside AI Sandbox."
    MSG_ACTION="Action required:"
    MSG_ACTION1="  Manually edit docker-compose.yml (on host OS)"
    MSG_ACTION2="  Or run: .sandbox/scripts/sync-secrets.sh (in shell environment)"
    MSG_ACTION3="  If not secret: add pattern to .sandbox/config/sync-ignore"
    MSG_NO_DENY="No file patterns in AI settings"
    MSG_NO_FILES="No matching files found"
    MSG_QUIET_MISSING="⚠️  %d files missing from docker-compose.yml"
    MSG_SUMMARY_OK="✓ Secret sync: all configured (%d checked, %d ignored)"
    MSG_IGNORED_HEADER="Ignored files (matched sync-ignore patterns):"
fi

# Directories to ignore during file search
# ファイル検索時に無視するディレクトリ
IGNORE_PATTERNS=(
    "*/node_modules/*"
    "*/.git/*"
    "*/.sandbox/*"
)

# Build find ignore options
# find の除外オプションを構築
build_ignore_opts() {
    local opts=()
    for p in "${IGNORE_PATTERNS[@]}"; do
        opts+=("!" "-path" "$p")
    done
    echo "${opts[@]}"
}

# Extract Read() patterns from .claude/settings.json
# .claude/settings.json から Read() パターンを抽出
extract_claude_patterns() {
    local settings_file="$1"

    if [ ! -f "$settings_file" ]; then
        return
    fi

    # Extract Read() patterns and convert to search-friendly format
    # Read() パターンを抽出し、検索しやすい形式に変換
    jq -r '.permissions.deny[]' "$settings_file" 2>/dev/null | \
        grep -E '^Read\(' | \
        sed -E 's/^Read\(([^)]+)\)$/\1/' | \
        sort -u
}

# Extract patterns from .aiexclude files (Gemini Code Assist)
# .aiexclude ファイルからパターンを抽出（Gemini Code Assist用）
extract_aiexclude_patterns() {
    local aiexclude_file="$1"

    if [ ! -f "$aiexclude_file" ]; then
        return
    fi

    # gitignore-style patterns, filter out comments and empty lines
    # gitignore形式のパターン、コメントと空行を除外
    grep -v '^#' "$aiexclude_file" | grep -v '^[[:space:]]*$' | sort -u
}

# Find all Gemini ignore files in workspace (.aiexclude, .geminiignore)
# ワークスペース内のすべての Gemini 除外ファイルを検索
find_gemini_ignore_files() {
    find "$WORKSPACE" \( -name ".aiexclude" -o -name ".geminiignore" \) -type f \
        ! -path "*/node_modules/*" \
        ! -path "*/.git/*" \
        2>/dev/null
}

# Find files matching a pattern
# パターンに一致するファイルを検索
find_matching_files() {
    local pattern="$1"
    local ignore_opts
    read -ra ignore_opts <<< "$(build_ignore_opts)"

    # Handle trailing slash = directory pattern (e.g., secrets/, **/secrets/)
    # 末尾スラッシュ = ディレクトリパターンの処理（例: secrets/, **/secrets/）
    if [[ "$pattern" == */ ]]; then
        local dir_pattern="${pattern%/}"  # Remove trailing slash / 末尾スラッシュを除去

        if [[ "$dir_pattern" == **/* ]]; then
            # Recursive directory pattern like **/secrets/
            # **/secrets/ のような再帰ディレクトリパターン
            local dir_name="${dir_pattern##**/}"
            find "$WORKSPACE" -type d -name "$dir_name" "${ignore_opts[@]}" 2>/dev/null | while read -r dir; do
                find "$dir" -type f "${ignore_opts[@]}" 2>/dev/null
            done
        else
            # Root-level directory pattern like secrets/
            # secrets/ のようなルートレベルディレクトリパターン
            local full_dir="$WORKSPACE/$dir_pattern"
            if [ -d "$full_dir" ]; then
                find "$full_dir" -type f "${ignore_opts[@]}" 2>/dev/null
            fi
        fi
        return
    fi

    # Convert glob pattern to find-compatible format
    # グロブパターンを find 互換形式に変換
    # **/ -> recursive, * -> single level

    if [[ "$pattern" == **/* ]]; then
        # Pattern like **/*.env or **/secrets/**
        # **/*.env や **/secrets/** のようなパターン
        local search_pattern="${pattern//\*\*\//*}"
        search_pattern="${search_pattern//\*\*/*}"

        if [[ "$pattern" == *"/**" ]]; then
            # Directory pattern like **/secrets/**
            # **/secrets/** のようなディレクトリパターン
            local dir_name="${pattern%/**}"
            dir_name="${dir_name##**/}"
            find "$WORKSPACE" -type d -name "$dir_name" "${ignore_opts[@]}" 2>/dev/null | while read -r dir; do
                find "$dir" -type f "${ignore_opts[@]}" 2>/dev/null
            done
        else
            # File pattern like **/*.env
            # **/*.env のようなファイルパターン
            local file_pattern="${pattern##**/}"
            find "$WORKSPACE" -name "$file_pattern" -type f "${ignore_opts[@]}" 2>/dev/null
        fi
    else
        # Specific path pattern like securenote-api/.env
        # securenote-api/.env のような具体的パスパターン
        local full_path="$WORKSPACE/$pattern"
        # Handle wildcards in specific paths
        # 具体的パスのワイルドカードを処理
        if [[ "$pattern" == *"*"* ]]; then
            # shellcheck disable=SC2086
            ls -1 $full_path 2>/dev/null || true
        elif [ -f "$full_path" ]; then
            echo "$full_path"
        elif [ -d "$full_path" ]; then
            find "$full_path" -type f "${ignore_opts[@]}" 2>/dev/null
        fi
    fi
}

# Check if a file is configured in docker-compose.yml
# ファイルが docker-compose.yml に設定されているかチェック
is_file_in_compose() {
    local file_path="$1"
    local compose_file="$2"
    # Escaped for safe use inside a grep -E pattern (both checks below)
    local escaped_file_path
    escaped_file_path=$(printf '%s' "$file_path" | sed -E 's/[][\.^$(){}?+*|]/\\&/g')

    # Check /dev/null mounts
    # /dev/null マウントをチェック
    if grep -qE "^\s*-\s*/dev/null:${escaped_file_path}(:ro)?$" "$compose_file" 2>/dev/null; then
        return 0
    fi

    # Check tmpfs mounts (for directories). Only matches a tmpfs entry
    # tagged with a trailing "# @secret" comment -- see _secret-tag.sh for
    # the shared matching regex used by all six secret-sync scripts, so
    # this check always agrees with validate-secrets.py /
    # compare-secret-config.py / etc. on what counts as a tagged entry.
    # tmpfs マウントをチェック（ディレクトリ用）。末尾に "# @secret" タグが
    # 付いているエントリのみを対象とする。共通のマッチング正規表現は
    # _secret-tag.sh を参照（6本のスクリプトすべてで共有し、
    # validate-secrets.py / compare-secret-config.py 等と判定が
    # 常に一致するようにする）。
    local dir_path
    dir_path=$(dirname "$file_path")
    while [ "$dir_path" != "$WORKSPACE" ] && [ "$dir_path" != "/" ]; do
        # Escaped for safe use inside a grep -E pattern
        local escaped_dir_path re
        escaped_dir_path=$(printf '%s' "$dir_path" | sed -E 's/[][\.^$(){}?+*|]/\\&/g')
        re=$(secret_tag_exact_regex "$escaped_dir_path")
        if grep -qE "$re" "$compose_file" 2>/dev/null; then
            return 0
        fi
        dir_path=$(dirname "$dir_path")
    done

    return 1
}

# Main
# メイン処理

# Check if settings file exists
# 設定ファイルの存在確認
if [ ! -f "$CLAUDE_SETTINGS" ]; then
    print_default "✓ Secret sync: $MSG_NO_SETTINGS"
    exit 0
fi

# Check if compose file exists
# compose ファイルの存在確認
if [ ! -f "$COMPOSE_FILE" ]; then
    print_default "✓ Secret sync: $MSG_NO_COMPOSE"
    exit 0
fi

# Get deny patterns from Claude settings
# Claude 設定から deny パターンを取得
claude_patterns=$(extract_claude_patterns "$CLAUDE_SETTINGS")

# Get patterns from all Gemini ignore files (.aiexclude, .geminiignore)
# すべての Gemini 除外ファイルからパターンを取得
gemini_patterns=""
while IFS= read -r ignore_file; do
    [ -z "$ignore_file" ] && continue
    file_patterns=$(extract_aiexclude_patterns "$ignore_file")
    if [ -n "$file_patterns" ]; then
        gemini_patterns="${gemini_patterns}${file_patterns}"$'\n'
    fi
done < <(find_gemini_ignore_files)

# Combine all patterns
# すべてのパターンを結合
patterns=$(echo -e "${claude_patterns}\n${gemini_patterns}" | grep -v '^$' | sort -u)

if [ -z "$patterns" ]; then
    print_default "✓ Secret sync: $MSG_NO_DENY"
    exit 0
fi

# Find all files matching deny patterns
# deny パターンに一致するすべてのファイルを検索
all_matching_files=$(
    while IFS= read -r pattern; do
        [ -n "$pattern" ] && find_matching_files "$pattern"
    done <<< "$patterns" | sort -u
)

if [ -z "$all_matching_files" ]; then
    print_default "✓ Secret sync: $MSG_NO_FILES"
    exit 0
fi

# Check which files are NOT in docker-compose.yml
# Also filter out files matching sync-ignore patterns
# docker-compose.yml に設定されていないファイルを確認
# sync-ignore パターンにマッチするファイルも除外
missing_files=()
ignored_files=()
while IFS= read -r file; do
    [ -z "$file" ] && continue

    # Check if file matches sync-ignore patterns
    # sync-ignore パターンにマッチするかチェック
    if matches_sync_ignore "$file"; then
        ignored_files+=("$file")
        continue
    fi

    if ! is_file_in_compose "$file" "$COMPOSE_FILE"; then
        missing_files+=("$file")
    fi
done <<< "$all_matching_files"

# ============================================================
# Quiet mode: only show if missing files / クワイエットモード: 未設定ファイルがある場合のみ表示
# ============================================================
if is_quiet; then
    if [ ${#missing_files[@]} -gt 0 ]; then
        # shellcheck disable=SC2059
        printf "$MSG_QUIET_MISSING\n" "${#missing_files[@]}"
        for file in "${missing_files[@]}"; do
            rel_path="${file#$WORKSPACE/}"
            echo "   📄 $rel_path"
        done
    fi
    exit 0
fi

# ============================================================
# Summary mode: problem explanation + action required / サマリーモード: 問題の説明と対応が必要な内容を表示
# ============================================================
if is_summary; then
    if [ ${#missing_files[@]} -gt 0 ]; then
        echo ""
        echo "$MSG_MISSING_HEADER"
        echo ""
        for file in "${missing_files[@]}"; do
            rel_path="${file#$WORKSPACE/}"
            echo "   📄 $rel_path"
        done
        echo ""
        echo "$MSG_MISSING_FOOTER"
        echo "$MSG_MISSING_FOOTER2"
        echo "$MSG_MISSING_FOOTER3"
        echo ""
        echo "$MSG_ACTION"
        echo "$MSG_ACTION1"
        echo "$MSG_ACTION2"
        echo "$MSG_ACTION3"
        echo ""
    else
        total_checked=$(echo "$all_matching_files" | grep -c . || true)
        # shellcheck disable=SC2059
        printf "$MSG_SUMMARY_OK\n" "$total_checked" "${#ignored_files[@]}"
    fi
    exit 0
fi

# ============================================================
# Verbose mode: full output / 詳細モード: 全出力を表示
# ============================================================
print_title "$MSG_TITLE"

# Report results
# 結果を報告
if [ ${#missing_files[@]} -eq 0 ]; then
    echo "$MSG_ALL_SYNCED"
    if [ ${#ignored_files[@]} -gt 0 ]; then
        echo ""
        echo "$MSG_IGNORED_HEADER"
        for file in "${ignored_files[@]}"; do
            rel_path="${file#$WORKSPACE/}"
            echo "   📄 $rel_path"
        done
    fi
else
    echo "$MSG_MISSING_HEADER"
    echo ""
    for file in "${missing_files[@]}"; do
        # Show relative path from workspace
        # ワークスペースからの相対パスを表示
        rel_path="${file#$WORKSPACE/}"
        echo "   📄 $rel_path"
    done
    echo ""
    echo "$MSG_MISSING_FOOTER"
    echo "$MSG_MISSING_FOOTER2"
    echo "$MSG_MISSING_FOOTER3"
    echo ""
    echo "$MSG_ACTION"
    echo "$MSG_ACTION1"
    echo "$MSG_ACTION2"
    echo "$MSG_ACTION3"

    if [ ${#ignored_files[@]} -gt 0 ]; then
        echo ""
        echo "$MSG_IGNORED_HEADER"
        for file in "${ignored_files[@]}"; do
            rel_path="${file#$WORKSPACE/}"
            echo "   📄 $rel_path"
        done
    fi
fi
print_footer

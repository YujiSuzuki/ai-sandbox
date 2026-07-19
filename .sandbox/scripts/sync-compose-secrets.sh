#!/bin/bash
# sync-compose-secrets.sh
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
# Escaped for safe use inside a bash =~ regex (tmpfs-line detection below)
WORKSPACE_RE=$(printf '%s' "$WORKSPACE" | sed -E 's/[][\.^$(){}?+*|]/\\&/g')

# Source common functions (backup utilities, etc.)
# 共通関数を読み込み（バックアップユーティリティなど）
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_startup_common.sh"

DEVCONTAINER_COMPOSE="$WORKSPACE/.devcontainer/docker-compose.yml"
CLI_SANDBOX_COMPOSE="$WORKSPACE/cli_sandbox/docker-compose.yml"

# Short display paths
# 表示用の短いパス
DEVCONTAINER_COMPOSE_SHORT=".devcontainer/docker-compose.yml"
CLI_SANDBOX_COMPOSE_SHORT="cli_sandbox/docker-compose.yml"

# Language detection based on locale
# ロケールに基づく言語検出
if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    MSG_TITLE="🔧 docker-compose.yml 秘匿設定同期ツール"
    MSG_CHECKING="差異をチェック中..."
    MSG_FILE_NOT_FOUND="ファイルが見つかりません:"
    MSG_ALL_SYNCED="✅ 両方の docker-compose.yml は同期されています。差異はありません。"
    MSG_FOUND_HEADER="以下の差異が見つかりました:"
    MSG_VOLUMES="/dev/null マウント (volumes)"
    MSG_TMPFS="tmpfs マウント"
    MSG_ONLY_IN="のみに存在:"
    MSG_PROMPT="どうしますか？"
    MSG_YES_ALL="すべて同期"
    MSG_YES_EACH="個別確認"
    MSG_NO="同期しない"
    MSG_PREVIEW="プレビュー表示"
    MSG_CONFIRM="追加しますか？"
    MSG_ADDING="追加中:"
    MSG_ADDED="✅ 追加しました"
    MSG_SKIPPED="⏭️  スキップしました"
    MSG_DONE_HEADER="完了！"
    MSG_DONE_ADDED="同期されたエントリ:"
    MSG_DONE_NONE="同期されたエントリはありません"
    MSG_REBUILD="変更を反映するにはコンテナをリビルドしてください:"
    MSG_REBUILD_DC="  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'"
    MSG_REBUILD_CLI="  CLI: docker-compose で再起動"
    MSG_BACKUP="バックアップを作成しました:"
    MSG_PREVIEW_HEADER="以下を追加します:"
    MSG_PREVIEW_VOLUMES="📄 volumes セクションに追加:"
    MSG_PREVIEW_TMPFS="📁 tmpfs セクションに追加:"
    MSG_TO_FILE="追加先:"
else
    MSG_TITLE="🔧 docker-compose.yml Secret Config Sync Tool"
    MSG_CHECKING="Checking for differences..."
    MSG_FILE_NOT_FOUND="File not found:"
    MSG_ALL_SYNCED="✅ Both docker-compose.yml files are in sync. No differences found."
    MSG_FOUND_HEADER="The following differences were found:"
    MSG_VOLUMES="/dev/null mounts (volumes)"
    MSG_TMPFS="tmpfs mounts"
    MSG_ONLY_IN="only in:"
    MSG_PROMPT="What would you like to do?"
    MSG_YES_ALL="Sync all"
    MSG_YES_EACH="Review each"
    MSG_NO="Don't sync"
    MSG_PREVIEW="Preview changes"
    MSG_CONFIRM="Add this entry?"
    MSG_ADDING="Adding:"
    MSG_ADDED="✅ Added"
    MSG_SKIPPED="⏭️  Skipped"
    MSG_DONE_HEADER="Done!"
    MSG_DONE_ADDED="Synced entries:"
    MSG_DONE_NONE="No entries were synced"
    MSG_REBUILD="Rebuild containers to apply changes:"
    MSG_REBUILD_DC="  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'"
    MSG_REBUILD_CLI="  CLI: Restart with docker-compose"
    MSG_BACKUP="Backup created:"
    MSG_PREVIEW_HEADER="The following will be added:"
    MSG_PREVIEW_VOLUMES="📄 Add to volumes section:"
    MSG_PREVIEW_TMPFS="📁 Add to tmpfs section:"
    MSG_TO_FILE="Target file:"
fi

# Check if files exist
# ファイルの存在確認
check_files() {
    local missing=false
    if [ ! -f "$DEVCONTAINER_COMPOSE" ]; then
        echo "$MSG_FILE_NOT_FOUND $DEVCONTAINER_COMPOSE"
        missing=true
    fi
    if [ ! -f "$CLI_SANDBOX_COMPOSE" ]; then
        echo "$MSG_FILE_NOT_FOUND $CLI_SANDBOX_COMPOSE"
        missing=true
    fi
    if [ "$missing" = true ]; then
        exit 1
    fi
}

# Extract /dev/null volume mounts
# /dev/null マウントを抽出
extract_devnull_mounts() {
    local file="$1"
    grep -E '^\s*-\s*/dev/null:' "$file" 2>/dev/null | \
        sed 's/^[[:space:]]*-[[:space:]]*//' | \
        sort || true
}

# Extract tmpfs mounts ($WORKSPACE paths with :ro)
# tmpfs マウントを抽出（$WORKSPACE パスで :ro 付き）
extract_tmpfs_mounts() {
    local file="$1"
    local in_tmpfs=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*tmpfs: ]]; then
            in_tmpfs=true
            continue
        fi
        if [[ "$in_tmpfs" == true && "$line" =~ ^[[:space:]]*[a-z_]+: && ! "$line" =~ ^[[:space:]]*- ]]; then
            in_tmpfs=false
            continue
        fi
        if [[ "$in_tmpfs" == true && "$line" =~ ^[[:space:]]*-[[:space:]]*$WORKSPACE_RE && "$line" =~ :ro($|[[:space:]]) ]]; then
            echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//'
        fi
    done < "$file" | sort -u
}

# Add a /dev/null mount to docker-compose.yml
# /dev/null マウントを docker-compose.yml に追加
add_devnull_mount() {
    local mount="$1"
    local compose_file="$2"

    local last_devnull_line
    last_devnull_line=$(grep -n '/dev/null:' "$compose_file" | tail -1 | cut -d: -f1)

    if [ -n "$last_devnull_line" ]; then
        local indent="      "
        sed -i "${last_devnull_line}a\\${indent}- ${mount}" "$compose_file"
        return 0
    else
        echo "Warning: Could not find existing /dev/null mounts in $compose_file"
        return 1
    fi
}

# Add a tmpfs mount to docker-compose.yml
# tmpfs マウントを docker-compose.yml に追加
add_tmpfs_mount() {
    local mount="$1"
    local compose_file="$2"

    local in_tmpfs=false
    local last_tmpfs_line=0
    local line_num=0

    while IFS= read -r line; do
        ((line_num++))
        if [[ "$line" =~ ^[[:space:]]*tmpfs: ]]; then
            in_tmpfs=true
            continue
        fi
        if [[ "$in_tmpfs" == true && "$line" =~ ^[[:space:]]*-[[:space:]]*$WORKSPACE_RE ]]; then
            last_tmpfs_line=$line_num
        fi
        if [[ "$in_tmpfs" == true && "$line" =~ ^[[:space:]]*[a-z_]+: && ! "$line" =~ ^[[:space:]]*- ]]; then
            in_tmpfs=false
        fi
    done < "$compose_file"

    if [ "$last_tmpfs_line" -gt 0 ]; then
        local indent="      "
        sed -i "${last_tmpfs_line}a\\${indent}- ${mount}" "$compose_file"
        return 0
    else
        echo "Warning: Could not find tmpfs section in $compose_file"
        return 1
    fi
}

# Create backups in .sandbox/backups/ and clean up old ones
# .sandbox/backups/ にバックアップを作成し、古いものを整理
create_backups() {
    echo ""
    echo "$MSG_BACKUP"

    local backup_dc
    backup_dc=$(backup_file "$DEVCONTAINER_COMPOSE" "devcontainer")
    echo "   $DEVCONTAINER_COMPOSE_SHORT → ${backup_dc}"
    cleanup_backups "devcontainer.docker-compose.yml.*"

    local backup_cli
    backup_cli=$(backup_file "$CLI_SANDBOX_COMPOSE" "cli_sandbox")
    echo "   $CLI_SANDBOX_COMPOSE_SHORT → ${backup_cli}"
    cleanup_backups "cli_sandbox.docker-compose.yml.*"

    echo ""
}

# Main
# メイン処理
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$MSG_TITLE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

check_files

echo "$MSG_CHECKING"
echo ""

# Extract mounts from both files
# 両ファイルからマウント設定を抽出
dc_volumes=$(extract_devnull_mounts "$DEVCONTAINER_COMPOSE")
cli_volumes=$(extract_devnull_mounts "$CLI_SANDBOX_COMPOSE")
dc_tmpfs=$(extract_tmpfs_mounts "$DEVCONTAINER_COMPOSE")
cli_tmpfs=$(extract_tmpfs_mounts "$CLI_SANDBOX_COMPOSE")

# Find differences
# 差異を検出
volumes_only_in_dc=$(comm -23 <(echo "$dc_volumes") <(echo "$cli_volumes") 2>/dev/null || true)
volumes_only_in_cli=$(comm -13 <(echo "$dc_volumes") <(echo "$cli_volumes") 2>/dev/null || true)
tmpfs_only_in_dc=$(comm -23 <(echo "$dc_tmpfs") <(echo "$cli_tmpfs") 2>/dev/null || true)
tmpfs_only_in_cli=$(comm -13 <(echo "$dc_tmpfs") <(echo "$cli_tmpfs") 2>/dev/null || true)

# Check if there are any differences
# 差異があるかチェック
has_diff=false
[ -n "$volumes_only_in_dc" ] && has_diff=true
[ -n "$volumes_only_in_cli" ] && has_diff=true
[ -n "$tmpfs_only_in_dc" ] && has_diff=true
[ -n "$tmpfs_only_in_cli" ] && has_diff=true

if [ "$has_diff" = false ]; then
    echo "$MSG_ALL_SYNCED"
    echo ""
    exit 0
fi

# Show differences
# 差異を表示
echo "$MSG_FOUND_HEADER"
echo ""

if [ -n "$volumes_only_in_dc" ] || [ -n "$volumes_only_in_cli" ]; then
    echo "📁 $MSG_VOLUMES"
    if [ -n "$volumes_only_in_dc" ]; then
        echo "   DevContainer $MSG_ONLY_IN ($DEVCONTAINER_COMPOSE_SHORT)"
        echo "$volumes_only_in_dc" | while read -r line; do
            [ -n "$line" ] && echo "      - $line"
        done
    fi
    if [ -n "$volumes_only_in_cli" ]; then
        echo "   CLI Sandbox $MSG_ONLY_IN ($CLI_SANDBOX_COMPOSE_SHORT)"
        echo "$volumes_only_in_cli" | while read -r line; do
            [ -n "$line" ] && echo "      - $line"
        done
    fi
    echo ""
fi

if [ -n "$tmpfs_only_in_dc" ] || [ -n "$tmpfs_only_in_cli" ]; then
    echo "📁 $MSG_TMPFS"
    if [ -n "$tmpfs_only_in_dc" ]; then
        echo "   DevContainer $MSG_ONLY_IN ($DEVCONTAINER_COMPOSE_SHORT)"
        echo "$tmpfs_only_in_dc" | while read -r line; do
            [ -n "$line" ] && echo "      - $line"
        done
    fi
    if [ -n "$tmpfs_only_in_cli" ]; then
        echo "   CLI Sandbox $MSG_ONLY_IN ($CLI_SANDBOX_COMPOSE_SHORT)"
        echo "$tmpfs_only_in_cli" | while read -r line; do
            [ -n "$line" ] && echo "      - $line"
        done
    fi
    echo ""
fi

# Prompt user
# ユーザーに確認
echo "───────────────────────────────────────────────────────────"
echo "$MSG_PROMPT"
echo ""
echo "  1) $MSG_YES_ALL"
echo "  2) $MSG_YES_EACH"
echo "  3) $MSG_NO"
echo "  4) $MSG_PREVIEW"
echo ""
read -rp "Select [1/2/3/4]: " choice

synced_entries=()

# Helper function to sync all entries
# 全エントリを同期するヘルパー関数
sync_all() {
    create_backups

    # Add DevContainer-only entries to CLI Sandbox
    # DevContainer のみのエントリを CLI Sandbox に追加
    if [ -n "$volumes_only_in_dc" ]; then
        while read -r mount; do
            [ -z "$mount" ] && continue
            echo "$MSG_ADDING $mount"
            echo "   $MSG_TO_FILE $CLI_SANDBOX_COMPOSE_SHORT"
            if add_devnull_mount "$mount" "$CLI_SANDBOX_COMPOSE"; then
                echo "   $MSG_ADDED"
                synced_entries+=("$mount")
            fi
        done <<< "$volumes_only_in_dc"
    fi

    if [ -n "$tmpfs_only_in_dc" ]; then
        while read -r mount; do
            [ -z "$mount" ] && continue
            echo "$MSG_ADDING $mount"
            echo "   $MSG_TO_FILE $CLI_SANDBOX_COMPOSE_SHORT"
            if add_tmpfs_mount "$mount" "$CLI_SANDBOX_COMPOSE"; then
                echo "   $MSG_ADDED"
                synced_entries+=("$mount")
            fi
        done <<< "$tmpfs_only_in_dc"
    fi

    # Add CLI Sandbox-only entries to DevContainer
    # CLI Sandbox のみのエントリを DevContainer に追加
    if [ -n "$volumes_only_in_cli" ]; then
        while read -r mount; do
            [ -z "$mount" ] && continue
            echo "$MSG_ADDING $mount"
            echo "   $MSG_TO_FILE $DEVCONTAINER_COMPOSE_SHORT"
            if add_devnull_mount "$mount" "$DEVCONTAINER_COMPOSE"; then
                echo "   $MSG_ADDED"
                synced_entries+=("$mount")
            fi
        done <<< "$volumes_only_in_cli"
    fi

    if [ -n "$tmpfs_only_in_cli" ]; then
        while read -r mount; do
            [ -z "$mount" ] && continue
            echo "$MSG_ADDING $mount"
            echo "   $MSG_TO_FILE $DEVCONTAINER_COMPOSE_SHORT"
            if add_tmpfs_mount "$mount" "$DEVCONTAINER_COMPOSE"; then
                echo "   $MSG_ADDED"
                synced_entries+=("$mount")
            fi
        done <<< "$tmpfs_only_in_cli"
    fi
}

# Helper function to sync with confirmation for each entry
# 各エントリを確認しながら同期するヘルパー関数
sync_each() {
    create_backups

    # Add DevContainer-only entries to CLI Sandbox
    # DevContainer のみのエントリを CLI Sandbox に追加
    if [ -n "$volumes_only_in_dc" ]; then
        # Use mapfile to avoid stdin redirection in while loop
        # while ループでの stdin リダイレクトを避けるため mapfile を使用
        mapfile -t mounts <<< "$volumes_only_in_dc"
        for mount in "${mounts[@]}"; do
            [ -z "$mount" ] && continue
            echo ""
            echo "📄 $mount"
            echo "   $MSG_TO_FILE $CLI_SANDBOX_COMPOSE_SHORT"
            read -rp "   $MSG_CONFIRM [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                if add_devnull_mount "$mount" "$CLI_SANDBOX_COMPOSE"; then
                    echo "   $MSG_ADDED"
                    synced_entries+=("$mount")
                fi
            else
                echo "   $MSG_SKIPPED"
            fi
        done
    fi

    if [ -n "$tmpfs_only_in_dc" ]; then
        mapfile -t mounts <<< "$tmpfs_only_in_dc"
        for mount in "${mounts[@]}"; do
            [ -z "$mount" ] && continue
            echo ""
            echo "📁 $mount"
            echo "   $MSG_TO_FILE $CLI_SANDBOX_COMPOSE_SHORT"
            read -rp "   $MSG_CONFIRM [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                if add_tmpfs_mount "$mount" "$CLI_SANDBOX_COMPOSE"; then
                    echo "   $MSG_ADDED"
                    synced_entries+=("$mount")
                fi
            else
                echo "   $MSG_SKIPPED"
            fi
        done
    fi

    # Add CLI Sandbox-only entries to DevContainer
    # CLI Sandbox のみのエントリを DevContainer に追加
    if [ -n "$volumes_only_in_cli" ]; then
        mapfile -t mounts <<< "$volumes_only_in_cli"
        for mount in "${mounts[@]}"; do
            [ -z "$mount" ] && continue
            echo ""
            echo "📄 $mount"
            echo "   $MSG_TO_FILE $DEVCONTAINER_COMPOSE_SHORT"
            read -rp "   $MSG_CONFIRM [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                if add_devnull_mount "$mount" "$DEVCONTAINER_COMPOSE"; then
                    echo "   $MSG_ADDED"
                    synced_entries+=("$mount")
                fi
            else
                echo "   $MSG_SKIPPED"
            fi
        done
    fi

    if [ -n "$tmpfs_only_in_cli" ]; then
        mapfile -t mounts <<< "$tmpfs_only_in_cli"
        for mount in "${mounts[@]}"; do
            [ -z "$mount" ] && continue
            echo ""
            echo "📁 $mount"
            echo "   $MSG_TO_FILE $DEVCONTAINER_COMPOSE_SHORT"
            read -rp "   $MSG_CONFIRM [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                if add_tmpfs_mount "$mount" "$DEVCONTAINER_COMPOSE"; then
                    echo "   $MSG_ADDED"
                    synced_entries+=("$mount")
                fi
            else
                echo "   $MSG_SKIPPED"
            fi
        done
    fi
}

# Show preview
# プレビューを表示
show_preview() {
    if [ -n "$volumes_only_in_dc" ] || [ -n "$tmpfs_only_in_dc" ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$MSG_PREVIEW_HEADER $CLI_SANDBOX_COMPOSE_SHORT"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -n "$volumes_only_in_dc" ]; then
            echo ""
            echo "$MSG_PREVIEW_VOLUMES"
            echo "$volumes_only_in_dc" | while read -r mount; do
                [ -n "$mount" ] && echo "      - $mount"
            done
        fi
        if [ -n "$tmpfs_only_in_dc" ]; then
            echo ""
            echo "$MSG_PREVIEW_TMPFS"
            echo "$tmpfs_only_in_dc" | while read -r mount; do
                [ -n "$mount" ] && echo "      - $mount"
            done
        fi
    fi

    if [ -n "$volumes_only_in_cli" ] || [ -n "$tmpfs_only_in_cli" ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$MSG_PREVIEW_HEADER $DEVCONTAINER_COMPOSE_SHORT"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -n "$volumes_only_in_cli" ]; then
            echo ""
            echo "$MSG_PREVIEW_VOLUMES"
            echo "$volumes_only_in_cli" | while read -r mount; do
                [ -n "$mount" ] && echo "      - $mount"
            done
        fi
        if [ -n "$tmpfs_only_in_cli" ]; then
            echo ""
            echo "$MSG_PREVIEW_TMPFS"
            echo "$tmpfs_only_in_cli" | while read -r mount; do
                [ -n "$mount" ] && echo "      - $mount"
            done
        fi
    fi
    echo ""
}

case "$choice" in
    1)
        sync_all
        ;;
    2)
        sync_each
        ;;
    3)
        echo ""
        echo "$MSG_SKIPPED"
        exit 0
        ;;
    4)
        show_preview
        exit 0
        ;;
    *)
        echo ""
        echo "$MSG_SKIPPED"
        exit 0
        ;;
esac

# Summary
# サマリー
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$MSG_DONE_HEADER"
echo ""

if [ ${#synced_entries[@]} -gt 0 ]; then
    echo "$MSG_DONE_ADDED"
    for entry in "${synced_entries[@]}"; do
        echo "   ✅ $entry"
    done
    echo ""
    echo "───────────────────────────────────────────────────────────"
    echo "$MSG_REBUILD"
    echo "$MSG_REBUILD_DC"
    echo "$MSG_REBUILD_CLI"
else
    echo "$MSG_DONE_NONE"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

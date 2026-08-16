#!/bin/bash
# triage-undeclared-secrets.sh
# Interactively triage findings from check-undeclared-secrets.sh: per item, the user judges
# it a real secret (hide via docker-compose.yml), not a secret (add to sync-ignore), or skip.
#
# Usage: .sandbox/scripts/triage-undeclared-secrets.sh [--dry-run]
#   --dry-run: Show what each finding would become without prompting or writing anything
#
# IMPORTANT: Must run inside AI Sandbox container (not on host OS).
# @env: container
# ---
# check-undeclared-secrets.sh の検出結果を1件ずつ対話式に処理する:
# ユーザーが中身を確認し、本物の秘密なら docker-compose.yml で隠蔽 / 秘密でなければ
# sync-ignore に追記 / 判断しないならスキップ、を選ぶ。
#
# 使用法: .sandbox/scripts/triage-undeclared-secrets.sh [--dry-run]
#   --dry-run: プロンプトも書き込みも行わず、各検出結果がどう処理されるかのみ表示

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

# Source common startup functions (sync-ignore support, backups) and the
# shared "# @secret" tag matcher
# 共通起動関数（sync-ignore サポート、バックアップ）と共有の "# @secret"
# タグマッチャーを読み込み
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_startup_common.sh"
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_secret-tag.sh"

CHECK_SCRIPT="${CHECK_SCRIPT:-$WORKSPACE/.sandbox/scripts/check-undeclared-secrets.sh}"

DEVCONTAINER_COMPOSE="$WORKSPACE/.devcontainer/docker-compose.yml"
CLI_SANDBOX_COMPOSE="$WORKSPACE/cli_sandbox/docker-compose.yml"
LABEL_DC="DevContainer"
LABEL_CLI="CLI Sandbox"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

# Language detection based on locale
# ロケールに基づく言語検出
if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    MSG_TITLE="🕵️  未宣言シークレットのトリアージ"
    MSG_DISCLAIMER="名前パターンによる検出結果です。1件ずつ確認しながら処理してください。"
    MSG_COMPOSE_FOUND="検出された docker-compose.yml:"
    MSG_NO_COMPOSE="docker-compose.yml が見つかりません（両方とも）"
    MSG_NO_JQ="jq が必要です"
    MSG_NONE_FOUND="✅ 対処が必要な未宣言ファイルはありません。"
    MSG_FOUND_COUNT="件の未宣言ファイルが見つかりました。1件ずつ確認します。"
    MSG_CLAUDE_ONLY_NOTE="（.claude/settings.json では既にカバー済み。sync-secrets.sh で対処できます）"
    MSG_FILE_TYPE="File"
    MSG_DIR_TYPE="Dir"
    MSG_CONFIRM_WARNING="⚠️  ファイル名からの自動判定です。選択前に中身を確認してください"
    MSG_OPT_HIDE="1) 本物の秘密だと判断 → docker-compose.yml で隠蔽"
    MSG_OPT_IGNORE="2) 秘密ではないと判断 → sync-ignore に追加"
    MSG_OPT_SKIP="3) 今は判断しない → スキップ"
    MSG_PROMPT="選択 [1/2/3]: "
    MSG_HIDDEN="✅ 隠蔽しました"
    MSG_IGNORED_ACTION="✅ sync-ignore に追加しました"
    MSG_SKIPPED="⏭️  スキップしました"
    MSG_BACKUP="バックアップを作成しました:"
    MSG_HIDE_FAILED="⚠️  隠蔽に失敗しました（手動で追加してください）"
    MSG_SUMMARY_HEADER="完了！"
    MSG_SUMMARY_HIDDEN="隠蔽したファイル:"
    MSG_SUMMARY_IGNORED="sync-ignore に追加したファイル:"
    MSG_SUMMARY_SKIPPED="スキップした件数:"
    MSG_SUMMARY_NONE="変更はありませんでした"
    MSG_REBUILD="変更を反映するにはコンテナをリビルドしてください:"
    MSG_REBUILD_CMD="  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'"
    MSG_REBUILD_CLI="  CLI: ./cli_sandbox/build.sh"
    MSG_DRY_RUN_HEADER="🔍 ドライラン: 変更は行われません"
    MSG_DRY_RUN_HIDE="  隠蔽する場合 →"
    MSG_DRY_RUN_IGNORE="  無視する場合 →"
else
    MSG_TITLE="🕵️  Undeclared Secrets Triage"
    MSG_DISCLAIMER="Based on name-pattern detection -- review each item as you go."
    MSG_COMPOSE_FOUND="Detected docker-compose.yml:"
    MSG_NO_COMPOSE="docker-compose.yml not found (neither file exists)"
    MSG_NO_JQ="jq is required"
    MSG_NONE_FOUND="✅ No undeclared files need action."
    MSG_FOUND_COUNT="undeclared file(s) found. Reviewing one at a time."
    MSG_CLAUDE_ONLY_NOTE="(already covered by .claude/settings.json -- can also be handled by sync-secrets.sh)"
    MSG_FILE_TYPE="File"
    MSG_DIR_TYPE="Dir"
    MSG_CONFIRM_WARNING="⚠️  Detected by filename only -- check the file's actual content before choosing"
    MSG_OPT_HIDE="1) Judged as a real secret -> hide via docker-compose.yml"
    MSG_OPT_IGNORE="2) Judged as not a secret -> add to sync-ignore"
    MSG_OPT_SKIP="3) Not decided yet -> skip"
    MSG_PROMPT="Select [1/2/3]: "
    MSG_HIDDEN="✅ Hidden"
    MSG_IGNORED_ACTION="✅ Added to sync-ignore"
    MSG_SKIPPED="⏭️  Skipped"
    MSG_BACKUP="Backup created:"
    MSG_HIDE_FAILED="⚠️  Failed to hide (please add manually)"
    MSG_SUMMARY_HEADER="Done!"
    MSG_SUMMARY_HIDDEN="Hidden:"
    MSG_SUMMARY_IGNORED="Added to sync-ignore:"
    MSG_SUMMARY_SKIPPED="Skipped:"
    MSG_SUMMARY_NONE="No changes were made"
    MSG_REBUILD="Rebuild containers to apply changes:"
    MSG_REBUILD_CMD="  VS Code: Ctrl+Shift+P → 'Dev Containers: Rebuild Container'"
    MSG_REBUILD_CLI="  CLI: ./cli_sandbox/build.sh"
    MSG_DRY_RUN_HEADER="🔍 Dry-run: no changes will be made"
    MSG_DRY_RUN_HIDE="  If hidden ->"
    MSG_DRY_RUN_IGNORE="  If ignored ->"
fi

# ============================================================
# docker-compose.yml edit helpers
#
# Intentionally duplicated from sync-secrets.sh rather than extracted into
# a shared lib: check-undeclared-secrets.sh already has its own independent
# compose-detection logic (is_path_hidden_by_compose) rather than reusing
# sync-secrets.sh's, so per-script duplication of this straightforward
# sed-based editing is the existing convention here -- only the "# @secret"
# tag regex that six scripts must agree on byte-for-byte lives in a shared
# file (_secret-tag.sh). If a third caller needs this logic, extract it then.
#
# sync-secrets.sh から意図的に複製している（共通ライブラリへは切り出さない）:
# check-undeclared-secrets.sh も sync-secrets.sh とは別に独自の compose 検出
# ロジック(is_path_hidden_by_compose)を持っており、この程度の sed 編集は
# スクリプトごとに複製するのがこのプロジェクトの既存の流儀。6本のスクリプトが
# 完全一致で合意する必要がある "# @secret" タグの正規表現だけが共通ファイル
# (_secret-tag.sh) にある。3箇所目の呼び出しが必要になったら切り出す。
# ============================================================

is_file_in_compose() {
    local file_path="$1"
    local compose_file="$2"

    local escaped_file_path
    escaped_file_path=$(printf '%s' "$file_path" | sed -E 's/[][\.^$(){}?+*|]/\\&/g')
    if grep -qE "^\s*-\s*/dev/null:${escaped_file_path}(:ro)?$" "$compose_file" 2>/dev/null; then
        return 0
    fi

    # Start at file_path itself, not its parent -- file_path may itself be a
    # directory that's already tagged (e.g. hidden in one compose file but
    # not the other), and that exact-path match must be checked before
    # walking ancestors.
    # file_path自身から開始する（親ディレクトリからではない）--
    # file_path自体がタグ付き済みのディレクトリである場合があり
    # （例: 一方のcomposeファイルでは既に隠蔽済みだがもう一方では未隠蔽）、
    # 祖先を辿る前にこの完全一致をチェックする必要がある。
    local dir_path="$file_path"
    while [ "$dir_path" != "$WORKSPACE" ] && [ "$dir_path" != "/" ]; do
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

add_file_to_compose() {
    local file_path="$1"
    local compose_file="$2"

    local last_devnull_line
    last_devnull_line=$(grep -n '/dev/null:' "$compose_file" | tail -1 | cut -d: -f1)

    if [ -n "$last_devnull_line" ]; then
        local indent="      "
        sed -i "${last_devnull_line}a\\${indent}- /dev/null:${file_path}:ro" "$compose_file"
    else
        echo "Warning: Could not find existing /dev/null mounts in $compose_file"
        echo "Please add manually: - /dev/null:${file_path}:ro"
        return 1
    fi
}

add_dir_to_compose() {
    local dir_path="$1"
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
        sed -i "${last_tmpfs_line}a\\${indent}- ${dir_path}  # @secret" "$compose_file"
    else
        echo "Warning: Could not find tmpfs section in $compose_file"
        echo "Please add manually under tmpfs: - ${dir_path}  # @secret"
        return 1
    fi
}

get_compose_label() {
    local compose_file="$1"
    if [ "$compose_file" = "$DEVCONTAINER_COMPOSE" ]; then
        echo "$LABEL_DC"
    elif [ "$compose_file" = "$CLI_SANDBOX_COMPOSE" ]; then
        echo "$LABEL_CLI"
    else
        echo "$compose_file"
    fi
}

# Hide one path via compose in every compose file where it's still missing.
# Backs up each compose file at most once per run, only on its first actual
# write (lazy -- a run where every item is skipped creates zero backups).
# 未宣言のすべての compose ファイルにパスを隠蔽する。各 compose ファイルの
# バックアップは実行中に初めて書き込みが発生した時点で1回だけ作る
# （遅延方式 -- 全件スキップされた実行ではバックアップは作られない）。
declare -A BACKED_UP_COMPOSE
hide_path_in_composes() {
    local path="$1"
    local is_dir="$2"
    local any_success=false

    for compose_file in "${COMPOSE_FILES[@]}"; do
        is_file_in_compose "$path" "$compose_file" && continue

        if [ -z "${BACKED_UP_COMPOSE[$compose_file]:-}" ]; then
            local label backup_label backup_path
            label=$(get_compose_label "$compose_file")
            backup_label=$(echo "$label" | tr '[:upper:] ' '[:lower:]_')
            backup_path=$(backup_file "$compose_file" "$backup_label")
            echo "   $MSG_BACKUP $backup_path"
            cleanup_backups "${backup_label}.docker-compose.yml.*"
            BACKED_UP_COMPOSE[$compose_file]=1
        fi

        if [ "$is_dir" = true ]; then
            add_dir_to_compose "$path" "$compose_file" && any_success=true
        else
            add_file_to_compose "$path" "$compose_file" && any_success=true
        fi
    done

    [ "$any_success" = true ]
}

# Add to sync-ignore, backing it up at most once per run on first write.
# sync-ignore に追加。バックアップは実行中の初回書き込み時に1回だけ作る。
BACKED_UP_SYNC_IGNORE=false
ignore_path() {
    local rel_path="$1"

    if [ "$BACKED_UP_SYNC_IGNORE" = false ] && [ -f "$SYNC_IGNORE_FILE" ]; then
        local backup_path
        backup_path=$(backup_file "$SYNC_IGNORE_FILE" "sync_ignore")
        echo "   $MSG_BACKUP $backup_path"
        cleanup_backups "sync_ignore.sync-ignore.*"
        BACKED_UP_SYNC_IGNORE=true
    fi

    add_sync_ignore_pattern "$rel_path"
}

# ============================================================
# Main
# ============================================================

print_title "$MSG_TITLE"
echo "$MSG_DISCLAIMER"
echo ""

command -v jq &>/dev/null || { echo "❌ $MSG_NO_JQ"; exit 1; }

COMPOSE_FILES=()
COMPOSE_LABELS=()
[ -f "$DEVCONTAINER_COMPOSE" ] && COMPOSE_FILES+=("$DEVCONTAINER_COMPOSE") && COMPOSE_LABELS+=("$LABEL_DC")
[ -f "$CLI_SANDBOX_COMPOSE" ] && COMPOSE_FILES+=("$CLI_SANDBOX_COMPOSE") && COMPOSE_LABELS+=("$LABEL_CLI")

if [ ${#COMPOSE_FILES[@]} -eq 0 ]; then
    echo "❌ $MSG_NO_COMPOSE"
    exit 1
fi

echo "$MSG_COMPOSE_FOUND"
for i in "${!COMPOSE_FILES[@]}"; do
    echo "   📄 ${COMPOSE_LABELS[$i]}: ${COMPOSE_FILES[$i]}"
done
echo ""

[ -x "$CHECK_SCRIPT" ] || { echo "❌ $CHECK_SCRIPT not found or not executable"; exit 1; }

scan_json=$("$CHECK_SCRIPT" --format json)

mapfile -t undeclared_rel < <(echo "$scan_json" | jq -r '.undeclared[]')
mapfile -t claude_only_rel < <(echo "$scan_json" | jq -r '.claude_only[]')

is_claude_only() {
    local target="$1" p
    for p in "${claude_only_rel[@]}"; do
        [ "$p" = "$target" ] && return 0
    done
    return 1
}

if [ ${#undeclared_rel[@]} -eq 0 ]; then
    echo "$MSG_NONE_FOUND"
    print_footer
    exit 0
fi

if [ "$DRY_RUN" = true ]; then
    echo "$MSG_DRY_RUN_HEADER"
    echo ""
    for rel_path in "${undeclared_rel[@]}"; do
        local_path="$WORKSPACE/$rel_path"
        echo "📄 $rel_path"
        if [ -d "$local_path" ]; then
            echo "$MSG_DRY_RUN_HIDE      - ${local_path}  # @secret"
        else
            echo "$MSG_DRY_RUN_HIDE      - /dev/null:${local_path}:ro"
        fi
        echo "$MSG_DRY_RUN_IGNORE    $rel_path  (${SYNC_IGNORE_FILE#"$WORKSPACE"/})"
        echo ""
    done
    print_footer
    exit 0
fi

echo "${#undeclared_rel[@]} $MSG_FOUND_COUNT"
echo ""

hidden_list=()
ignored_list=()
skipped_count=0

for rel_path in "${undeclared_rel[@]}"; do
    local_path="$WORKSPACE/$rel_path"
    is_dir=false
    type_label="[$MSG_FILE_TYPE]"
    if [ -d "$local_path" ]; then
        is_dir=true
        type_label="[$MSG_DIR_TYPE]"
    fi

    echo "📄 $rel_path $type_label"
    if is_claude_only "$rel_path"; then
        echo "   $MSG_CLAUDE_ONLY_NOTE"
    fi
    echo "   $MSG_CONFIRM_WARNING"
    echo "   $MSG_OPT_HIDE"
    echo "   $MSG_OPT_IGNORE"
    echo "   $MSG_OPT_SKIP"
    read -rp "   $MSG_PROMPT" choice

    case "$choice" in
        1)
            if hide_path_in_composes "$local_path" "$is_dir"; then
                echo "   $MSG_HIDDEN"
                hidden_list+=("$rel_path")
            else
                echo "   $MSG_HIDE_FAILED"
            fi
            ;;
        2)
            ignore_path "$rel_path"
            echo "   $MSG_IGNORED_ACTION"
            ignored_list+=("$rel_path")
            ;;
        *)
            echo "   $MSG_SKIPPED"
            skipped_count=$((skipped_count + 1))
            ;;
    esac
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$MSG_SUMMARY_HEADER"
echo ""

if [ ${#hidden_list[@]} -eq 0 ] && [ ${#ignored_list[@]} -eq 0 ] && [ "$skipped_count" -eq "${#undeclared_rel[@]}" ]; then
    echo "$MSG_SUMMARY_NONE"
else
    if [ ${#hidden_list[@]} -gt 0 ]; then
        echo "$MSG_SUMMARY_HIDDEN"
        for f in "${hidden_list[@]}"; do echo "   ✅ $f"; done
    fi
    if [ ${#ignored_list[@]} -gt 0 ]; then
        echo "$MSG_SUMMARY_IGNORED"
        for f in "${ignored_list[@]}"; do echo "   ✅ $f"; done
    fi
    echo "$MSG_SUMMARY_SKIPPED $skipped_count"
fi

if [ ${#hidden_list[@]} -gt 0 ]; then
    echo ""
    echo "───────────────────────────────────────────────────────────"
    echo "$MSG_REBUILD"
    echo "$MSG_REBUILD_CMD"
    echo "$MSG_REBUILD_CLI"
fi

print_footer
exit 0

#!/bin/bash
# setup-language-hook.sh
# Idempotently register the Japanese-response-language reminder hook
# (UserPromptSubmit -> .sandbox/hooks/language-reminder.sh) in the workspace's
# .claude/settings.json when the container's default locale is Japanese.
# No-op for any other locale.
# ---
# コンテナのデフォルトロケールが日本語の場合、日本語応答リマインダーフック
# （UserPromptSubmit -> .sandbox/hooks/language-reminder.sh）を workspace の
# .claude/settings.json に冪等に登録する。それ以外のロケールでは何もしない。

set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"

# Only relevant for Japanese locale -- the hook itself also checks $LANG at
# call time, but registering it for other locales would just add a dead
# entry to settings.json.
# 日本語ロケールの場合のみ対象 -- フック自体も呼び出し時に$LANGを確認するが、
# 他ロケールで登録しても settings.json に無意味なエントリが増えるだけになる。
if [[ "${LANG:-}" != ja_JP* ]] && [[ "${LC_ALL:-}" != ja_JP* ]]; then
    exit 0
fi

# shellcheck source=/dev/null
source "${WORKSPACE_ROOT}/.sandbox/scripts/_startup_common.sh"

WORKSPACE_SETTINGS="$WORKSPACE_ROOT/.claude/settings.json"
HOOK_SCRIPT="$WORKSPACE_ROOT/.sandbox/hooks/language-reminder.sh"
HOOK_COMMAND="bash $HOOK_SCRIPT"

if ! command -v jq &> /dev/null; then
    print_warning "jq が見つからないため、言語リマインダーフックの設定をスキップしました。"
    exit 0
fi

mkdir -p "$(dirname "$WORKSPACE_SETTINGS")"
[ -f "$WORKSPACE_SETTINGS" ] || echo '{}' > "$WORKSPACE_SETTINGS"

# Already registered? (idempotent across container restarts)
# 既に登録済みか（コンテナ再起動をまたいで冪等にするため）
if jq -e --arg cmd "$HOOK_COMMAND" '
    [(.hooks.UserPromptSubmit // [])[].hooks[]? | select(.type == "command") | .command]
    | any(. == $cmd)
' "$WORKSPACE_SETTINGS" > /dev/null 2>&1; then
    print_detail "✓ 言語リマインダーフックは登録済みです。"
    exit 0
fi

merged=$(jq --arg cmd "$HOOK_COMMAND" '
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [
        {"hooks": [{"type": "command", "command": $cmd, "timeout": 5}]}
    ])
' "$WORKSPACE_SETTINGS")

echo "$merged" | jq '.' > "$WORKSPACE_SETTINGS.tmp" && mv "$WORKSPACE_SETTINGS.tmp" "$WORKSPACE_SETTINGS"

print_default "✓ 言語リマインダーフックを登録しました（.claude/settings.json）"

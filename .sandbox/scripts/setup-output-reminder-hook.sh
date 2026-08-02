#!/bin/bash
# setup-output-reminder-hook.sh
# Idempotently register the setup-output reminder hook (UserPromptSubmit ->
# .sandbox/hooks/setup-output-reminder.sh) in the workspace's
# .claude/settings.json. Unlike setup-language-hook.sh, this applies
# regardless of locale -- the setup-output content it reproduces is
# technical information, not translated per-locale text.
# ---
# setup-outputリマインダーフック（UserPromptSubmit ->
# .sandbox/hooks/setup-output-reminder.sh）を workspace の
# .claude/settings.json に冪等に登録する。setup-language-hook.shと違い、
# ロケールによらず常に登録する（setup-outputの内容は言語非依存の
# 技術情報のため）。

set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"

# shellcheck source=/dev/null
source "${WORKSPACE_ROOT}/.sandbox/scripts/_startup_common.sh"

WORKSPACE_SETTINGS="$WORKSPACE_ROOT/.claude/settings.json"
HOOK_SCRIPT="$WORKSPACE_ROOT/.sandbox/hooks/setup-output-reminder.sh"
HOOK_COMMAND="bash $HOOK_SCRIPT"

if ! command -v jq &> /dev/null; then
    print_warning "jq が見つからないため、setup-output リマインダーフックの設定をスキップしました。"
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
    print_detail "✓ setup-output リマインダーフックは登録済みです。"
    exit 0
fi

merged=$(jq --arg cmd "$HOOK_COMMAND" '
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [
        {"hooks": [{"type": "command", "command": $cmd, "timeout": 5}]}
    ])
' "$WORKSPACE_SETTINGS")

echo "$merged" | jq '.' > "$WORKSPACE_SETTINGS.tmp" && mv "$WORKSPACE_SETTINGS.tmp" "$WORKSPACE_SETTINGS"

print_default "✓ setup-output リマインダーフックを登録しました（.claude/settings.json）"

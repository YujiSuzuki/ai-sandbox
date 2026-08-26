#!/bin/bash
# setup-language-hook.sh
# Idempotently register the response-language reminder hook
# (UserPromptSubmit -> .sandbox/hooks/language-reminder.sh) in the workspace's
# .claude/settings.json. Registered regardless of locale: the hook itself
# branches on $LANG at call time to remind the AI to stay in Japanese or
# English, since surrounding context (tool output, nested project docs, etc.)
# can pull responses away from the $LANG-derived default in either direction.
# ---
# 応答言語リマインダーフック（UserPromptSubmit ->
# .sandbox/hooks/language-reminder.sh）を workspace の .claude/settings.json
# に冪等に登録する。フック自体が呼び出し時に$LANGを見て日本語/英語のどちらを
# 維持すべきか伝えるため、ロケールによらず登録する -- 周囲のコンテキスト
# （ツール出力・ネストしたプロジェクトのドキュメント等）に引っ張られて
# $LANG由来のデフォルトからずれることは、どちらの方向にも起こりうるため。

set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"

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

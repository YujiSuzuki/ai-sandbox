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

# The hook is registered regardless of locale (see file header), but the
# messages reporting that registration are still user-facing output and
# must follow the same locale switch as startup.sh's MSG_* pattern.
# フック自体はロケールによらず登録するが（ファイル冒頭コメント参照）、
# 登録結果を伝えるメッセージはユーザー向け出力であり、startup.shのMSG_*
# パターンと同様にロケールで切り替える必要がある。
if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    MSG_NO_JQ="jq が見つからないため、setup-output リマインダーフックの設定をスキップしました。"
    MSG_ALREADY_REGISTERED="✓ setup-output リマインダーフックは登録済みです。"
    MSG_REGISTERED="✓ setup-output リマインダーフックを登録しました（.claude/settings.json）"
else
    MSG_NO_JQ="jq not found, skipping setup-output reminder hook configuration."
    MSG_ALREADY_REGISTERED="✓ setup-output reminder hook already registered."
    MSG_REGISTERED="✓ setup-output reminder hook registered (.claude/settings.json)"
fi

WORKSPACE_SETTINGS="$WORKSPACE_ROOT/.claude/settings.json"
HOOK_SCRIPT="$WORKSPACE_ROOT/.sandbox/hooks/setup-output-reminder.sh"
HOOK_COMMAND="bash $HOOK_SCRIPT"

if ! command -v jq &> /dev/null; then
    print_warning "$MSG_NO_JQ"
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
    print_detail "$MSG_ALREADY_REGISTERED"
    exit 0
fi

merged=$(jq --arg cmd "$HOOK_COMMAND" '
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [
        {"hooks": [{"type": "command", "command": $cmd, "timeout": 5}]}
    ])
' "$WORKSPACE_SETTINGS")

echo "$merged" | jq '.' > "$WORKSPACE_SETTINGS.tmp" && mv "$WORKSPACE_SETTINGS.tmp" "$WORKSPACE_SETTINGS"

print_default "$MSG_REGISTERED"

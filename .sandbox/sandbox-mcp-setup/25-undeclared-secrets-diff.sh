#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# @notify: persistent  (see setup-output-reminder.sh -- repeated every turn,
#   separately from the one-shot MANDATORY dump, until the AI marks it
#   resolved or a repeat cap is hit)
# Surface newly-appeared undeclared-secret-like files (see
# .sandbox/scripts/check-undeclared-secrets.sh) as MCP startup context, so
# the AI can proactively flag them instead of the finding sitting unnoticed
# until someone remembers to run the scan by hand. Silent when nothing new
# was found, including the very first run (see check-undeclared-secrets-diff.sh).
#
# sandbox-mcp's runSetupScripts() gives each setup script a 5s budget total
# and discards output on timeout or non-zero exit -- so the timeout below is
# capped well under that (same pattern as 40-hostmcp-host-tools-hint.sh).
# ---
# 新たに現れた未申告のシークレットらしきファイル（.sandbox/scripts/check-undeclared-secrets.sh
# 参照）を、MCP起動時コンテキストとして表示する。誰かが手動でスキャンを実行する
# のを待つのではなく、AIが自発的に指摘できるようにするため。何も新規検出が
# なければ（初回実行時を含め）何も出力しない（check-undeclared-secrets-diff.sh 参照）。
#
# sandbox-mcpのrunSetupScripts()は各セットアップスクリプトに合計5秒のタイム
# アウトを設けており、タイムアウトや異常終了時は出力を握りつぶす仕様のため、
# 下のタイムアウト値はそれより十分短く設定してある（40-hostmcp-host-tools-hint.sh
# と同じパターン）。

WORKSPACE="${WORKSPACE:-/workspace}"
DIFF_SCRIPT="${DIFF_SCRIPT:-$WORKSPACE/.sandbox/scripts/check-undeclared-secrets-diff.sh}"
CHECK_TIMEOUT_SECS="${CHECK_TIMEOUT_SECS:-3}"

[ -x "$DIFF_SCRIPT" ] || exit 0

timeout "$CHECK_TIMEOUT_SECS" "$DIFF_SCRIPT"

exit 0

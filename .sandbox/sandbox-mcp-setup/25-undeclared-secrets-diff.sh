#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# @notify: persistent  (see setup-output-reminder.sh -- repeated every turn,
#   separately from the one-shot MANDATORY dump, until the AI marks it
#   resolved or a repeat cap is hit)
# @confirm-target: .sandbox/.state/check-undeclared-secrets.json  (see
#   setup-output-reminder.sh -- once the AI touches "<name>.resolved" for
#   this notice, its not-yet-confirmed pending file gets merged into here)
# Surface newly-appeared undeclared-secret-like files (see
# .sandbox/scripts/check-undeclared-secrets.sh) as MCP startup context, so
# the AI can proactively flag them instead of the finding sitting unnoticed
# until someone remembers to run the scan by hand. Silent when nothing new
# was found, including the very first run (see check-undeclared-secrets-diff.py).
#
# check-undeclared-secrets-diff.py never confirms a finding on detection --
# it mirrors not-yet-confirmed findings into a PENDING_FILE, which we point
# at this session's own spill directory (named after $PPID, sandbox-mcp's
# own PID, since this script is exec'd directly as its child -- see
# runSetupScripts() in mainte/sandbox-mcp/internal/server/server.go). This
# keeps not-yet-confirmed candidates scoped to this session: if several
# sandbox-mcp connections are alive at once (e.g. multiple VS Code windows
# on the same workspace), one session's promotion (see @confirm-target
# above and setup-output-reminder.sh, which also merges rather than
# overwrites to stay correct regardless of resolution order across
# sessions) always reads only its own candidates, never another session's.
#
# sandbox-mcp's runSetupScripts() gives each setup script a 5s budget total
# and discards output on timeout or non-zero exit -- so the timeout below is
# capped well under that (same pattern as 40-hostmcp-host-tools-hint.sh).
# ---
# 新たに現れた未申告のシークレットらしきファイル（.sandbox/scripts/check-undeclared-secrets.sh
# 参照）を、MCP起動時コンテキストとして表示する。誰かが手動でスキャンを実行する
# のを待つのではなく、AIが自発的に指摘できるようにするため。何も新規検出が
# なければ（初回実行時を含め）何も出力しない（check-undeclared-secrets-diff.py 参照）。
#
# check-undeclared-secrets-diff.py は検知した瞬間に何かを確定させることは
# なく、未確定の検知をPENDING_FILEへミラーする。このPENDING_FILEを、
# このセッション自身の退避ディレクトリ（$PPID = sandbox-mcp自身のPIDに
# ちなむ名前 -- 本スクリプトはその子プロセスとして直接execされるため。
# mainte/sandbox-mcp/internal/server/server.go の runSetupScripts() 参照）
# に向けることで、未確定の候補をセッション単位に閉じ込める。同一ワーク
# スペースを開いた複数のVS Codeウィンドウなどで複数のsandbox-mcp接続が
# 同時に生存していても、あるセッションの昇格処理（上の@confirm-target、
# および setup-output-reminder.sh 参照 -- そちらはセッション間の解決
# 順序に関わらず正しく動くよう、上書きではなくマージも行っている）は
# 常に自分自身の候補だけを読み、別セッションのものを読むことはない。
#
# sandbox-mcpのrunSetupScripts()は各セットアップスクリプトに合計5秒のタイム
# アウトを設けており、タイムアウトや異常終了時は出力を握りつぶす仕様のため、
# 下のタイムアウト値はそれより十分短く設定してある（40-hostmcp-host-tools-hint.sh
# と同じパターン）。

WORKSPACE="${WORKSPACE:-/workspace}"
DIFF_SCRIPT="${DIFF_SCRIPT:-$WORKSPACE/.sandbox/scripts/check-undeclared-secrets-diff.py}"
CHECK_TIMEOUT_SECS="${CHECK_TIMEOUT_SECS:-3}"

[ -x "$DIFF_SCRIPT" ] || exit 0

export PENDING_FILE="$WORKSPACE/.sandbox/.state/setup-output/sandbox-mcp-pids/$PPID/25-undeclared-secrets-diff.pending.json"

timeout "$CHECK_TIMEOUT_SECS" "$DIFF_SCRIPT"

exit 0

#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# Hint that .sandbox/host-tools/ scripts exist but are unusable because
# HostMCP is not connected (not registered, or registered but offline).
# Silent when host-tools is empty or HostMCP is already connected.
#
# sandbox-mcp's runSetupScripts() gives each setup script a 5s budget total
# and discards output on timeout or non-zero exit -- so the --check call
# below is capped well under that, and this script always exits 0.
# ---
# .sandbox/host-tools/ にスクリプトはあるのに、HostMCPが未接続（未登録、または
# 登録済みだがオフライン）のせいで使えない、という状況をAIに知らせる。
# host-toolsが空、またはHostMCPが既に接続済みの場合は何も出力しない。
#
# sandbox-mcpのrunSetupScripts()は各セットアップスクリプトに合計5秒のタイム
# アウトを設けており、タイムアウトや異常終了時は出力を握りつぶす仕様のため、
# 下の --check 呼び出しはそれより十分短く設定してあり、このスクリプト自体は
# 常にexit 0で終わる。

WORKSPACE="${WORKSPACE:-/workspace}"
HOSTMCP_CHECK_SCRIPT="${HOSTMCP_CHECK_SCRIPT:-$WORKSPACE/.sandbox/scripts/setup-hostmcp.py}"
HOST_TOOLS_DIR="$WORKSPACE/.sandbox/host-tools"
CHECK_TIMEOUT_SECS="${CHECK_TIMEOUT_SECS:-3}"

# Bash glob expansion sorts matches alphabetically, so tools[0] is a stable,
# deterministic "representative" example, not an arbitrary filesystem order.
# Bashのglob展開はマッチ結果をアルファベット順に並べるため、tools[0]はファイル
# システムの並び順に依存しない、安定した「代表例」として使える。
shopt -s nullglob
tools=("$HOST_TOOLS_DIR"/*.sh)
shopt -u nullglob

[ "${#tools[@]}" -eq 0 ] && exit 0
[ -x "$HOSTMCP_CHECK_SCRIPT" ] || exit 0

timeout "$CHECK_TIMEOUT_SECS" "$HOSTMCP_CHECK_SCRIPT" --check
status=$?

case "$status" in
    1|2|124)
        # 1=not registered, 2=registered but offline, 124=timed out (e.g. a
        # stuck VS Code port forward) -- all three mean host-tools can't be
        # used via run_host_tool right now, so the hint applies to all.
        # 1=未登録、2=登録済みだがオフライン、124=タイムアウト（VS Codeのポート
        # フォワードが詰まっている場合など）-- いずれもrun_host_toolでhost-tools
        # を使えない状態なので、ヒントはこの3つ全てに適用する。
        echo "HostMCP is not connected: .sandbox/host-tools/ has ${#tools[@]} script(s) (e.g. $(basename "${tools[0]}")) that require it to run. Run .sandbox/scripts/setup-hostmcp.py, and make sure \`hostmcp serve\` is running on the host OS."
        ;;
    *)
        # 0=connected, or any unexpected code -- stay silent rather than
        # guess at an unknown state.
        # 0=接続済み、またはそれ以外の未知のコード -- 不明な状態を推測するより
        # 何も出力しない方が安全。
        ;;
esac

exit 0

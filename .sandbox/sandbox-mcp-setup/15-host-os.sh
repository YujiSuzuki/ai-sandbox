#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# Tell the AI the host OS/arch, so it knows what environment host-side
# scripts (.sandbox/host-setup/, install-hostmcp.sh) actually run under.
# Silent if .host-os hasn't been written yet (init-host-env.sh not run on the host).
# ---
# ホスト側のスクリプト（.sandbox/host-setup/、install-hostmcp.sh）が実際にどの
# 環境で動くのか分かるよう、AIにホストのOS/アーキテクチャを伝える。
# .host-osがまだ書き込まれていない場合（ホストでinit-host-env.sh未実行）は何も出力しない。

WORKSPACE="${WORKSPACE:-/workspace}"
HOST_OS_FILE="$WORKSPACE/.sandbox/.host-os"

if [ -f "$HOST_OS_FILE" ]; then
    { read -r os; read -r arch; } < "$HOST_OS_FILE"
    [ -n "$os" ] && echo "Host OS: ${os}${arch:+/$arch}"
fi

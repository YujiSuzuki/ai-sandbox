#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# Show sandbox environment type so AI knows which environment it's running in
# ---
# AIが自分がどの環境で動いているか分かるよう、サンドボックス環境の種類を表示する

[ -n "$SANDBOX_ENV" ] && echo "Sandbox environment: $SANDBOX_ENV"

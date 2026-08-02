#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# Show sandbox environment type so AI knows which environment it's running in

[ -n "$SANDBOX_ENV" ] && echo "Sandbox environment: $SANDBOX_ENV"

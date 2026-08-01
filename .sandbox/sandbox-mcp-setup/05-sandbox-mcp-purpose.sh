#!/bin/bash
# Self-describe SandboxMCP's role vs HostMCP, and how it builds this very
# context block, via the MCP `instructions` field -- so any MCP client
# (not just Claude Code) learns this without reading CLAUDE.md.

echo "SandboxMCP (this server): runs inside the container via stdio, auto-started by the client, for script/tool discovery -- list_scripts/get_script_info/run_script and list_tools/get_tool_info/run_tool. HostMCP: runs on the host OS via SSE/HTTP, started manually (\`hostmcp serve\`), for container/host access via mcp__hostmcp__* tools (see its own instructions once connected)."
echo "This context block itself is auto-built at startup: SandboxMCP runs every script in .sandbox/sandbox-mcp-setup/ (alphabetically) and appends each script's stdout here -- this line comes from 05-sandbox-mcp-purpose.sh. Add your own numbered script there to inject project-specific startup context, the same way .sandbox/scripts/ and .sandbox/tools/ let you extend what run_script/run_tool can execute."

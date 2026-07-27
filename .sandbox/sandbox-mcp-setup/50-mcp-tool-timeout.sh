#!/bin/bash
# Report the AI's own MCP tool-call timeout so it doesn't have to guess.
# Claude Code applies a per-request timer to HTTP/SSE-based MCP servers
# (HostMCP is one) independently of anything the server itself is configured
# with; MCP_TOOL_TIMEOUT (milliseconds) overrides that timer, which otherwise
# defaults to 60s.

if [[ "$MCP_TOOL_TIMEOUT" =~ ^[0-9]+$ ]]; then
    timeout_sec=$(( 10#$MCP_TOOL_TIMEOUT / 1000 ))
    echo "MCP tool-call timeout: ${timeout_sec}s (MCP_TOOL_TIMEOUT=${MCP_TOOL_TIMEOUT}ms). A host tool whose declared @timeout (see get_host_tool_info) exceeds this will appear to fail via run_host_tool even though it may still succeed on the host OS -- for those, use \`hostmcp client ... --timeout <seconds>\` via a backgrounded Bash call instead, or pass client_timeout_seconds=${timeout_sec} to run_host_tool (required whenever the tool's own timeout exceeds HostMCP's global default, so the server can refuse upfront rather than run it only for you to give up before the result arrives)."
elif [[ -n "$MCP_TOOL_TIMEOUT" ]]; then
    echo "MCP tool-call timeout: 60s default (MCP_TOOL_TIMEOUT is set to an invalid value '${MCP_TOOL_TIMEOUT}' -- expected an integer number of milliseconds). A host tool whose declared @timeout (see get_host_tool_info) exceeds 60s will appear to fail via run_host_tool even though it may still succeed on the host OS -- for those, use \`hostmcp client ... --timeout <seconds>\` via a backgrounded Bash call instead, or fix MCP_TOOL_TIMEOUT. Pass client_timeout_seconds=60 to run_host_tool for tools whose own timeout exceeds HostMCP's global default (required so the server can refuse upfront rather than run it only for you to give up before the result arrives)."
else
    echo "MCP tool-call timeout: 60s default (MCP_TOOL_TIMEOUT is unset). A host tool whose declared @timeout (see get_host_tool_info) exceeds 60s will appear to fail via run_host_tool even though it may still succeed on the host OS -- for those, use \`hostmcp client ... --timeout <seconds>\` via a backgrounded Bash call instead, or raise MCP_TOOL_TIMEOUT. Pass client_timeout_seconds=60 to run_host_tool for tools whose own timeout exceeds HostMCP's global default (required so the server can refuse upfront rather than run it only for you to give up before the result arrives)."
fi

#!/bin/bash
# Hint that .sandbox/host-tools/ scripts exist but are unusable because
# HostMCP is not connected (not registered, or registered but offline).
# Silent when host-tools is empty or HostMCP is already connected.
#
# sandbox-mcp's runSetupScripts() gives each setup script a 5s budget total
# and discards output on timeout or non-zero exit -- so the --check call
# below is capped well under that, and this script always exits 0.

WORKSPACE="${WORKSPACE:-/workspace}"
HOSTMCP_CHECK_SCRIPT="${HOSTMCP_CHECK_SCRIPT:-$WORKSPACE/.sandbox/scripts/setup-hostmcp.sh}"
HOST_TOOLS_DIR="$WORKSPACE/.sandbox/host-tools"
CHECK_TIMEOUT_SECS="${CHECK_TIMEOUT_SECS:-3}"

# Bash glob expansion sorts matches alphabetically, so tools[0] is a stable,
# deterministic "representative" example, not an arbitrary filesystem order.
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
        echo "HostMCP is not connected: .sandbox/host-tools/ has ${#tools[@]} script(s) (e.g. $(basename "${tools[0]}")) that require it to run. Run .sandbox/scripts/setup-hostmcp.sh, and make sure \`hostmcp serve\` is running on the host OS."
        ;;
    *)
        # 0=connected, or any unexpected code -- stay silent rather than
        # guess at an unknown state.
        ;;
esac

exit 0

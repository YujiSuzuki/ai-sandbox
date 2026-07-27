#!/bin/bash
# Tell the AI the host OS/arch, so it knows what environment host-side
# scripts (.sandbox/host-setup/, install-hostmcp.sh) actually run under.
# Silent if .host-os hasn't been written yet (init-host-env.sh not run on the host).

WORKSPACE="${WORKSPACE:-/workspace}"
HOST_OS_FILE="$WORKSPACE/.sandbox/.host-os"

if [ -f "$HOST_OS_FILE" ]; then
    { read -r os; read -r arch; } < "$HOST_OS_FILE"
    [ -n "$os" ] && echo "Host OS: ${os}${arch:+/$arch}"
fi

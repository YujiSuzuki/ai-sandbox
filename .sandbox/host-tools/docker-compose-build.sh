#!/bin/bash
# docker-compose-build.sh
# @timeout: 300
# Build images defined in a docker-compose file (host OS execution).
#
# Some images (e.g. a Rust build compiling from scratch) take well over the
# default 60s host-tools timeout, hence the @timeout override above.
#
# Note: @timeout only raises the host-side kill timer. Calling this via MCP's
#   run_host_tool has its own separate 60s default wait and may still report
#   an apparent failure on a slow build. Pass client_timeout_seconds to
#   run_host_tool, or fall back to `hostmcp client --timeout 300 ...` via
#   Bash — see README.md and xcode-test.sh's header for the two-layer
#   explanation and a worked example.
#
# Usage:
#   docker-compose-build.sh <compose-file> [-- <extra docker compose args>]
#
# Examples:
#   docker-compose-build.sh /path/to/docker-compose.yml
#   docker-compose-build.sh ./docker-compose.yml -- --no-cache
#
# Command-line usage example (client-side --timeout must match @timeout above)
# hostmcp client --timeout 300 --url http://host.docker.internal:18080 host-tools run docker-compose-build.sh -- /path/to/docker-compose.yml
# ---
# 指定した docker-compose ファイルのイメージをホスト OS 上でビルドする汎用スクリプトです。
#
# 注: @timeout はホスト側の強制終了タイマーを延ばすだけです。MCP の
#   run_host_tool 経由の呼び出しは別レイヤーで既定60秒の待機時間を持ち、
#   ビルドが遅い場合は失敗したように見えることがあります。run_host_tool に
#   client_timeout_seconds を渡すか、Bash経由で
#   `hostmcp client --timeout 300 ...` にフォールバックしてください
#   （二層構造の詳細と実例は README.md と xcode-test.sh のヘッダーを参照）。

set -e

# .project (written by `hostmcp tools sync`) holds this project's workspace
# root on the host OS. It lets a caller pass a workspace-relative path (the
# only kind visible from inside the container) instead of a host absolute path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_META="${SCRIPT_DIR}/.project"
WORKSPACE_DIR=""
if [ -f "$PROJECT_META" ]; then
    if ! WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null); then
        echo "Warning: failed to parse ${PROJECT_META} (is jq installed and the file valid JSON?)" >&2
        WORKSPACE_DIR=""
    fi
fi

COMPOSE_FILE="$1"
shift || true

if [ -z "$COMPOSE_FILE" ]; then
    echo "Error: compose file not found: <none>" >&2
    echo "Usage: docker-compose-build.sh <compose-file> [-- <extra docker compose args>]" >&2
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ] && [[ "$COMPOSE_FILE" != /* ]] && [ -n "$WORKSPACE_DIR" ] && [ -f "${WORKSPACE_DIR}/${COMPOSE_FILE}" ]; then
    COMPOSE_FILE="${WORKSPACE_DIR}/${COMPOSE_FILE}"
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: compose file not found: ${COMPOSE_FILE}" >&2
    if [ -z "$WORKSPACE_DIR" ]; then
        echo "  (.project not found — run 'hostmcp tools sync' on the host OS, or pass a host-absolute path)" >&2
    fi
    echo "Usage: docker-compose-build.sh <compose-file> [-- <extra docker compose args>]" >&2
    exit 1
fi

echo "Building images..."
echo "  Compose file: $COMPOSE_FILE"
docker compose -f "$COMPOSE_FILE" build "$@"

echo ""
echo "Build complete. Images:"
docker compose -f "$COMPOSE_FILE" images

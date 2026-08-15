#!/bin/bash
# docker-compose-down.sh
# Stop containers defined in a docker-compose file (host OS execution).
#
# Usage:
#   docker-compose-down.sh <compose-file> [-- <extra docker compose args>]
#
# Examples:
#   docker-compose-down.sh /path/to/docker-compose.yml
#   docker-compose-down.sh ./docker-compose.yml -- --volumes
# ---
# 指定した docker-compose ファイルのコンテナをホスト OS 上で停止する汎用スクリプトです。

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
    echo "Usage: docker-compose-down.sh <compose-file> [-- <extra docker compose args>]" >&2
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
    echo "Usage: docker-compose-down.sh <compose-file> [-- <extra docker compose args>]" >&2
    exit 1
fi

echo "Stopping containers..."
echo "  Compose file: $COMPOSE_FILE"
docker compose -f "$COMPOSE_FILE" down "$@"

echo ""
echo "Containers stopped."

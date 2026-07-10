#!/bin/bash
# docker-compose-down.sh
# Stop containers defined in a docker-compose file (host OS execution).
# Generic version of the sample workflow in ai-sandbox-demo/.sandbox/host-tools/demo-down.sh.
#
# Usage:
#   docker-compose-down.sh <compose-file> [-- <extra docker compose args>]
#
# Examples:
#   docker-compose-down.sh /path/to/docker-compose.yml
#   docker-compose-down.sh ./docker-compose.yml -- --volumes
# ---
# 指定した docker-compose ファイルのコンテナをホスト OS 上で停止する汎用スクリプトです。
# ai-sandbox-demo/.sandbox/host-tools/demo-down.sh を汎用化したサンプルです。

set -e

COMPOSE_FILE="$1"
shift || true

if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: compose file not found: ${COMPOSE_FILE:-<none>}" >&2
    echo "Usage: docker-compose-down.sh <compose-file> [-- <extra docker compose args>]" >&2
    exit 1
fi

echo "Stopping containers..."
echo "  Compose file: $COMPOSE_FILE"
docker compose -f "$COMPOSE_FILE" down "$@"

echo ""
echo "Containers stopped."

#!/bin/bash
# docker-compose-up.sh
# Start containers defined in a docker-compose file (host OS execution).
# Generic version of the sample workflow in ai-sandbox-demo/.sandbox/host-tools/demo-up.sh.
#
# Usage:
#   docker-compose-up.sh <compose-file> [-- <extra docker compose args>]
#
# Examples:
#   docker-compose-up.sh /path/to/docker-compose.yml
#   docker-compose-up.sh ./docker-compose.yml -- --build
# ---
# 指定した docker-compose ファイルのコンテナをホスト OS 上で起動する汎用スクリプトです。
# ai-sandbox-demo/.sandbox/host-tools/demo-up.sh を汎用化したサンプルです。

set -e

COMPOSE_FILE="$1"
shift || true

if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: compose file not found: ${COMPOSE_FILE:-<none>}" >&2
    echo "Usage: docker-compose-up.sh <compose-file> [-- <extra docker compose args>]" >&2
    exit 1
fi

echo "Starting containers..."
echo "  Compose file: $COMPOSE_FILE"
docker compose -f "$COMPOSE_FILE" up -d "$@"

echo ""
echo "Status:"
docker compose -f "$COMPOSE_FILE" ps

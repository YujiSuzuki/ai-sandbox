#!/bin/bash
# docker-compose-build.sh
# Build images defined in a docker-compose file (host OS execution).
# Generic version of the sample workflow in ai-sandbox-demo/.sandbox/host-tools/demo-build.sh.
#
# Usage:
#   docker-compose-build.sh <compose-file> [-- <extra docker compose args>]
#
# Examples:
#   docker-compose-build.sh /path/to/docker-compose.yml
#   docker-compose-build.sh ./docker-compose.yml -- --no-cache
# ---
# 指定した docker-compose ファイルのイメージをホスト OS 上でビルドする汎用スクリプトです。
# ai-sandbox-demo/.sandbox/host-tools/demo-build.sh を汎用化したサンプルです。

set -e

COMPOSE_FILE="$1"
shift || true

if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: compose file not found: ${COMPOSE_FILE:-<none>}" >&2
    echo "Usage: docker-compose-build.sh <compose-file> [-- <extra docker compose args>]" >&2
    exit 1
fi

echo "Building images..."
echo "  Compose file: $COMPOSE_FILE"
docker compose -f "$COMPOSE_FILE" build "$@"

echo ""
echo "Build complete. Images:"
docker compose -f "$COMPOSE_FILE" images

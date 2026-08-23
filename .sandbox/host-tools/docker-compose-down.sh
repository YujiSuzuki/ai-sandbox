#!/bin/bash
# docker-compose-down.sh
# Stop containers defined in a docker-compose file (host OS execution).
#
# Usage:
#   docker-compose-down.sh <compose-file> [-- <extra docker compose args>]
#
# Destructive flags (-v/--volumes, --rmi) are rejected -- this script only
# stops/removes containers, never volumes or images. Run docker compose
# manually on the host OS if you really need those.
#
# Examples:
#   docker-compose-down.sh /path/to/docker-compose.yml
#   docker-compose-down.sh ./docker-compose.yml -- --remove-orphans
# ---
# 指定した docker-compose ファイルのコンテナをホスト OS 上で停止する汎用スクリプトです。
#
# 破壊的なフラグ（-v/--volumes, --rmi）は拒否します -- このスクリプトはコンテナの
# 停止/削除のみを行い、ボリュームやイメージは削除しません。本当に必要な場合は
# ホスト OS 上で docker compose を直接実行してください。

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

# Reject destructive flags regardless of "--" placement -- volumes/images
# hold data or build state that this stop-only tool must not be able to erase.
#
# Short options are matched by substring ("-*v*"), not exact "-v", because
# `docker compose` (pflag) lets boolean shorthands bundle with a following
# value-taking shorthand, e.g. "-vt5" == "-v -t 5". An exact "-v" match would
# let that bundled form slip through and still delete volumes.
for arg in "$@"; do
    case "$arg" in
        --volumes*|--rmi*)
            echo "Error: destructive flag '${arg}' is not allowed by this script." >&2
            echo "This script only stops/removes containers -- it never touches volumes or images." >&2
            echo "Run 'docker compose down' manually on the host OS if you really need '${arg}'." >&2
            exit 1
            ;;
        --*)
            ;;
        -*v*)
            echo "Error: destructive flag '${arg}' (bundles -v/--volumes) is not allowed by this script." >&2
            echo "This script only stops/removes containers -- it never touches volumes or images." >&2
            echo "Run 'docker compose down' manually on the host OS if you really need '${arg}'." >&2
            exit 1
            ;;
    esac
done

echo "Stopping containers..."
echo "  Compose file: $COMPOSE_FILE"
docker compose -f "$COMPOSE_FILE" down "$@"

echo ""
echo "Containers stopped."

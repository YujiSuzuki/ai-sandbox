#!/bin/bash
# docker-compose-config.sh
# Validate and render the merged config of one or more docker-compose files
# (host OS execution). Read-only: this only parses/merges the YAML — it does
# not build images, start containers, or make any changes.
#
# Usage:
#   docker-compose-config.sh <compose-file> [<compose-file2> ...] [-- <extra docker compose args>]
#
# Examples:
#   docker-compose-config.sh /path/to/docker-compose.yml
#   docker-compose-config.sh ./docker-compose.yml ./docker-compose.override.yml
#   docker-compose-config.sh ./docker-compose.yml -- --services
# ---
# 指定した1つ以上の docker-compose ファイルをマージした結果をホストOS上で
# 検証・表示する読み取り専用スクリプトです。YAMLのパース・マージのみを行い、
# イメージのビルドやコンテナの起動など、変更は一切行いません。

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

resolve_path() {
    local f="$1"
    if [ ! -f "$f" ] && [[ "$f" != /* ]] && [ -n "$WORKSPACE_DIR" ] && [ -f "${WORKSPACE_DIR}/${f}" ]; then
        f="${WORKSPACE_DIR}/${f}"
    fi
    echo "$f"
}

COMPOSE_FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --)
            shift
            break
            ;;
        *)
            COMPOSE_FILES+=("$1")
            shift
            ;;
    esac
done

if [ ${#COMPOSE_FILES[@]} -eq 0 ]; then
    echo "Error: no compose file specified" >&2
    echo "Usage: docker-compose-config.sh <compose-file> [<compose-file2> ...] [-- <extra docker compose args>]" >&2
    exit 1
fi

ARGS=()
for f in "${COMPOSE_FILES[@]}"; do
    resolved=$(resolve_path "$f")
    if [ ! -f "$resolved" ]; then
        echo "Error: compose file not found: ${f}" >&2
        if [ -z "$WORKSPACE_DIR" ]; then
            echo "  (.project not found — run 'hostmcp tools sync' on the host OS, or pass a host-absolute path)" >&2
        fi
        echo "Usage: docker-compose-config.sh <compose-file> [<compose-file2> ...] [-- <extra docker compose args>]" >&2
        exit 1
    fi
    ARGS+=(-f "$resolved")
done

echo "Validating merged compose config (read-only, no containers/images touched):"
for f in "${COMPOSE_FILES[@]}"; do
    echo "  - $f"
done
echo ""

docker compose "${ARGS[@]}" config "$@"

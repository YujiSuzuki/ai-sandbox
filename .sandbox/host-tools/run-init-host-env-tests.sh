#!/bin/bash
# run-init-host-env-tests.sh
# .sandbox/host-setup/test-init-host-env.sh をホスト OS 上で実行する。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# test-init-host-env.sh は実ネットワーク・実 go/curl・実シェル設定ファイルを
# 必要とするため AI Sandbox コンテナ内では実行できない（スクリプト自身が
# /workspace の存在をチェックしてガードしている）。このラッパーは
# HostMCP 経由でホスト OS 上に実行を委譲するためのもの。
#
# Usage:
#   ./run-init-host-env-tests.sh
#   ./run-init-host-env-tests.sh --workspace <path>
#
# Options:
#   --workspace <path>   ワークスペースルートパス（.project で自動取得できない場合）
#   --help, -h           このヘルプを表示
#
# コマンドラインからの使用例
# hostmcp client --url http://host.docker.internal:18080 host-tools run run-init-host-env-tests.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# .project (HostMCP sync で自動生成される JSON) からワークスペースパスを取得
PROJECT_META="${SCRIPT_DIR}/.project"
WORKSPACE_DIR=""
if [ -f "$PROJECT_META" ]; then
    WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null)
fi

show_help() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace)
            [[ $# -lt 2 ]] && { error "--workspace requires an argument"; exit 1; }
            WORKSPACE_DIR="$2"; shift 2 ;;
        --help|-h)
            show_help ;;
        *)
            error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$WORKSPACE_DIR" ]; then
    error "ワークスペースパスを特定できません。"
    error ".project ファイルが存在するか確認するか、--workspace <path> で指定してください。"
    exit 1
fi

TEST_SCRIPT="${WORKSPACE_DIR}/.sandbox/host-setup/test-init-host-env.sh"
if [ ! -f "$TEST_SCRIPT" ]; then
    error "テストスクリプトが見つかりません: $TEST_SCRIPT"
    exit 1
fi

info "Running: $TEST_SCRIPT"
bash "$TEST_SCRIPT"

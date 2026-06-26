#!/bin/bash
# xcode-build.sh
# Xcode ビルドをホスト OS（macOS）上で実行する（テスト不要の構文チェック用）。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# Usage:
#   ./xcode-build.sh [options]
#
# Options:
#   --project <path>         .xcodeproj のパス（未指定時は WORKSPACE_DIR 内を自動検出）
#   --scheme <scheme>        Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --destination <dest>     xcodebuild destination（デフォルト: iOS Simulator, 最新 iPhone）
#   --workspace <path>       ワークスペースルートパス（.project で自動取得できない場合）
#   --help, -h               このヘルプを表示
#
# Examples:
#   ./xcode-build.sh
#   ./xcode-build.sh --project /path/to/MyApp.xcodeproj
#   ./xcode-build.sh --scheme MyApp

set -euo pipefail

# ────────────────────────────────────────────
# カラー出力
# ────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "${BLUE}=== $* ===${NC}"; }

# ────────────────────────────────────────────
# デフォルト値
# ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_META="${SCRIPT_DIR}/.project"
WORKSPACE_DIR=""
if [ -f "$PROJECT_META" ]; then
    WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null)
fi

XCODEPROJ=""
SCHEME=""
DESTINATION=""

# ────────────────────────────────────────────
# 引数パース
# ────────────────────────────────────────────
show_help() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            [[ $# -lt 2 ]] && { error "--project requires an argument"; exit 1; }
            XCODEPROJ="$2"; shift 2 ;;
        --scheme)
            [[ $# -lt 2 ]] && { error "--scheme requires an argument"; exit 1; }
            SCHEME="$2"; shift 2 ;;
        --destination)
            [[ $# -lt 2 ]] && { error "--destination requires an argument"; exit 1; }
            DESTINATION="$2"; shift 2 ;;
        --workspace)
            [[ $# -lt 2 ]] && { error "--workspace requires an argument"; exit 1; }
            WORKSPACE_DIR="$2"; shift 2 ;;
        --help|-h)
            show_help ;;
        *)
            error "Unknown option: $1"; exit 1 ;;
    esac
done

# ワークスペースパスの確定
if [ -z "$WORKSPACE_DIR" ]; then
    error "ワークスペースパスを特定できません。"
    error ".project ファイルが存在するか確認するか、--workspace <path> で指定してください。"
    exit 1
fi

# .xcodeproj の解決（未指定時は自動検出）
if [ -z "$XCODEPROJ" ]; then
    XCODEPROJ_LIST=$(find "$WORKSPACE_DIR" -maxdepth 2 -name "*.xcodeproj" -type d 2>/dev/null)
    XCODEPROJ_COUNT=$(echo "$XCODEPROJ_LIST" | grep -c . 2>/dev/null || true)
    if [ "$XCODEPROJ_COUNT" -eq 0 ]; then
        error ".xcodeproj が見つかりません（WORKSPACE_DIR 2階層以内を検索）: ${WORKSPACE_DIR}"
        error "--project で明示指定してください。"
        exit 1
    elif [ "$XCODEPROJ_COUNT" -gt 1 ]; then
        error "複数の .xcodeproj が見つかりました。--project で明示指定してください:"
        echo "$XCODEPROJ_LIST" >&2
        exit 1
    fi
    XCODEPROJ=$(echo "$XCODEPROJ_LIST" | head -1)
fi

# SCHEME の自動導出（.xcodeproj のベース名から）
if [ -z "$SCHEME" ]; then
    SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
fi

# ────────────────────────────────────────────
# 事前チェック
# ────────────────────────────────────────────
if ! command -v xcodebuild &>/dev/null; then
    error "xcodebuild が見つかりません。Xcode がインストールされているか確認してください。"
    exit 1
fi

if [ ! -d "$XCODEPROJ" ]; then
    error "Xcode プロジェクトが見つかりません: ${XCODEPROJ}"
    exit 1
fi

XCODE_VERSION=$(set +o pipefail; xcodebuild -version 2>/dev/null | head -1 || echo "unknown")
info "使用 Xcode: ${XCODE_VERSION}"

# destination が未指定の場合、最新 iOS の iPhone シミュレーターを自動選択
if [ -z "$DESTINATION" ]; then
    SIM_ID=$(xcrun simctl list devices available -j 2>/dev/null | jq -r '
        .devices
        | to_entries
        | map(select(.key | test("com.apple.CoreSimulator.SimRuntime.iOS")))
        | sort_by(.key) | reverse
        | .[0].value
        | map(select(.name | test("^iPhone")))
        | .[0].udid // ""
    ' 2>/dev/null || true)
    if [ -n "$SIM_ID" ] && [ "$SIM_ID" != "null" ]; then
        DESTINATION="platform=iOS Simulator,id=${SIM_ID}"
        info "シミュレーター自動選択: ${SIM_ID}"
    else
        DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=18.6"
        warn "シミュレーター自動選択失敗。フォールバック: ${DESTINATION}"
    fi
fi

# ────────────────────────────────────────────
# xcodebuild コマンド組み立て
# ────────────────────────────────────────────
header "Xcode ビルド実行"
echo "  プロジェクト : ${XCODEPROJ}"
echo "  スキーム     : ${SCHEME}"
echo "  destination  : ${DESTINATION}"
echo ""

CMD=(
    xcodebuild build
    -project "${XCODEPROJ}"
    -scheme "${SCHEME}"
    -destination "${DESTINATION}"
)

# ────────────────────────────────────────────
# ビルド実行
# ────────────────────────────────────────────
LOG_FILE="${WORKSPACE_DIR}/tmp/xcode-build-last.log"
mkdir -p "${WORKSPACE_DIR}/tmp"
info "ログ保存先: ${LOG_FILE}"
info "xcodebuild 実行中（完了まで数分かかります）..."

set +e
"${CMD[@]}" > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

# ────────────────────────────────────────────
# 結果表示
# ────────────────────────────────────────────
ERROR_SUMMARY="${WORKSPACE_DIR}/tmp/xcode-build-errors.txt"
mkdir -p "$(dirname "$ERROR_SUMMARY")"

set +o pipefail
if [ $EXIT_CODE -eq 0 ]; then
    header "ビルド成功"
    {
        echo "BUILD SUCCEEDED"
        grep -E "warning:" "$LOG_FILE" | head -10
    } > "$ERROR_SUMMARY" 2>/dev/null || true
    info "BUILD SUCCEEDED"
    info "サマリー: ${ERROR_SUMMARY}"
else
    header "ビルド失敗"
    # エラー行を抽出してファイルに保存（コンテナからも読める）
    {
        echo "BUILD FAILED (exit code: ${EXIT_CODE})"
        echo "--- エラー一覧 ---"
        grep -E "error:" "$LOG_FILE" | head -60
    } > "$ERROR_SUMMARY" 2>/dev/null || true
    # 標準出力には先頭20行だけ表示
    head -20 "$ERROR_SUMMARY" 2>/dev/null || true
    echo ""
    error "BUILD FAILED (exit code: ${EXIT_CODE})"
    error "エラーサマリー: ${ERROR_SUMMARY}"
fi
set -o pipefail

exit $EXIT_CODE

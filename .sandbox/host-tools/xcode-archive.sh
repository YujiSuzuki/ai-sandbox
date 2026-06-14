#!/bin/bash
# xcode-archive.sh
# Xcode アーカイブをホスト OS（macOS）上で実行する。
# 生成した .xcarchive は Xcode Organizer（Window → Organizer）で開いて
# 「Distribute App」ボタンから TestFlight / App Store にアップロードできる。
# DockMCP の run_host_tool 経由でコンテナから呼び出す。
#
# Usage:
#   ./xcode-archive.sh [options]
#
# Options:
#   --project <path>         .xcodeproj のパス（未指定時は WORKSPACE_DIR 内を自動検出）
#   --scheme <scheme>        Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --archive-path <path>    .xcarchive の出力先（デフォルト: ~/Library/Developer/Xcode/Archives/<date>/<Scheme> <date>.xcarchive）
#   --workspace <path>       ワークスペースルートパス（.project で自動取得できない場合）
#   --help, -h               このヘルプを表示
#
# 完了後:
#   Xcode の Window → Organizer を開くとアーカイブが表示される。
#   「Distribute App」→「TestFlight & App Store」→「Upload」でアップロードできる。
#
# Examples:
#   ./xcode-archive.sh
#   ./xcode-archive.sh --archive-path ~/Desktop/MyApp.xcarchive

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
ARCHIVE_PATH=""
ARCHIVE_DATE=$(date "+%Y-%m-%d")

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
        --archive-path)
            [[ $# -lt 2 ]] && { error "--archive-path requires an argument"; exit 1; }
            ARCHIVE_PATH="$2"; shift 2 ;;
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

# ARCHIVE_PATH の自動導出（Xcode Organizer が拾える標準パス）
if [ -z "$ARCHIVE_PATH" ]; then
    ARCHIVE_PATH="${HOME}/Library/Developer/Xcode/Archives/${ARCHIVE_DATE}/${SCHEME} ${ARCHIVE_DATE}.xcarchive"
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

# 既存アーカイブを削除（xcodebuild は上書き不可）
if [ -e "$ARCHIVE_PATH" ]; then
    rm -rf "$ARCHIVE_PATH"
    info "既存アーカイブを削除: ${ARCHIVE_PATH}"
fi

# ────────────────────────────────────────────
# xcodebuild コマンド組み立て
# ────────────────────────────────────────────
header "Xcode アーカイブ実行"
echo "  プロジェクト    : ${XCODEPROJ}"
echo "  スキーム        : ${SCHEME}"
echo "  設定            : Release"
echo "  アーカイブ出力  : ${ARCHIVE_PATH}"
echo ""

CMD=(
    xcodebuild archive
    -project "${XCODEPROJ}"
    -scheme "${SCHEME}"
    -configuration Release
    -archivePath "${ARCHIVE_PATH}"
    -allowProvisioningUpdates
    CODE_SIGN_STYLE=Automatic
)

# ────────────────────────────────────────────
# アーカイブ実行
# ────────────────────────────────────────────
LOG_FILE="/tmp/xcode-archive-last.log"
info "ログ保存先: ${LOG_FILE}"
info "xcodebuild 実行中（完了まで数分かかります）..."

set +e
"${CMD[@]}" > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

# ────────────────────────────────────────────
# 結果表示
# ────────────────────────────────────────────
echo ""
if [ $EXIT_CODE -eq 0 ]; then
    header "アーカイブ成功"
    info "✅ ARCHIVE SUCCEEDED"
    info "アーカイブ: ${ARCHIVE_PATH}"
    echo ""
    echo -e "${GREEN}次のステップ:${NC}"
    echo "  Xcode の Window → Organizer を開くと"
    echo "  「${ARCHIVE_PATH}」が表示されます。"
    echo "  「Distribute App」→「TestFlight & App Store」→「Upload」"
    echo "  でアップロードしてください。"
else
    header "アーカイブ失敗"
    echo -e "${RED}❌ ARCHIVE FAILED (exit code: ${EXIT_CODE})${NC}"
    echo ""
    echo "--- エラー一覧 ---"
    grep -E "error:" "$LOG_FILE" 2>/dev/null | head -40 || true
    echo ""
    error "詳細ログ: ${LOG_FILE}"
fi

exit $EXIT_CODE

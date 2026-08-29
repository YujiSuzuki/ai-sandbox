#!/bin/bash
# xcode-archive.sh
# Archive an Xcode project on the host OS (macOS).
# Open the resulting .xcarchive in Xcode Organizer (Window -> Organizer) and
# use the "Distribute App" button to upload it to TestFlight / App Store.
# Invoked from the container via HostMCP's run_host_tool.
#
# Usage:
#   ./xcode-archive.sh [options]
#
# Options:
#   --project <path>         Path to the .xcodeproj (auto-detected under WORKSPACE_DIR if omitted)
#   --scheme <scheme>        Xcode scheme name (default: the .xcodeproj's base name)
#   --archive-path <path>    Output path for the .xcarchive (default: ~/Library/Developer/Xcode/Archives/<date>/<Scheme> <date>.xcarchive)
#   --help, -h               Show this help
#
# After completion:
#   Open Xcode's Window -> Organizer to see the archive.
#   Use "Distribute App" -> "TestFlight & App Store" -> "Upload" to upload it.
#
# Examples:
#   ./xcode-archive.sh
#   ./xcode-archive.sh --archive-path ~/Desktop/MyApp.xcarchive

# ---
# xcode-archive.sh
# Xcode アーカイブをホスト OS（macOS）上で実行する。
# 生成した .xcarchive は Xcode Organizer（Window → Organizer）で開いて
# 「Distribute App」ボタンから TestFlight / App Store にアップロードできる。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# Usage:
#   ./xcode-archive.sh [options]
#
# Options:
#   --project <path>         .xcodeproj のパス（未指定時は WORKSPACE_DIR 内を自動検出）
#   --scheme <scheme>        Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --archive-path <path>    .xcarchive の出力先（デフォルト: ~/Library/Developer/Xcode/Archives/<date>/<Scheme> <date>.xcarchive）
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
# Color output
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
# Defaults
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
# Argument parsing
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
        --help|-h)
            show_help ;;
        *)
            error "Unknown option: $1"; exit 1 ;;
    esac
done

# Resolve the workspace path
if [ -z "$WORKSPACE_DIR" ]; then
    error "Cannot determine the workspace path."
    error "Check that a .project file exists."
    exit 1
fi

# Resolve .xcodeproj (auto-detect if not specified)
if [ -z "$XCODEPROJ" ]; then
    XCODEPROJ_LIST=$(find "$WORKSPACE_DIR" -maxdepth 2 -name "*.xcodeproj" -type d 2>/dev/null)
    XCODEPROJ_COUNT=$(echo "$XCODEPROJ_LIST" | grep -c . 2>/dev/null || true)
    if [ "$XCODEPROJ_COUNT" -eq 0 ]; then
        error "No .xcodeproj found (searched up to 2 levels under WORKSPACE_DIR): ${WORKSPACE_DIR}"
        error "Specify one explicitly with --project."
        exit 1
    elif [ "$XCODEPROJ_COUNT" -gt 1 ]; then
        error "Multiple .xcodeproj found. Specify one explicitly with --project:"
        echo "$XCODEPROJ_LIST" >&2
        exit 1
    fi
    XCODEPROJ=$(echo "$XCODEPROJ_LIST" | head -1)
fi

# Auto-derive SCHEME (from the .xcodeproj's base name)
if [ -z "$SCHEME" ]; then
    SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
fi

# Auto-derive ARCHIVE_PATH (standard path that Xcode Organizer picks up)
if [ -z "$ARCHIVE_PATH" ]; then
    ARCHIVE_PATH="${HOME}/Library/Developer/Xcode/Archives/${ARCHIVE_DATE}/${SCHEME} ${ARCHIVE_DATE}.xcarchive"
fi

# ────────────────────────────────────────────
# Preflight checks
# ────────────────────────────────────────────
if ! command -v xcodebuild &>/dev/null; then
    error "xcodebuild not found. Check that Xcode is installed."
    exit 1
fi

if [ ! -d "$XCODEPROJ" ]; then
    error "Xcode project not found: ${XCODEPROJ}"
    exit 1
fi

XCODE_VERSION=$(set +o pipefail; xcodebuild -version 2>/dev/null | head -1 || echo "unknown")
info "Xcode version: ${XCODE_VERSION}"

# Remove any existing archive (xcodebuild can't overwrite one in place)
if [ -e "$ARCHIVE_PATH" ]; then
    rm -rf "$ARCHIVE_PATH"
    info "Removed existing archive: ${ARCHIVE_PATH}"
fi

# ────────────────────────────────────────────
# Build the xcodebuild command
# ────────────────────────────────────────────
header "Running Xcode archive"
echo "  Project       : ${XCODEPROJ}"
echo "  Scheme        : ${SCHEME}"
echo "  Configuration : Release"
echo "  Archive output: ${ARCHIVE_PATH}"
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
# Run archive
# ────────────────────────────────────────────
LOG_FILE="/tmp/xcode-archive-last.log"
info "Log: ${LOG_FILE}"
info "Running xcodebuild (this can take a few minutes)..."

set +e
"${CMD[@]}" > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

# ────────────────────────────────────────────
# Show results
# ────────────────────────────────────────────
echo ""
if [ $EXIT_CODE -eq 0 ]; then
    header "Archive succeeded"
    info "✅ ARCHIVE SUCCEEDED"
    info "Archive: ${ARCHIVE_PATH}"
    echo ""
    echo -e "${GREEN}Next steps:${NC}"
    echo "  Open Xcode's Window → Organizer and you'll see"
    echo "  \"${ARCHIVE_PATH}\" listed there."
    echo "  Use \"Distribute App\" → \"TestFlight & App Store\" → \"Upload\""
    echo "  to upload it."
else
    header "Archive failed"
    echo -e "${RED}❌ ARCHIVE FAILED (exit code: ${EXIT_CODE})${NC}"
    echo ""
    echo "--- Errors ---"
    grep -E "error:" "$LOG_FILE" 2>/dev/null | head -40 || true
    echo ""
    error "Full log: ${LOG_FILE}"
fi

exit $EXIT_CODE

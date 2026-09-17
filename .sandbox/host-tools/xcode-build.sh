#!/bin/bash
# xcode-build.sh
# Build an Xcode project on the host OS (macOS) (for syntax checking, no tests).
# Invoked from the container via HostMCP's run_host_tool.
#
# Usage:
#   ./xcode-build.sh [options]
#
# Options:
#   --project <path>         Path to the .xcodeproj. Absolute, or relative to WORKSPACE_DIR
#                             (auto-detected under WORKSPACE_DIR if omitted, but only up to
#                             2 levels deep -- pass this explicitly for a project nested
#                             deeper, e.g. inside a sub-repo's own ios/ subdirectory)
#   --scheme <scheme>        Xcode scheme name (default: the .xcodeproj's base name)
#   --destination <dest>     xcodebuild destination (default: iOS Simulator, latest iPhone)
#   --clean                  Run `xcodebuild clean build` instead of a plain incremental
#                             build. Use this when you suspect xcodebuild is reusing stale
#                             build products instead of picking up a source change -- e.g.
#                             a symptom like "CoreData: warning: Multiple NSEntityDescriptions
#                             claim the NSManagedObject subclass ..." in the output, or a
#                             build that finishes suspiciously fast with no compile steps in
#                             the log even after editing a file. Takes noticeably longer
#                             (a full rebuild, not incremental).
#   --help, -h               Show this help
#
# Examples:
#   ./xcode-build.sh
#   ./xcode-build.sh --project /path/to/MyApp.xcodeproj
#   ./xcode-build.sh --project myapp/ios/MyApp.xcodeproj  # relative to WORKSPACE_DIR; needed
#                                                          # when nested deeper than auto-detect's 2 levels
#   ./xcode-build.sh --scheme MyApp
#   ./xcode-build.sh --clean  # force a full rebuild if stale build products are suspected

# ---
# xcode-build.sh
# Xcode ビルドをホスト OS（macOS）上で実行する（テスト不要の構文チェック用）。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# Usage:
#   ./xcode-build.sh [options]
#
# Options:
#   --project <path>         .xcodeproj のパス。絶対パス、または WORKSPACE_DIR からの相対パス
#                             （未指定時は WORKSPACE_DIR 内を自動検出するが、深さ2階層までしか
#                             探索しない -- サブリポジトリの ios/ 配下など、それより深い場所に
#                             ある場合は明示的に指定すること）
#   --scheme <scheme>        Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --destination <dest>     xcodebuild destination（デフォルト: iOS Simulator, 最新 iPhone）
#   --clean                  素の増分ビルドの代わりに `xcodebuild clean build` を実行する。
#                             ソースの変更をxcodebuildが拾えず古いビルド成果物を使い回して
#                             いる疑いがある時に使う -- 例えば出力に「CoreData: warning:
#                             Multiple NSEntityDescriptions claim the NSManagedObject
#                             subclass ...」のような症状が出ている、ファイルを編集した
#                             はずなのにログにコンパイル関連の行が一つもなく不自然に速く
#                             終わる、などのサイン。フルリビルドになるため明確に時間が
#                             長くなる。
#   --help, -h               このヘルプを表示
#
# Examples:
#   ./xcode-build.sh
#   ./xcode-build.sh --project /path/to/MyApp.xcodeproj
#   ./xcode-build.sh --project myapp/ios/MyApp.xcodeproj  # WORKSPACE_DIR からの相対パス。
#                                                          # 自動検出の2階層より深い場合に必要
#   ./xcode-build.sh --scheme MyApp
#   ./xcode-build.sh --clean  # 古いビルド成果物が疑われる時にフルリビルドを強制する

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
DESTINATION=""
CLEAN=false

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
        --destination)
            [[ $# -lt 2 ]] && { error "--destination requires an argument"; exit 1; }
            DESTINATION="$2"; shift 2 ;;
        --clean)
            CLEAN=true; shift ;;
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

# Resolve SCHEME (from the .xcodeproj's base name if not specified)
if [ -z "$SCHEME" ]; then
    SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
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

# Auto-select the latest iOS iPhone simulator if destination is not specified
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
        info "Simulator auto-selected: ${SIM_ID}"
    else
        DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=18.6"
        warn "Simulator auto-selection failed. Falling back to: ${DESTINATION}"
    fi
fi

# ────────────────────────────────────────────
# Build the xcodebuild command
# ────────────────────────────────────────────
header "Running Xcode build"
echo "  Project      : ${XCODEPROJ}"
echo "  Scheme       : ${SCHEME}"
echo "  destination  : ${DESTINATION}"
[ "$CLEAN" = "true" ] && echo "  Clean        : yes (full rebuild)"
echo ""

CMD=(xcodebuild)
[ "$CLEAN" = "true" ] && CMD+=(clean)
CMD+=(
    build
    -project "${XCODEPROJ}"
    -scheme "${SCHEME}"
    -destination "${DESTINATION}"
)

# ────────────────────────────────────────────
# Run build
# ────────────────────────────────────────────
LOG_FILE="${WORKSPACE_DIR}/tmp/xcode-build-last.log"
mkdir -p "${WORKSPACE_DIR}/tmp"
info "Log: ${LOG_FILE}"
info "Running xcodebuild (this can take a few minutes)..."

set +e
"${CMD[@]}" > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

# ────────────────────────────────────────────
# Show results
# ────────────────────────────────────────────
ERROR_SUMMARY="${WORKSPACE_DIR}/tmp/xcode-build-errors.txt"
mkdir -p "$(dirname "$ERROR_SUMMARY")"

set +o pipefail
if [ $EXIT_CODE -eq 0 ]; then
    header "Build succeeded"
    {
        echo "BUILD SUCCEEDED"
        grep -E "warning:" "$LOG_FILE" | head -10
    } > "$ERROR_SUMMARY" 2>/dev/null || true
    info "BUILD SUCCEEDED"
    info "Summary: ${ERROR_SUMMARY}"
else
    header "Build failed"
    # Extract error lines and save to a file (readable from the container too)
    {
        echo "BUILD FAILED (exit code: ${EXIT_CODE})"
        echo "--- Errors ---"
        grep -E "error:" "$LOG_FILE" | head -60
    } > "$ERROR_SUMMARY" 2>/dev/null || true
    # Show only the first 20 lines on stdout
    head -20 "$ERROR_SUMMARY" 2>/dev/null || true
    echo ""
    error "BUILD FAILED (exit code: ${EXIT_CODE})"
    error "Error summary: ${ERROR_SUMMARY}"
fi
set -o pipefail

exit $EXIT_CODE

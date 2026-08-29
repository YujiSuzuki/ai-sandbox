#!/bin/bash
# xcode-install-app.sh
# Build a macOS app and copy it from DerivedData's random hash path into a
# known, fixed directory (default: ~/.hostmcp/Applications).
# Lets the container always find the build product at the same path.
# Invoked from the container via HostMCP's run_host_tool.
#
# Usage:
#   ./xcode-install-app.sh [options]
#
# Options:
#   --project <path>         Path to the .xcodeproj (auto-detected under WORKSPACE_DIR if omitted)
#   --scheme <scheme>        Xcode scheme name (default: the .xcodeproj's base name)
#   --configuration <cfg>    Build configuration (default: Debug)
#   --dest-dir <path>        Install destination directory (default: ~/.hostmcp/Applications)
#   --help, -h               Show this help
#
# Examples:
#   ./xcode-install-app.sh --project AirDropStatus/AirDropStatus.xcodeproj
#   ./xcode-install-app.sh --scheme AirDropStatus --dest-dir ~/.hostmcp/Applications

# ---
# xcode-install-app.sh
# macOS アプリをビルドし、DerivedData 配下のランダムなハッシュパスから
# 既知の固定ディレクトリ（デフォルト: ~/.hostmcp/Applications）へコピーする。
# コンテナ側からは常に同じパスでビルド成果物を参照できるようにするためのツール。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# Usage:
#   ./xcode-install-app.sh [options]
#
# Options:
#   --project <path>         .xcodeproj のパス（未指定時は WORKSPACE_DIR 内を自動検出）
#   --scheme <scheme>        Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --configuration <cfg>    ビルド構成（デフォルト: Debug）
#   --dest-dir <path>        インストール先ディレクトリ（デフォルト: ~/.hostmcp/Applications）
#   --help, -h               このヘルプを表示
#
# Examples:
#   ./xcode-install-app.sh --project AirDropStatus/AirDropStatus.xcodeproj
#   ./xcode-install-app.sh --scheme AirDropStatus --dest-dir ~/.hostmcp/Applications

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
# Path validation helper
# ────────────────────────────────────────────
# HostMCP doesn't validate arguments once a Host Tool is approved, so this
# check is the only line of defense confirming that a target path (e.g. for
# rm -rf) stays within the expected range.
require_within() {
    local target="$1" base="$2" label="$3"
    local resolved_base resolved_target
    resolved_base="$(cd "$base" 2>/dev/null && pwd -P)" || { error "${label}: cannot resolve base directory: ${base}"; exit 1; }
    resolved_target="$(cd "$target" 2>/dev/null && pwd -P)" || { error "${label}: cannot resolve path: ${target}"; exit 1; }
    case "$resolved_target" in
        "$resolved_base"|"$resolved_base"/*) ;;
        *)
            error "${label} is outside the allowed range: ${target}"
            error "Allowed range: under ${resolved_base} only"
            exit 1
            ;;
    esac
}

# ────────────────────────────────────────────
# Defaults
# ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_META="${SCRIPT_DIR}/.project"
WORKSPACE_DIR=""
if [ -f "$PROJECT_META" ]; then
    # Without `|| WORKSPACE_DIR=""`, a malformed .project (broken JSON) makes jq
    # exit non-zero, and set -e would abort silently here before reaching the
    # friendlier error message further down.
    WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null) || WORKSPACE_DIR=""
fi

XCODEPROJ=""
SCHEME=""
CONFIGURATION="Debug"
DEST_DIR="${HOME}/.hostmcp/Applications"

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
        --configuration)
            [[ $# -lt 2 ]] && { error "--configuration requires an argument"; exit 1; }
            CONFIGURATION="$2"; shift 2 ;;
        --dest-dir)
            [[ $# -lt 2 ]] && { error "--dest-dir requires an argument"; exit 1; }
            DEST_DIR="$2"; shift 2 ;;
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

# Derive SCHEME automatically from the .xcodeproj's base name, if not specified
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

# Allowing --project to point at an unrelated project elsewhere on the host
# would permit arbitrary code execution via its Build Phases, so require it
# to stay under WORKSPACE_DIR.
require_within "$XCODEPROJ" "$WORKSPACE_DIR" "--project"

XCODE_VERSION=$(set +o pipefail; xcodebuild -version 2>/dev/null | head -1 || echo "unknown")
info "Using Xcode: ${XCODE_VERSION}"

DESTINATION="platform=macOS"

# ────────────────────────────────────────────
# Run build
# ────────────────────────────────────────────
header "Running Xcode build"
echo "  Project       : ${XCODEPROJ}"
echo "  Scheme        : ${SCHEME}"
echo "  Configuration : ${CONFIGURATION}"
echo "  destination   : ${DESTINATION}"
echo ""

LOG_FILE="${WORKSPACE_DIR}/tmp/xcode-install-app-last.log"
mkdir -p "${WORKSPACE_DIR}/tmp"
info "Log: ${LOG_FILE}"
info "Running xcodebuild (this can take a few minutes)..."

set +e
xcodebuild build \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
    header "Build failed"
    grep -E "error:" "$LOG_FILE" | head -60 || true
    error "BUILD FAILED (exit code: ${EXIT_CODE})"
    error "Log: ${LOG_FILE}"
    exit $EXIT_CODE
fi
info "BUILD SUCCEEDED"

# ────────────────────────────────────────────
# Resolve the build product path
# ────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    error "jq not found."
    exit 1
fi

SETTINGS_ERR_FILE="${WORKSPACE_DIR}/tmp/xcode-install-app-settings-err.log"

set +e
SETTINGS_JSON=$(xcodebuild -showBuildSettings -json \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" 2>"$SETTINGS_ERR_FILE")
SETTINGS_EXIT=$?
set -e

if [ $SETTINGS_EXIT -ne 0 ]; then
    error "Failed to fetch build settings (exit code: ${SETTINGS_EXIT})."
    tail -20 "$SETTINGS_ERR_FILE" >&2 2>/dev/null || true
    exit $SETTINGS_EXIT
fi

# -showBuildSettings -json returns entries for every target the scheme builds
# (main app plus any embedded extensions/widgets/frameworks), so naively using
# the first entry can pick up settings from something other than the main app.
# Prefer the target whose name matches SCHEME, falling back to the first entry
# if there's no match.
TARGET_SETTINGS=$(echo "$SETTINGS_JSON" | jq -c --arg t "$SCHEME" \
    '([.[] | select(.target == $t)] + .)[0].buildSettings // {}')

BUILT_PRODUCTS_DIR=$(echo "$TARGET_SETTINGS" | jq -r '.BUILT_PRODUCTS_DIR // empty')
WRAPPER_NAME=$(echo "$TARGET_SETTINGS" | jq -r '.WRAPPER_NAME // empty')

if [ -z "$BUILT_PRODUCTS_DIR" ] || [ -z "$WRAPPER_NAME" ]; then
    error "Could not determine the build product path (BUILT_PRODUCTS_DIR/WRAPPER_NAME)."
    exit 1
fi

# WRAPPER_NAME gets joined with DEST_DIR below to build the copy destination
# path. Using a build-settings-derived value directly in path construction
# would let a value containing "/" or ".." write outside the destination
# directory, so require it to be a single file/directory name. "." alone is
# also rejected: allowing it would make DEST_APP equal DEST_DIR itself, and
# the rsync --delete right after would wipe out everything under DEST_DIR.
case "$WRAPPER_NAME" in
    */*|*..*|.)
        error "Invalid build product name (WRAPPER_NAME): ${WRAPPER_NAME}"
        exit 1
        ;;
esac

SRC_APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
if [ ! -d "$SRC_APP" ]; then
    error "Build product not found: ${SRC_APP}"
    exit 1
fi

# ────────────────────────────────────────────
# Copy to the fixed directory
# ────────────────────────────────────────────
header "Installing"
# require_within needs `cd` to resolve, so it can't be used on a directory
# that doesn't exist yet. Reject anything outside $HOME at the string level
# before mkdir -p creates it. String matching doesn't normalize the path, so
# a value containing ".." (e.g. "$HOME/../../tmp/evil") would still match the
# "$HOME"/* pattern as-is -- explicitly reject ".." before mkdir -p to guard
# against that.
case "$DEST_DIR" in
    *..*)
        error "--dest-dir must not contain '..': ${DEST_DIR}"
        exit 1
        ;;
esac
case "$DEST_DIR" in
    "$HOME"|"$HOME"/*) ;;
    *)
        error "--dest-dir is outside the allowed range: ${DEST_DIR}"
        error "Allowed range: under ${HOME} only"
        exit 1
        ;;
esac
# If a symlink is planted somewhere under $DEST_DIR, mkdir -p itself would
# follow it and create a directory outside $HOME (a side effect that
# require_within can't catch after the fact, since it only runs once the
# directory already exists). To guard against that, validate the nearest
# existing ancestor directory with require_within first, then mkdir -p ($HOME
# itself always exists, so this loop is guaranteed to terminate).
EXISTING_ANCESTOR="$DEST_DIR"
while [ ! -d "$EXISTING_ANCESTOR" ]; do
    EXISTING_ANCESTOR="$(dirname "$EXISTING_ANCESTOR")"
done
require_within "$EXISTING_ANCESTOR" "$HOME" "--dest-dir"
mkdir -p "$DEST_DIR"
# Passing --dest-dir to rsync / open unvalidated would allow writing to
# arbitrary paths, so require it to stay under $HOME (final check, after
# creation).
require_within "$DEST_DIR" "$HOME" "--dest-dir"
DEST_APP="${DEST_DIR}/${WRAPPER_NAME}"
# Even if DEST_DIR itself is under $HOME, if DEST_APP (rsync's actual write
# target) is a symlink, rsync --delete would follow it and delete the
# contents of whatever it points to -- something validating DEST_DIR alone
# can't catch. The WRAPPER_NAME string check above only rejects path
# separators and "..", not what actually exists at that name, so check for a
# symlink separately here.
if [ -L "$DEST_APP" ]; then
    error "Destination already exists as a symlink: ${DEST_APP}"
    error "Refusing to install over a symlink for safety. Remove it manually and re-run."
    exit 1
fi

info "Source: ${SRC_APP}"
info "Destination: ${DEST_APP}"

# --delete removes anything at the destination that isn't in the source, so
# the destination always ends up matching the new build exactly. Plain cp
# can leave old and new files mixed together (if the destination directory
# already exists, cp -R nests the copy inside it, and copying with a trailing
# dot to overwrite in place still leaves behind files the new build doesn't
# have).
if ! command -v rsync &>/dev/null; then
    error "rsync not found."
    exit 1
fi
rsync -a --delete "${SRC_APP}/" "${DEST_APP}/"

info "Install complete: ${DEST_APP}"
info "To launch it manually: open \"${DEST_APP}\""

exit 0

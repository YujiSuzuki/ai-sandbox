#!/bin/bash
# @timeout: 600
# xcode-simulator-screenshot.sh
# Build an iOS app, install + launch it on a Simulator, and capture a
# screenshot to a path under WORKSPACE_DIR so it can be read from the
# container (the shared workspace mount is the only channel back to the AI;
# there is no other way to see what's on the host's screen).
# Invoked from the container via HostMCP's run_host_tool.
#
# --ui-test mode drives the app to a screen beyond its launch screen: it runs
# one XCUITest method (which navigates and captures its own screenshot via
# XCTAttachment) through `xcodebuild test`, then extracts that attachment via
# xcresulttool instead of using simctl directly. See docs/ai-guide.md's
# "XCUITest Screenshot Automation" section for the convention a target app's
# UI test target/method should follow.
#
# ---
# xcode-simulator-screenshot.sh
# iOSアプリをビルドし、シミュレータにインストール・起動した上でスクリーンショットを撮り、
# WORKSPACE_DIR配下のパスに保存する（共有ワークスペースのマウントだけが、AIに結果を
# 見せられる唯一の経路。ホストの画面を他の方法で見る手段は無い）。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# --ui-testモードは、起動画面より先の画面までアプリを導く: 自分自身で
# XCTAttachmentによりスクリーンショットを撮る1つのXCUITestメソッドを
# `xcodebuild test`経由で実行し、xcresulttoolでその添付を取り出す
# （simctlを直接使う代わりに）。対象アプリのUIテストターゲット/メソッドが
# 従うべき型については docs/ai-guide.md の「XCUITest Screenshot Automation」
# 節を参照。
#
# Usage:
#   ./xcode-simulator-screenshot.sh [options]
#
# Options:
#   --project <path>      Path to the .xcodeproj (auto-detected under WORKSPACE_DIR if omitted)
#   --scheme <scheme>     Xcode scheme name (default: the .xcodeproj's base name)
#   --output <path>       Screenshot output path, relative to WORKSPACE_DIR (default: tmp/simulator-screenshot.png)
#   --wait <seconds>      Seconds to wait after launch before capturing (default: 3, ignored in --ui-test mode)
#   --ui-test <Target>/<Class>/<method>
#                          Run this XCUITest method instead of the default simctl
#                          install/launch/screenshot flow, and extract its
#                          XCTAttachment screenshot via xcresulttool
#   --help, -h            Show this help
#
# Examples:
#   ./xcode-simulator-screenshot.sh
#   ./xcode-simulator-screenshot.sh --scheme MyApp --output tmp/home.png
#   ./xcode-simulator-screenshot.sh --scheme MyApp --ui-test "MyAppUITests/MyAppUITests/testSettingsScreenshot" --output tmp/settings.png

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
# check is the only line of defense confirming that the output path stays
# within WORKSPACE_DIR.
require_within() {
    local target="$1" base="$2" label="$3"
    local resolved_base resolved_target
    resolved_base="$(cd "$base" 2>/dev/null && pwd -P)" || { error "${label}: cannot resolve base directory: ${base}"; exit 1; }
    resolved_target="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || { error "${label}: cannot resolve path: ${target}"; exit 1; }
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
    WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null) || WORKSPACE_DIR=""
fi

XCODEPROJ=""
SCHEME=""
OUTPUT_REL="tmp/simulator-screenshot.png"
WAIT_SECONDS=3
UI_TEST=""

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
        --output)
            [[ $# -lt 2 ]] && { error "--output requires an argument"; exit 1; }
            OUTPUT_REL="$2"; shift 2 ;;
        --wait)
            [[ $# -lt 2 ]] && { error "--wait requires an argument"; exit 1; }
            WAIT_SECONDS="$2"; shift 2 ;;
        --ui-test)
            [[ $# -lt 2 ]] && { error "--ui-test requires an argument"; exit 1; }
            UI_TEST="$2"; shift 2 ;;
        --help|-h)
            show_help ;;
        *)
            error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$WORKSPACE_DIR" ]; then
    error "Cannot determine the workspace path."
    error "Check that a .project file exists."
    exit 1
fi

# Restrict --output to a relative path so it can't escape WORKSPACE_DIR via "..".
case "$OUTPUT_REL" in
    /*|*..*)
        error "--output must be a path relative to WORKSPACE_DIR ('..' and absolute paths are not allowed): ${OUTPUT_REL}"
        exit 1
        ;;
esac
OUTPUT_PATH="${WORKSPACE_DIR}/${OUTPUT_REL}"

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

# require_within needs `cd` to resolve, so it can't be used on a directory that
# doesn't exist yet. To avoid mkdir -p escaping WORKSPACE_DIR via a symlink,
# validate the nearest existing ancestor with require_within first, then
# mkdir -p, then validate the output path itself again (same procedure as
# xcode-install-app.sh).
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
EXISTING_ANCESTOR="$OUTPUT_DIR"
while [ ! -d "$EXISTING_ANCESTOR" ]; do
    EXISTING_ANCESTOR="$(dirname "$EXISTING_ANCESTOR")"
done
require_within "${EXISTING_ANCESTOR}/." "$WORKSPACE_DIR" "--output"
mkdir -p "$OUTPUT_DIR"
require_within "$OUTPUT_PATH" "$WORKSPACE_DIR" "--output"

if [ -z "$SCHEME" ]; then
    SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
fi

# --scheme shouldn't contain path separators, but --ui-test mode concatenates
# it directly into RESULT_BUNDLE/EXPORT_DIR paths that are then passed to
# rm -rf, so reject path traversal here the same way --output does.
case "$SCHEME" in
    */*|*..*)
        error "--scheme must not contain path separators or '..': ${SCHEME}"
        exit 1
        ;;
esac

# --ui-test accepts a bare xcodebuild -only-testing identifier, which also allows
# Target or Target/Class (no method) -- but the code downstream assumes exactly
# one test method runs, so require the full 3-part form here.
if [ -n "$UI_TEST" ]; then
    UI_TEST_SLASHES=$(awk -F/ '{print NF-1}' <<< "$UI_TEST")
    UI_TEST_HAS_EMPTY_PART=$(awk -F/ '{for(i=1;i<=NF;i++) if($i=="") print "empty"}' <<< "$UI_TEST")
    if [ "$UI_TEST_SLASHES" != "2" ] || [ -n "$UI_TEST_HAS_EMPTY_PART" ]; then
        error "--ui-test must fully specify all 3 levels of <Target>/<Class>/<method> (to narrow the run to one test method): ${UI_TEST}"
        exit 1
    fi
fi

# ────────────────────────────────────────────
# Preflight checks
# ────────────────────────────────────────────
for bin in xcodebuild xcrun jq; do
    if ! command -v "$bin" &>/dev/null; then
        error "${bin} not found."
        exit 1
    fi
done

if [ ! -d "$XCODEPROJ" ]; then
    error "Xcode project not found: ${XCODEPROJ}"
    exit 1
fi

# ────────────────────────────────────────────
# Pick a simulator (same selection logic as xcode-build.sh)
# ────────────────────────────────────────────
SIM_ID=$(xcrun simctl list devices available -j 2>/dev/null | jq -r '
    .devices
    | to_entries
    | map(select(.key | test("com.apple.CoreSimulator.SimRuntime.iOS")))
    | sort_by(.key) | reverse
    | .[0].value
    | map(select(.name | test("^iPhone")))
    | .[0].udid // ""
' 2>/dev/null || true)

if [ -z "$SIM_ID" ] || [ "$SIM_ID" = "null" ]; then
    error "No available iOS simulator found."
    exit 1
fi
info "Simulator: ${SIM_ID}"
DESTINATION="platform=iOS Simulator,id=${SIM_ID}"

# ────────────────────────────────────────────
# --ui-test mode: run one XCUITest method and extract its screenshot
# attachment via xcresulttool, instead of the simctl-based flow below.
# ────────────────────────────────────────────
if [ -n "$UI_TEST" ]; then
    header "Running XCUITest (${UI_TEST})"
    TMP_DIR="${WORKSPACE_DIR}/.sandbox/tmp"
    RESULT_BUNDLE="${TMP_DIR}/${SCHEME}-ui-test-screenshot.xcresult"
    LOG_FILE="${TMP_DIR}/xcode-simulator-screenshot-ui-test.log"
    EXPORT_DIR="${TMP_DIR}/${SCHEME}-ui-test-attachments"
    mkdir -p "$TMP_DIR"
    [ -e "$RESULT_BUNDLE" ] && rm -rf "$RESULT_BUNDLE"
    rm -rf "$EXPORT_DIR"

    CMD=(
        xcodebuild test
        -project "${XCODEPROJ}"
        -scheme "${SCHEME}"
        -destination "${DESTINATION}"
        -parallel-testing-enabled NO
        -maximum-concurrent-test-simulator-destinations 1
        -resultBundlePath "${RESULT_BUNDLE}"
        -only-testing "${UI_TEST}"
    )

    info "Log: ${LOG_FILE}"
    info "Running xcodebuild (this can take a few minutes)..."
    set +e
    "${CMD[@]}" > "$LOG_FILE" 2>&1
    EXIT_CODE=$?
    set -e

    if [ "$EXIT_CODE" -ne 0 ]; then
        error "UI TEST FAILED (exit code: ${EXIT_CODE})"
        xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" 2>/dev/null | jq -r '
            def walk_nodes:
                .[]? | if .nodeType == "Test Case" then "  " + .result + " " + .name
                       else (.children? // [] | walk_nodes) end;
            .testNodes | walk_nodes' 2>/dev/null || true
        error "Full log: ${LOG_FILE}"
        exit "$EXIT_CODE"
    fi
    info "UI TEST PASSED"

    mkdir -p "$EXPORT_DIR"
    # UI_TEST was validated above to be a full Target/Class/Method identifier,
    # which narrows the run to exactly one test method -- but a test can still
    # attach more than one screenshot (e.g. a test plan with automatic
    # per-step screenshots), so the PNG count below is checked explicitly
    # rather than assumed.
    if ! xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$EXPORT_DIR" > "${LOG_FILE}.export" 2>&1; then
        error "xcresulttool export attachments failed. Details: ${LOG_FILE}.export"
        exit 1
    fi

    PNG_COUNT=$(find "$EXPORT_DIR" -iname "*.png" | wc -l | tr -d ' ')
    if [ "$PNG_COUNT" -eq 0 ]; then
        error "No screenshot attachment found (check that the test sets attachment.lifetime = .keepAlways): ${EXPORT_DIR}"
        exit 1
    elif [ "$PNG_COUNT" -gt 1 ]; then
        error "Found multiple screenshot attachments (${PNG_COUNT}). Cannot tell which one to use. Make sure the test method captures exactly one screenshot: ${EXPORT_DIR}"
        exit 1
    fi
    EXPORTED_PNG=$(find "$EXPORT_DIR" -iname "*.png" | head -1)

    cp "$EXPORTED_PNG" "$OUTPUT_PATH"
    info "Screenshot saved to: ${OUTPUT_PATH}"
    exit 0
fi

# ────────────────────────────────────────────
# Build
# ────────────────────────────────────────────
header "Running Xcode build"
LOG_FILE="${WORKSPACE_DIR}/tmp/xcode-simulator-screenshot-build.log"
mkdir -p "${WORKSPACE_DIR}/tmp"
info "Log: ${LOG_FILE}"

set +e
xcodebuild build \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -destination "${DESTINATION}" \
    > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
    error "BUILD FAILED (exit code: ${EXIT_CODE})"
    grep -E "error:" "$LOG_FILE" | head -40 || true
    exit $EXIT_CODE
fi
info "BUILD SUCCEEDED"

# ────────────────────────────────────────────
# Resolve build product & bundle id
# ────────────────────────────────────────────
SETTINGS_JSON=$(xcodebuild -showBuildSettings -json \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -destination "${DESTINATION}" 2>/dev/null)

TARGET_SETTINGS=$(echo "$SETTINGS_JSON" | jq -c --arg t "$SCHEME" \
    '([.[] | select(.target == $t)] + .)[0].buildSettings // {}')

BUILT_PRODUCTS_DIR=$(echo "$TARGET_SETTINGS" | jq -r '.BUILT_PRODUCTS_DIR // empty')
WRAPPER_NAME=$(echo "$TARGET_SETTINGS" | jq -r '.WRAPPER_NAME // empty')
BUNDLE_ID=$(echo "$TARGET_SETTINGS" | jq -r '.PRODUCT_BUNDLE_IDENTIFIER // empty')

if [ -z "$BUILT_PRODUCTS_DIR" ] || [ -z "$WRAPPER_NAME" ] || [ -z "$BUNDLE_ID" ]; then
    error "Could not determine build product / bundle ID."
    exit 1
fi

APP_PATH="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
if [ ! -d "$APP_PATH" ]; then
    error "Build product not found: ${APP_PATH}"
    exit 1
fi

# ────────────────────────────────────────────
# Boot, install, launch, capture
# ────────────────────────────────────────────
header "Launching on simulator and capturing"
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1 || true
xcrun simctl install "$SIM_ID" "$APP_PATH"
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" >/dev/null

info "Waiting ${WAIT_SECONDS}s for rendering..."
sleep "$WAIT_SECONDS"

xcrun simctl io "$SIM_ID" screenshot "$OUTPUT_PATH"

info "Screenshot saved to: ${OUTPUT_PATH}"
exit 0

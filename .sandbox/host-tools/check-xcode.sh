#!/bin/bash
# check-xcode.sh
# Read-only check of whether Xcode is installed and usable on the host OS.
# Makes no changes -- reports current status and next steps.
#
# Usage:
#   ./check-xcode.sh
#
# Examples:
#   ./check-xcode.sh
# ---
# ホストOS上でXcodeがインストールされ使用可能な状態か確認する、
# 読み取り専用の診断スクリプト。設定変更は一切行わない。

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

header() { echo -e "${BLUE}=== $* ===${NC}"; }
ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()   { echo -e "${RED}[NG]${NC} $*"; }

header "Host OS"
OS="$(uname -s)"
ARCH="$(uname -m)"
echo "  OS: $OS ($ARCH)"

if [ "$OS" != "Darwin" ]; then
    warn "Xcode requires macOS. This host is '$OS' -- xcode-build.sh, xcode-test.sh,"
    echo "  xcode-archive.sh, xcode-install-app.sh and xcodegen-generate.sh will not work here."
    exit 0
fi

header "Command Line Tools"
if ! command -v xcode-select >/dev/null 2>&1; then
    fail "xcode-select not found (unexpected on macOS)"
    exit 1
fi

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [ -z "$DEV_DIR" ]; then
    fail "No active developer directory (xcode-select -p failed)"
    echo "  Install Xcode from the App Store, or run: xcode-select --install"
    exit 1
fi
echo "  Developer dir: $DEV_DIR"

if echo "$DEV_DIR" | grep -q "CommandLineTools"; then
    warn "Only Command Line Tools are active, not full Xcode."
    echo "  xcodebuild will fail for iOS/simulator builds. Install Xcode from the App"
    echo "  Store, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
else
    ok "Full Xcode is active"
fi

header "xcodebuild"
if ! command -v xcodebuild >/dev/null 2>&1; then
    fail "xcodebuild command not found"
    exit 1
fi

XCODEBUILD_OUT="$(xcodebuild -version 2>&1)"
XCODEBUILD_EXIT=$?
if [ $XCODEBUILD_EXIT -ne 0 ]; then
    fail "xcodebuild -version failed (exit $XCODEBUILD_EXIT)"
    echo "$XCODEBUILD_OUT" | sed 's/^/  /'
    if echo "$XCODEBUILD_OUT" | grep -qi "license"; then
        echo "  -> License not accepted yet. Run: sudo xcodebuild -license"
    fi
    exit 1
fi
ok "xcodebuild is usable"
echo "$XCODEBUILD_OUT" | sed 's/^/  /'

header "iOS Simulator runtimes"
if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found on host PATH -- cannot parse simctl output"
elif ! command -v xcrun >/dev/null 2>&1; then
    fail "xcrun command not found (unexpected on macOS)"
    exit 1
else
    SIM_JSON="$(xcrun simctl list runtimes -j 2>/dev/null || echo '{}')"
    SIM_COUNT="$(echo "$SIM_JSON" | jq '[.runtimes[]? | select(.identifier | test("iOS"))] | length' 2>/dev/null || echo 0)"
    if [ "${SIM_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        ok "$SIM_COUNT iOS runtime(s) installed"
        echo "$SIM_JSON" | jq -r '.runtimes[] | select(.identifier | test("iOS")) | "  - \(.name) (\(.identifier))"' 2>/dev/null
    else
        warn "No iOS simulator runtimes found"
        echo "  Install via Xcode > Settings > Platforms, or: xcodebuild -downloadPlatform iOS"
    fi
fi

exit 0

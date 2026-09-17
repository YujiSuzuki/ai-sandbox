#!/bin/bash
# simulator-app-reset.sh
# Uninstall an app from an iOS Simulator device, and/or reset one of its
# privacy permission grants (notifications, camera, photos, ...), without
# tearing down the whole Simulator like restart-simulator.sh does.
#
# Why this exists: iOS/iPadOS remembers a permission decision (e.g. "Allow"/
# "Don't Allow" on the notification prompt) per bundle ID in the device's
# privacy database, not inside the app's own container. Reinstalling the same
# app via a normal build+install (xcode-build.sh, xcode-test.sh,
# xcode-simulator-screenshot.sh) does NOT clear that decision, so a UI test or
# manual run that needs to see the permission prompt again -- to verify what a
# fresh user actually sees, or to unblock a test stuck on a stale "Don't
# Allow" from an earlier run -- has no way to get back to a clean state
# without this.
#
# Usage:
#   simulator-app-reset.sh --bundle-id <id> [--device <udid>] [--uninstall] [--reset-privacy <service>]
#
#   --bundle-id <id>        Required. The app's bundle identifier
#                             (e.g. com.example.MyApp).
#   --device <udid>          Simulator device UDID. Auto-selects the latest
#                             available iOS iPhone simulator if omitted (same
#                             logic as xcode-build.sh).
#   --uninstall               Remove the app and its container entirely
#                             (`xcrun simctl uninstall`). This also clears
#                             every privacy grant for it, since nothing is
#                             left to hold a decision.
#   --reset-privacy <service> Reset one privacy service's grant for this app
#                             without removing it (`xcrun simctl privacy ...
#                             reset <service> <bundle-id>`). Common values:
#                             notifications, camera, photos, contacts,
#                             location, microphone, calendar, reminders, all.
#
#   At least one of --uninstall / --reset-privacy must be given.
#
# Examples:
#   simulator-app-reset.sh --bundle-id com.example.MyApp --uninstall
#   simulator-app-reset.sh --bundle-id com.example.MyApp --reset-privacy notifications
#   simulator-app-reset.sh --bundle-id com.example.MyApp --uninstall --reset-privacy all
# ---
# iOS シミュレータから対象アプリをアンインストールする、および/または
# 個別のプライバシー権限(通知・カメラ・写真など)の許可状態だけをリセットする
# スクリプトです。restart-simulator.sh のようにシミュレータ全体を巻き込みません。
#
# 存在理由: iOS/iPadOS は通知許可ダイアログの「許可」/「許可しない」といった
# 決定を、アプリのコンテナ内ではなくデバイス側のプライバシーデータベースに
# bundle ID 単位で記憶します。xcode-build.sh・xcode-test.sh・
# xcode-simulator-screenshot.sh による通常のビルド→インストールでは、この
# 決定はクリアされません。フレッシュユーザーが実際に見るダイアログを確認したい
# 場合や、以前の実行で「許可しない」のまま止まってしまったUIテストを復旧したい
# 場合、これをクリーンな状態に戻す手段が他にありませんでした。
#
# 使い方:
#   simulator-app-reset.sh --bundle-id <id> [--device <udid>] [--uninstall] [--reset-privacy <service>]
#
#   --bundle-id <id>        必須。アプリのbundle identifier(例: com.example.MyApp)。
#   --device <udid>          シミュレータデバイスのUDID。省略時はxcode-build.sh
#                             と同じロジックで最新のiPhoneシミュレータを自動選択。
#   --uninstall               アプリとそのコンテナを完全に削除します
#                             (`xcrun simctl uninstall`)。何も残らないため、
#                             このアプリに対する全プライバシー許可もクリア
#                             されます。
#   --reset-privacy <service> アプリを削除せずに、特定のプライバシーサービスの
#                             許可状態だけをリセットします(`xcrun simctl
#                             privacy ... reset <service> <bundle-id>`)。
#                             よく使う値: notifications, camera, photos,
#                             contacts, location, microphone, calendar,
#                             reminders, all。
#
#   --uninstall と --reset-privacy の少なくとも一方を指定する必要があります。
#
# 例:
#   simulator-app-reset.sh --bundle-id com.example.MyApp --uninstall
#   simulator-app-reset.sh --bundle-id com.example.MyApp --reset-privacy notifications
#   simulator-app-reset.sh --bundle-id com.example.MyApp --uninstall --reset-privacy all

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

header() { echo -e "${BLUE}=== $* ===${NC}"; }
info()   { echo -e "${GREEN}[INFO]${NC} $*"; }
ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()   { echo -e "${RED}[NG]${NC} $*"; }

BUNDLE_ID=""
DEVICE=""
DO_UNINSTALL=0
PRIVACY_SERVICE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle-id)
            [ $# -lt 2 ] && { fail "--bundle-id requires an argument"; exit 1; }
            BUNDLE_ID="$2"
            shift 2
            ;;
        --device)
            [ $# -lt 2 ] && { fail "--device requires an argument"; exit 1; }
            DEVICE="$2"
            shift 2
            ;;
        --uninstall)
            DO_UNINSTALL=1
            shift
            ;;
        --reset-privacy)
            [ $# -lt 2 ] && { fail "--reset-privacy requires an argument"; exit 1; }
            PRIVACY_SERVICE="$2"
            shift 2
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            echo "Usage: simulator-app-reset.sh --bundle-id <id> [--device <udid>] [--uninstall] [--reset-privacy <service>]" >&2
            exit 1
            ;;
    esac
done

if [ -z "$BUNDLE_ID" ]; then
    fail "--bundle-id is required."
    exit 1
fi

if [ "$DO_UNINSTALL" -eq 0 ] && [ -z "$PRIVACY_SERVICE" ]; then
    fail "Nothing to do -- pass --uninstall and/or --reset-privacy <service>."
    exit 1
fi

OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    fail "This script requires macOS (xcrun simctl). Host is '$OS'."
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    fail "xcrun not found -- is Xcode / Command Line Tools installed?"
    exit 1
fi

if [ -z "$DEVICE" ]; then
    DEVICE=$(xcrun simctl list devices available -j 2>/dev/null | jq -r '
        .devices
        | to_entries
        | map(select(.key | test("com.apple.CoreSimulator.SimRuntime.iOS")))
        | sort_by(.key) | reverse
        | .[0].value
        | map(select(.name | test("^iPhone")))
        | .[0].udid // ""
    ' 2>/dev/null || true)
    if [ -z "$DEVICE" ] || [ "$DEVICE" = "null" ]; then
        fail "Could not auto-select a Simulator device. Pass --device <udid> explicitly."
        exit 1
    fi
    info "Simulator auto-selected: ${DEVICE}"
fi

header "Impact"
echo "  Target device: ${DEVICE}"
echo "  Target app:    ${BUNDLE_ID}"
if [ "$DO_UNINSTALL" -eq 1 ]; then
    echo "  - Uninstalls the app and deletes its entire container (user data,"
    echo "    UserDefaults, Core Data / SQLite stores, every privacy grant)."
fi
if [ -n "$PRIVACY_SERVICE" ]; then
    echo "  - Resets the '${PRIVACY_SERVICE}' privacy grant for this app back to"
    echo "    \"not determined\" -- the next request shows the system prompt again."
fi
echo "  Risk: low. Scoped to one app on one Simulator device; does not touch"
echo "  the host Mac, other apps, or real device data."
echo "  Recovery: none needed -- reinstalling the app (any build/test/screenshot"
echo "  host tool) recreates its container, and permission prompts simply"
echo "  reappear on next use."
echo ""

if [ "$DO_UNINSTALL" -eq 1 ]; then
    header "Uninstalling ${BUNDLE_ID}"
    if xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" 2>&1; then
        ok "Uninstalled"
    else
        warn "simctl uninstall reported an error (app may not have been installed)"
    fi
fi

if [ -n "$PRIVACY_SERVICE" ]; then
    header "Resetting privacy service '${PRIVACY_SERVICE}'"
    if xcrun simctl privacy "$DEVICE" reset "$PRIVACY_SERVICE" "$BUNDLE_ID" 2>&1; then
        ok "Privacy grant reset"
    else
        fail "simctl privacy reset failed"
        exit 1
    fi
fi

echo ""
ok "Done."

#!/bin/bash
# restart-simulator.sh
# Fully quit and reopen Simulator.app on the host OS, and/or shut down all
# booted Simulator devices via `xcrun simctl shutdown all`. Useful when a
# Simulator gets stuck (frozen UI, stale app state, a device that won't boot)
# and a plain relaunch from Xcode doesn't clear it.
#
# IMPORTANT: Simulator.app and the CoreSimulator daemon are shared across the
# whole host Mac, not scoped to this project -- running this will interrupt
# any Simulator session the developer has open for unrelated work (other
# projects, manual testing, an attached debugger), not just this project's.
#
# By default this does NOT relaunch Simulator.app after quitting it. Reopening
# is only useful for a human watching the screen -- xcode-test.sh
# (`xcodebuild test`) and xcode-simulator-screenshot.sh (`xcrun simctl
# bootstatus -b` + `simctl install`/`launch`) both boot/use the target device
# headlessly regardless of whether Simulator.app's GUI is open, so a
# build/test run right after this script needs no reopen. Pass --reopen when
# you actually want to look at the simulator yourself afterward.
#
# Usage:
#   restart-simulator.sh [--shutdown-only] [--reopen] [--force]
#
#   --shutdown-only  Only run `xcrun simctl shutdown all` (device-level
#                     shutdown). Does not quit Simulator.app.
#   --reopen          Relaunch Simulator.app after quitting it (for visually
#                     inspecting it yourself; not needed before a build/test).
#   --force           Skip the graceful `osascript quit` and go straight to
#                     `killall Simulator`. Use when Simulator.app is frozen
#                     and won't respond to a normal quit request.
#
# Examples:
#   restart-simulator.sh                    # shutdown all devices, quit app (stays closed)
#   restart-simulator.sh --shutdown-only    # just `xcrun simctl shutdown all`
#   restart-simulator.sh --reopen           # quit and relaunch, for manual/visual use
#   restart-simulator.sh --force            # force-kill a frozen Simulator.app
# ---
# ホスト OS 上で Simulator.app を完全終了する、および/または
# `xcrun simctl shutdown all` で起動中の全シミュレータデバイスをシャットダウン
# するスクリプトです。Simulator がフリーズした、アプリの状態が壊れた、デバイス
# が起動しなくなったなど、Xcode からの通常の再起動では直らない場合に使います。
#
# 重要: Simulator.app と CoreSimulator デーモンはホスト Mac 全体で共有されて
# おり、このプロジェクト専用ではありません。実行すると、他プロジェクトでの
# 作業や手動テスト、アタッチ中のデバッガなど、このプロジェクト以外で開いて
# いる Simulator セッションも巻き込んで中断されます。
#
# デフォルトでは終了後に Simulator.app を再起動しません。再起動は人間が画面を
# 見て確認したい場合にのみ意味があり、xcode-test.sh（`xcodebuild test`）や
# xcode-simulator-screenshot.sh（`xcrun simctl bootstatus -b` +
# `simctl install`/`launch`）はどちらも Simulator.app の GUI が開いているかに
# 関わらずヘッドレスに対象デバイスを起動するため、このスクリプトの直後に
# ビルド/テストを走らせるだけなら再起動は不要です。自分の目で確認したい時だけ
# `--reopen` を付けてください。

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

SHUTDOWN_ONLY=0
REOPEN=0
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --shutdown-only) SHUTDOWN_ONLY=1 ;;
        --reopen)         REOPEN=1 ;;
        --force)          FORCE=1 ;;
        *)
            echo "Error: unknown argument '$arg'" >&2
            echo "Usage: restart-simulator.sh [--shutdown-only] [--reopen] [--force]" >&2
            exit 1
            ;;
    esac
done

OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    fail "This script requires macOS (Simulator.app / xcrun simctl). Host is '$OS'."
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    fail "xcrun not found -- is Xcode / Command Line Tools installed?"
    exit 1
fi

header "Impact"
echo "  - Shuts down ALL booted Simulator devices on this host (any project, any app)."
if [ "$SHUTDOWN_ONLY" -eq 0 ]; then
    echo "  - Quits Simulator.app entirely (any open windows/sessions are closed)."
    if [ "$REOPEN" -eq 1 ]; then
        echo "  - Relaunches Simulator.app afterward (no device booted until one is selected)."
    else
        echo "  - Leaves Simulator.app closed (a build/test run boots devices headlessly; pass --reopen to relaunch the GUI)."
    fi
fi
echo "  Risk: low for this project's own state (Simulator devices hold no durable"
echo "  project data), but it interrupts any Simulator use elsewhere on this Mac."
echo "  Recovery: reopen manually via 'open -a Simulator' or from Xcode; devices"
echo "  boot again automatically the next time a build/run targets them."
echo ""

header "Shutting down Simulator devices"
if xcrun simctl shutdown all 2>&1; then
    ok "xcrun simctl shutdown all completed"
else
    warn "xcrun simctl shutdown all reported an error (continuing)"
fi

if [ "$SHUTDOWN_ONLY" -eq 1 ]; then
    echo ""
    ok "Done (--shutdown-only: Simulator.app left untouched)."
    exit 0
fi

header "Quitting Simulator.app"
if ! pgrep -x Simulator >/dev/null 2>&1; then
    ok "Simulator.app was not running"
else
    if [ "$FORCE" -eq 1 ]; then
        killall Simulator 2>/dev/null || true
    else
        osascript -e 'quit app "Simulator"' >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x Simulator >/dev/null 2>&1 || break
            sleep 1
        done
        if pgrep -x Simulator >/dev/null 2>&1; then
            warn "Simulator.app did not quit gracefully within 10s -- force-killing"
            killall Simulator 2>/dev/null || true
            sleep 1
        fi
    fi

    if pgrep -x Simulator >/dev/null 2>&1; then
        fail "Simulator.app is still running after quit attempt"
        exit 1
    fi
    ok "Simulator.app quit"
fi

if [ "$REOPEN" -eq 0 ]; then
    echo ""
    ok "Done (Simulator.app left closed; pass --reopen to relaunch it)."
    exit 0
fi

header "Reopening Simulator.app"
if open -a Simulator; then
    ok "Simulator.app relaunched"
else
    fail "Failed to reopen Simulator.app"
    exit 1
fi

echo ""
ok "Done."

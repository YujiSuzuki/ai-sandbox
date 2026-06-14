#!/bin/bash
# mac-memory.sh
# macOS のメモリ使用状況を表示する。
# DockMCP の run_host_tool 経由でコンテナから呼び出す。
#
# Usage:
#   ./mac-memory.sh [options]
#
# Options:
#   --top N     メモリ使用量上位 N プロセスを表示（デフォルト: 10）
#   --help, -h  このヘルプを表示
#
# Examples:
#   ./mac-memory.sh
#   ./mac-memory.sh --top 5

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

header() { echo -e "${BLUE}=== $* ===${NC}"; }
info()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }

TOP_N=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        --top) TOP_N="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ────────────────────────────────────────────
# メモリプレッシャー（normal / warning / critical）
# ────────────────────────────────────────────
header "メモリプレッシャー"
PRESSURE=$(memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | head -1 || true)
LEVEL=$(memory_pressure 2>/dev/null | grep "The system memory pressure" | head -1 || true)
[ -n "$LEVEL" ]    && echo "  $LEVEL"
[ -n "$PRESSURE" ] && echo "  $PRESSURE"

# ────────────────────────────────────────────
# 物理メモリ合計 / vm_stat
# ────────────────────────────────────────────
header "物理メモリ"
TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
TOTAL_GB=$(echo "scale=1; $TOTAL_BYTES / 1073741824" | bc 2>/dev/null || echo "?")
echo "  搭載RAM: ${TOTAL_GB} GB"
echo ""

# vm_stat でページ情報を取得
PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
VM=$(vm_stat 2>/dev/null)

get_pages() {
    echo "$VM" | grep "$1" | awk '{print $NF}' | tr -d '.'
}

PAGES_FREE=$( get_pages "Pages free")
PAGES_WIRED=$(get_pages "Pages wired down")
PAGES_ACTIVE=$(get_pages "Pages active")
PAGES_INACTIVE=$(get_pages "Pages inactive")
PAGES_COMPRESSED=$(get_pages "Pages stored in compressor")

to_mb() {
    local pages="${1:-0}"
    echo $(( pages * PAGE_SIZE / 1048576 ))
}

FREE_MB=$(to_mb "$PAGES_FREE")
WIRED_MB=$(to_mb "$PAGES_WIRED")
ACTIVE_MB=$(to_mb "$PAGES_ACTIVE")
INACTIVE_MB=$(to_mb "$PAGES_INACTIVE")
COMPRESSED_MB=$(to_mb "$PAGES_COMPRESSED")
USED_MB=$(( WIRED_MB + ACTIVE_MB + COMPRESSED_MB ))

echo "  空き       : ${FREE_MB} MB"
echo "  使用中     : ${USED_MB} MB  (active: ${ACTIVE_MB} + wired: ${WIRED_MB} + compressed: ${COMPRESSED_MB})"
echo "  非アクティブ: ${INACTIVE_MB} MB"

# ────────────────────────────────────────────
# シミュレーター プロセス
# ────────────────────────────────────────────
header "起動中のシミュレーター"
SIM_PROCS=$(ps aux 2>/dev/null | grep -i "Simulator\|simctl\|CoreSimulator" | grep -v grep || true)
if [ -z "$SIM_PROCS" ]; then
    echo "  （シミュレータープロセスなし）"
else
    echo "$SIM_PROCS" | awk '{printf "  %-8s %5s MB  %s\n", $1, int($6/1024), $11}' | head -20
fi

# ────────────────────────────────────────────
# メモリ使用量上位プロセス
# ────────────────────────────────────────────
header "メモリ使用量 上位 ${TOP_N} プロセス"
ps aux 2>/dev/null \
    | sort -k6 -rn \
    | head -$(( TOP_N + 1 )) \
    | tail -"$TOP_N" \
    | awk '{printf "  %7s MB  %-30s\n", int($6/1024), $11}'

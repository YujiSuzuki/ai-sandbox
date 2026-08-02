#!/bin/bash
# test-setup-output-reminder.sh
# Test script for hooks/setup-output-reminder.sh
#
# hooks/setup-output-reminder.sh のテストスクリプト
#
# Usage: ./test-setup-output-reminder.sh
# 使用方法: ./test-setup-output-reminder.sh

set -e

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for this test"
    echo "エラー: このテストには jq が必要です"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/setup-output-reminder.sh"
TEST_WORKSPACE=""
ALIVE_PID=""
OUT_BASE_REL=".sandbox/.state/setup-output/sandbox-mcp-pids"

# Colors for output
# 出力用の色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color / 色なし

# Test counter
# テストカウンター
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
# ヘルパー関数
pass() {
    echo -e "${GREEN}✅ $1${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}❌ $1${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

# Setup / cleanup
# セットアップ・クリーンアップ
setup() {
    TEST_WORKSPACE=$(mktemp -d /tmp/.test-setup-output-reminder-XXXXXX)
    mkdir -p "$TEST_WORKSPACE/$OUT_BASE_REL"
    export WORKSPACE_ROOT="$TEST_WORKSPACE"
}

stop_alive_pid() {
    if [ -n "$ALIVE_PID" ]; then
        kill "$ALIVE_PID" 2>/dev/null || true
        wait "$ALIVE_PID" 2>/dev/null || true
        ALIVE_PID=""
    fi
}

cleanup() {
    stop_alive_pid
    if [ -n "$TEST_WORKSPACE" ] && [ -d "$TEST_WORKSPACE" ]; then
        rm -rf "$TEST_WORKSPACE"
    fi
    unset WORKSPACE_ROOT
}

trap cleanup EXIT

# Fixture helpers
# フィクスチャ用ヘルパー
start_alive_pid() {
    sleep 100 &
    ALIVE_PID=$!
}

make_dead_pid() {
    ( : ) &
    local p=$!
    wait "$p" 2>/dev/null || true
    echo "$p"
}

# ========================================
# Test Cases / テストケース
# ========================================

# Test 1: No setup-output directory at all -> {}
# テスト1: setup-outputディレクトリ自体が存在しない -> {}
test_no_dir() {
    info "Test 1: No setup-output directory -> {}"
    info "テスト1: setup-outputディレクトリが存在しない場合 -> {}"

    setup
    rm -rf "${TEST_WORKSPACE:?}/$OUT_BASE_REL"

    local result
    result=$("$HOOK")

    if [ "$result" = "{}" ]; then
        pass "Empty {} returned when dir missing"
    else
        fail "Expected {}, got: $result"
    fi

    cleanup
}

# Test 2: Directory exists but has no subdirectories -> {}
# テスト2: ディレクトリはあるが中身が空 -> {}
test_empty_dir() {
    info "Test 2: Empty setup-output directory -> {}"
    info "テスト2: setup-outputディレクトリが空の場合 -> {}"

    setup

    local result
    result=$("$HOOK")

    if [ "$result" = "{}" ]; then
        pass "Empty {} returned when dir has no subdirs"
    else
        fail "Expected {}, got: $result"
    fi

    cleanup
}

# Test 3: Alive PID dir with two txt files -> content inlined into additionalContext
# テスト3: 生存PIDディレクトリのtxtファイル内容がadditionalContextにそのまま含まれる
test_alive_pid_content_inlined() {
    info "Test 3: Alive PID dir content is inlined into additionalContext"
    info "テスト3: 生存PIDディレクトリの内容がadditionalContextに埋め込まれる"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    echo "hello from file A" > "$dir/05-a.txt"
    echo "hello from file B" > "$dir/40-b.txt"

    local result
    result=$("$HOOK")

    if echo "$result" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' > /dev/null 2>&1; then
        pass "hookEventName is UserPromptSubmit"
    else
        fail "hookEventName missing/incorrect: $result"
    fi

    local ctx
    ctx=$(echo "$result" | jq -r '.hookSpecificOutput.additionalContext')
    if [[ "$ctx" == *"hello from file A"* ]] && [[ "$ctx" == *"hello from file B"* ]]; then
        pass "Both file contents inlined into additionalContext"
    else
        fail "File contents not found in additionalContext: $ctx"
    fi

    stop_alive_pid
    cleanup
}

# Test 4: Only a dead PID directory is present -> {}
# テスト4: 死亡PIDディレクトリのみ存在する場合 -> {}
test_dead_pid_only() {
    info "Test 4: Only dead PID directory present -> {}"
    info "テスト4: 死亡PIDディレクトリのみの場合 -> {}"

    setup
    local dead_pid
    dead_pid=$(make_dead_pid)
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$dead_pid"
    mkdir -p "$dir"
    echo "should not appear" > "$dir/05-a.txt"

    local result
    result=$("$HOOK")

    if [ "$result" = "{}" ]; then
        pass "Dead PID directory ignored"
    else
        fail "Expected {}, got: $result"
    fi

    cleanup
}

# Test 5: Two alive PID dirs -> the one with newest mtime is chosen
# テスト5: 生存PIDディレクトリが2つある場合、mtimeが新しい方が選ばれる
test_newest_mtime_chosen() {
    info "Test 5: Newest mtime among alive PID dirs is chosen"
    info "テスト5: 生存PIDディレクトリのうちmtimeが新しい方が選ばれる"

    setup

    sleep 100 &
    local pid_old=$!
    local dir_old="$TEST_WORKSPACE/$OUT_BASE_REL/$pid_old"
    mkdir -p "$dir_old"
    echo "OLD CONTENT" > "$dir_old/05-a.txt"

    sleep 1

    sleep 100 &
    local pid_new=$!
    local dir_new="$TEST_WORKSPACE/$OUT_BASE_REL/$pid_new"
    mkdir -p "$dir_new"
    echo "NEW CONTENT" > "$dir_new/05-a.txt"

    local result ctx
    result=$("$HOOK")
    ctx=$(echo "$result" | jq -r '.hookSpecificOutput.additionalContext')

    kill "$pid_old" "$pid_new" 2>/dev/null || true
    wait "$pid_old" "$pid_new" 2>/dev/null || true

    if [[ "$ctx" == *"NEW CONTENT"* ]] && [[ "$ctx" != *"OLD CONTENT"* ]]; then
        pass "Newest directory content selected"
    else
        fail "Expected only NEW CONTENT, got: $ctx"
    fi

    cleanup
}

# Test 6: Second invocation for the same PID dir returns {} (idempotent marker)
# テスト6: 同一PIDディレクトリへの2回目の呼び出しは{}(冪等マーカー)
test_idempotent_marker() {
    info "Test 6: Second invocation for same PID dir returns {}"
    info "テスト6: 同一ディレクトリへの2回目の呼び出しは{}"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    echo "only once" > "$dir/05-a.txt"

    local first second
    first=$("$HOOK")
    second=$("$HOOK")

    if [[ "$first" == *"only once"* ]] && [ "$second" = "{}" ]; then
        pass "Content emitted once, then suppressed on second call"
    else
        fail "First: $first / Second: $second"
    fi

    stop_alive_pid
    cleanup
}

# Test 7: Special characters (quotes/newlines/backslashes) still produce valid JSON
# テスト7: 引用符・改行・バックスラッシュを含んでも正しいJSONになる
test_json_escaping() {
    info "Test 7: Special characters in file content produce valid JSON"
    info "テスト7: ファイル内容に特殊文字を含んでも正しいJSONになる"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    printf 'line with "quotes" and \\ backslash\nsecond line\n' > "$dir/05-a.txt"

    local result
    result=$("$HOOK")

    if echo "$result" | jq empty > /dev/null 2>&1; then
        pass "Output is valid JSON despite special characters"
    else
        fail "Output is not valid JSON: $result"
    fi

    stop_alive_pid
    cleanup
}

# Test 8: jq unavailable -> {} (fail-safe)
# テスト8: jqが無い場合 -> {}(フェイルセーフ)
test_no_jq() {
    info "Test 8: jq unavailable -> {}"
    info "テスト8: jqが無い場合 -> {}"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    echo "content" > "$dir/05-a.txt"

    # Remove only the directories that provide a jq binary from PATH,
    # keeping every other directory intact.
    # jqバイナリを提供するディレクトリだけをPATHから除外し、
    # それ以外のディレクトリはそのまま残す。
    local filtered_path="" d
    IFS=':' read -ra path_dirs <<< "$PATH"
    for d in "${path_dirs[@]}"; do
        if [ ! -x "$d/jq" ]; then
            filtered_path="$filtered_path:$d"
        fi
    done
    filtered_path="${filtered_path#:}"

    local result
    result=$(PATH="$filtered_path" "$HOOK")

    if [ "$result" = "{}" ]; then
        pass "Empty {} returned when jq is unavailable"
    else
        fail "Expected {}, got: $result"
    fi

    stop_alive_pid
    cleanup
}

# ========================================
# Run all tests / 全テストの実行
# ========================================

echo ""
echo "=========================================="
echo "Testing hooks/setup-output-reminder.sh"
echo "hooks/setup-output-reminder.sh のテスト"
echo "=========================================="
echo ""

test_no_dir
test_empty_dir
test_alive_pid_content_inlined
test_dead_pid_only
test_newest_mtime_chosen
test_idempotent_marker
test_json_escaping
test_no_jq

echo ""
echo "=========================================="
echo "Test Results / テスト結果"
echo "=========================================="
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! / 全テスト成功！${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. / 一部のテストが失敗しました。${NC}"
    exit 1
fi

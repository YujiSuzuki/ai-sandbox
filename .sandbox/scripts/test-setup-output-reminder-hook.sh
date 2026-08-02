#!/bin/bash
# test-setup-output-reminder-hook.sh
# Test script for setup-output-reminder-hook.sh
#
# setup-output-reminder-hook.sh のテストスクリプト
#
# Usage: ./test-setup-output-reminder-hook.sh
# 使用方法: ./test-setup-output-reminder-hook.sh

set -e

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for this test"
    echo "エラー: このテストには jq が必要です"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/setup-output-reminder-hook.sh"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/setup-output-reminder.sh"
TEST_WORKSPACE=""

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

# Setup test environment
# テスト環境のセットアップ
setup() {
    info "Setting up test environment..."

    TEST_WORKSPACE=$(mktemp -d /tmp/.test-setup-output-reminder-hook-XXXXXX)
    mkdir -p "$TEST_WORKSPACE/.sandbox/scripts"
    mkdir -p "$TEST_WORKSPACE/.sandbox/hooks"

    cp "$SCRIPT_DIR/_startup_common.sh" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$HOOK_SCRIPT" "$TEST_WORKSPACE/.sandbox/hooks/"

    export WORKSPACE_ROOT="$TEST_WORKSPACE"
}

# Cleanup test environment
# テスト環境のクリーンアップ
cleanup() {
    info "Cleaning up test environment..."

    if [ -n "$TEST_WORKSPACE" ] && [ -d "$TEST_WORKSPACE" ]; then
        rm -rf "$TEST_WORKSPACE"
    fi

    unset WORKSPACE_ROOT
}

trap cleanup EXIT

# ========================================
# Test Cases / テストケース
# ========================================

# Test 1: registers the hook regardless of locale (unlike the language hook,
# this one is locale-independent since setup-output content isn't translated)
# テスト1: ロケールによらずフックを登録する（言語hookと違い、
# setup-outputの内容は言語非依存のため常に登録される）
test_registers_hook_any_locale() {
    info "Test 1: Hook is registered regardless of locale"
    info "テスト1: ロケールによらずフックが登録される"

    setup
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    "$SCRIPT"

    if jq -e --arg cmd "bash $TEST_WORKSPACE/.sandbox/hooks/setup-output-reminder.sh" '
        [(.hooks.UserPromptSubmit // [])[].hooks[]? | select(.type == "command") | .command]
        | any(. == $cmd)
    ' "$TEST_WORKSPACE/.claude/settings.json" > /dev/null 2>&1; then
        pass "Hook registered under non-Japanese locale too"
    else
        fail "Hook not registered under non-Japanese locale"
        cat "$TEST_WORKSPACE/.claude/settings.json" 2>/dev/null || true
    fi

    cleanup
}

# Test 2: registers the hook in a fresh settings.json
# テスト2: 新規settings.jsonにフックを登録する
test_registers_hook_fresh_settings() {
    info "Test 2: Registers the hook in a fresh settings.json"
    info "テスト2: 新規settings.jsonにフックを登録する"

    setup

    "$SCRIPT"

    if [ -f "$TEST_WORKSPACE/.claude/settings.json" ]; then
        pass "settings.json created"
    else
        fail "settings.json was not created"
    fi

    if jq -e --arg cmd "bash $TEST_WORKSPACE/.sandbox/hooks/setup-output-reminder.sh" '
        [(.hooks.UserPromptSubmit // [])[].hooks[]? | select(.type == "command") | .command]
        | any(. == $cmd)
    ' "$TEST_WORKSPACE/.claude/settings.json" > /dev/null 2>&1; then
        pass "Hook registered with correct command"
    else
        fail "Hook not registered correctly"
        cat "$TEST_WORKSPACE/.claude/settings.json"
    fi

    cleanup
}

# Test 3: existing settings.json content (e.g. permissions, other hooks) is preserved
# テスト3: 既存のsettings.jsonの内容（permissionsや他のhookなど）が保持される
test_preserves_existing_settings() {
    info "Test 3: Existing settings.json content is preserved"
    info "テスト3: 既存のsettings.jsonの内容が保持される"

    setup

    mkdir -p "$TEST_WORKSPACE/.claude"
    echo '{"permissions":{"deny":["Read(.env)"]},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash /workspace/.sandbox/hooks/language-reminder.sh","timeout":5}]}]}}' > "$TEST_WORKSPACE/.claude/settings.json"

    "$SCRIPT"

    if jq -e '.permissions.deny | index("Read(.env)")' "$TEST_WORKSPACE/.claude/settings.json" > /dev/null 2>&1; then
        pass "Existing permissions preserved"
    else
        fail "Existing permissions were lost"
        cat "$TEST_WORKSPACE/.claude/settings.json"
    fi

    if jq -e --arg cmd "bash /workspace/.sandbox/hooks/language-reminder.sh" '
        [(.hooks.UserPromptSubmit // [])[].hooks[]? | select(.type == "command") | .command]
        | any(. == $cmd)
    ' "$TEST_WORKSPACE/.claude/settings.json" > /dev/null 2>&1; then
        pass "Existing language hook entry preserved alongside new one"
    else
        fail "Existing language hook entry was lost"
        cat "$TEST_WORKSPACE/.claude/settings.json"
    fi

    if jq -e --arg cmd "bash $TEST_WORKSPACE/.sandbox/hooks/setup-output-reminder.sh" '
        [(.hooks.UserPromptSubmit // [])[].hooks[]? | select(.type == "command") | .command]
        | any(. == $cmd)
    ' "$TEST_WORKSPACE/.claude/settings.json" > /dev/null 2>&1; then
        pass "New hook added alongside existing entries"
    else
        fail "New hook was not added"
    fi

    cleanup
}

# Test 4: running twice does not duplicate the hook entry
# テスト4: 2回実行してもフックが重複登録されない
test_idempotent() {
    info "Test 4: Running twice does not duplicate the hook entry"
    info "テスト4: 2回実行してもフックが重複登録されない"

    setup

    "$SCRIPT"
    "$SCRIPT"

    local count
    count=$(jq --arg cmd "bash $TEST_WORKSPACE/.sandbox/hooks/setup-output-reminder.sh" '
        [.hooks.UserPromptSubmit[].hooks[] | select(.command == $cmd)] | length
    ' "$TEST_WORKSPACE/.claude/settings.json")

    if [ "$count" -eq 1 ]; then
        pass "Hook registered exactly once after two runs"
    else
        fail "Expected exactly 1 matching entry, got $count"
        cat "$TEST_WORKSPACE/.claude/settings.json"
    fi

    cleanup
}

# ========================================
# Run all tests / 全テストの実行
# ========================================

echo ""
echo "=========================================="
echo "Testing setup-output-reminder-hook.sh"
echo "setup-output-reminder-hook.sh のテスト"
echo "=========================================="
echo ""

test_registers_hook_any_locale
test_registers_hook_fresh_settings
test_preserves_existing_settings
test_idempotent

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

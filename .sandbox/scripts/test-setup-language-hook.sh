#!/bin/bash
# test-setup-language-hook.sh
# Test script for setup-language-hook.sh
#
# setup-language-hook.sh のテストスクリプト
#
# Usage: ./test-setup-language-hook.sh
# 使用方法: ./test-setup-language-hook.sh

set -e

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for this test"
    echo "エラー: このテストには jq が必要です"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/setup-language-hook.sh"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/language-reminder.sh"
TEST_WORKSPACE=""
ORIGINAL_LANG="${LANG:-}"
ORIGINAL_LC_ALL="${LC_ALL:-}"

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

    TEST_WORKSPACE=$(mktemp -d /tmp/.test-language-hook-XXXXXX)
    mkdir -p "$TEST_WORKSPACE/.sandbox/scripts"
    mkdir -p "$TEST_WORKSPACE/.sandbox/hooks"
    mkdir -p "$TEST_WORKSPACE/.sandbox/config"

    cp "$SCRIPT_DIR/_startup_common.sh" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$HOOK_SCRIPT" "$TEST_WORKSPACE/.sandbox/hooks/"
    cp "$SCRIPT_DIR/../config/startup.conf" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true
    cp "$SCRIPT_DIR/../config/sync-ignore" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true

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
    export LANG="$ORIGINAL_LANG"
    export LC_ALL="$ORIGINAL_LC_ALL"
}

# Trap to ensure cleanup on exit
# 終了時にクリーンアップを保証するトラップ
trap cleanup EXIT

# ========================================
# Test Cases / テストケース
# ========================================

# Test 1: Non-Japanese locale is a no-op
# テスト1: 日本語以外のロケールでは何もしない
test_noop_non_japanese_locale() {
    info "Test 1: Non-Japanese locale is a no-op"
    info "テスト1: 日本語以外のロケールでは何もしない"

    setup
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    "$SCRIPT"

    if [ ! -f "$TEST_WORKSPACE/.claude/settings.json" ]; then
        pass "No settings.json created for non-Japanese locale"
    else
        fail "settings.json should not be created for non-Japanese locale"
    fi

    cleanup
}

# Test 2: Japanese locale registers the hook in a fresh settings.json
# テスト2: 日本語ロケールでは新規settings.jsonにフックを登録する
test_registers_hook_fresh_settings() {
    info "Test 2: Japanese locale registers the hook in a fresh settings.json"
    info "テスト2: 日本語ロケールでは新規settings.jsonにフックを登録する"

    setup
    export LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8

    "$SCRIPT"

    if [ -f "$TEST_WORKSPACE/.claude/settings.json" ]; then
        pass "settings.json created"
    else
        fail "settings.json was not created"
    fi

    if jq -e --arg cmd "bash $TEST_WORKSPACE/.sandbox/hooks/language-reminder.sh" '
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

# Test 3: Existing settings.json content (e.g. permissions) is preserved
# テスト3: 既存のsettings.jsonの内容（permissionsなど）が保持される
test_preserves_existing_settings() {
    info "Test 3: Existing settings.json content is preserved"
    info "テスト3: 既存のsettings.jsonの内容が保持される"

    setup
    export LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8

    mkdir -p "$TEST_WORKSPACE/.claude"
    echo '{"permissions":{"deny":["Read(.env)"]}}' > "$TEST_WORKSPACE/.claude/settings.json"

    "$SCRIPT"

    if jq -e '.permissions.deny | index("Read(.env)")' "$TEST_WORKSPACE/.claude/settings.json" > /dev/null 2>&1; then
        pass "Existing permissions preserved"
    else
        fail "Existing permissions were lost"
        cat "$TEST_WORKSPACE/.claude/settings.json"
    fi

    if jq -e '.hooks.UserPromptSubmit' "$TEST_WORKSPACE/.claude/settings.json" > /dev/null 2>&1; then
        pass "Hook added alongside existing permissions"
    else
        fail "Hook was not added"
    fi

    cleanup
}

# Test 4: Running twice does not duplicate the hook entry
# テスト4: 2回実行してもフックが重複登録されない
test_idempotent() {
    info "Test 4: Running twice does not duplicate the hook entry"
    info "テスト4: 2回実行してもフックが重複登録されない"

    setup
    export LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8

    "$SCRIPT"
    "$SCRIPT"

    local count
    count=$(jq '.hooks.UserPromptSubmit | length' "$TEST_WORKSPACE/.claude/settings.json")

    if [ "$count" -eq 1 ]; then
        pass "Hook registered exactly once after two runs"
    else
        fail "Expected exactly 1 UserPromptSubmit entry, got $count"
        cat "$TEST_WORKSPACE/.claude/settings.json"
    fi

    cleanup
}

# ========================================
# Run all tests / 全テストの実行
# ========================================

echo ""
echo "=========================================="
echo "Testing setup-language-hook.sh"
echo "setup-language-hook.sh のテスト"
echo "=========================================="
echo ""

test_noop_non_japanese_locale
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

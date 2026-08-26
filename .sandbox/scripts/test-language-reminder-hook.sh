#!/bin/bash
# test-language-reminder-hook.sh
# Test .sandbox/hooks/language-reminder.sh behavior for both Japanese and
# non-Japanese locales.
# .sandbox/hooks/language-reminder.sh の日本語・非日本語ロケール両方の
# 動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TARGET_SCRIPT="$WORKSPACE/.sandbox/hooks/language-reminder.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; ((TESTS_PASSED++)) || true; }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((TESTS_FAILED++)) || true; }

require_jq() {
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required for this test"
        echo "エラー: このテストには jq が必要です"
        exit 1
    fi
}

# ============================================================
# Test: Japanese locale reminds the AI to stay in Japanese
# ============================================================
test_japanese_locale_reminds_japanese() {
    echo ""
    echo "=== Testing LANG=ja_JP.UTF-8 ==="

    local output ctx
    output=$(LANG="ja_JP.UTF-8" bash "$TARGET_SCRIPT")
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if echo "$ctx" | grep -q "Japanese"; then
        pass "Reminds the AI that the default is Japanese"
    else
        fail "Expected a Japanese-default reminder, got: $ctx"
    fi
}

# ============================================================
# Test: non-Japanese locale reminds the AI to stay in English.
# ============================================================
test_non_japanese_locale_reminds_english() {
    echo ""
    echo "=== Testing LANG=en_US.UTF-8 ==="

    local output ctx
    output=$(LANG="en_US.UTF-8" bash "$TARGET_SCRIPT")
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')

    if [ -n "$ctx" ]; then
        pass "Produces a non-empty reminder for a non-Japanese locale"
    else
        fail "Expected a non-empty reminder, got empty additionalContext (this was the observed bug: repeated Japanese-context drift went uncorrected in English sessions)"
    fi

    if echo "$ctx" | grep -q "English"; then
        pass "Reminds the AI that the default is English"
    else
        fail "Expected an English-default reminder, got: $ctx"
    fi
}

# ============================================================
# Test: unset LANG behaves the same as non-Japanese
# ============================================================
test_unset_lang_reminds_english() {
    echo ""
    echo "=== Testing LANG unset ==="

    local output ctx
    output=$(env -u LANG bash "$TARGET_SCRIPT")
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')

    if [ -n "$ctx" ]; then
        pass "Produces a non-empty reminder when LANG is unset"
    else
        fail "Expected a non-empty reminder when LANG is unset, got empty additionalContext"
    fi
}

# ============================================================
# Test: both branches still defer to the user's actual language
# ============================================================
test_both_branches_defer_to_user_language() {
    echo ""
    echo "=== Testing both branches defer to the user's actual language ==="

    local ctx_ja ctx_en
    ctx_ja=$(LANG="ja_JP.UTF-8" bash "$TARGET_SCRIPT" | jq -r '.hookSpecificOutput.additionalContext')
    ctx_en=$(LANG="en_US.UTF-8" bash "$TARGET_SCRIPT" | jq -r '.hookSpecificOutput.additionalContext')

    if echo "$ctx_ja" | grep -qi "switch language if the user" \
        && echo "$ctx_en" | grep -qi "switch language if the user"; then
        pass "Both branches instruct the AI to switch if the user writes in another language"
    else
        fail "Expected both branches to defer to the user's actual language, got ja: '$ctx_ja' / en: '$ctx_en'"
    fi
}

main() {
    require_jq

    echo "========================================"
    echo "language-reminder.sh Hook Tests"
    echo "========================================"

    test_japanese_locale_reminds_japanese
    test_non_japanese_locale_reminds_english
    test_unset_lang_reminds_english
    test_both_branches_defer_to_user_language

    echo ""
    echo "========================================"
    echo "Test Results"
    echo "========================================"
    echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
    echo ""

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"

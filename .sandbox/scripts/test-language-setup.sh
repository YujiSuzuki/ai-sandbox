#!/bin/bash
# test-language-setup.sh
# Test .sandbox/sandbox-mcp-setup/30-language.sh behavior
# .sandbox/sandbox-mcp-setup/30-language.sh の動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TARGET_SCRIPT="$WORKSPACE/.sandbox/sandbox-mcp-setup/30-language.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

# Test helpers
pass() { echo -e "${GREEN}PASS${NC}: $1"; ((TESTS_PASSED++)) || true; }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((TESTS_FAILED++)) || true; }

# ============================================================
# Test: Script is executable
# ============================================================
test_script_executable() {
    echo ""
    echo "=== Testing script is executable ==="

    if [ -f "$TARGET_SCRIPT" ]; then
        pass "30-language.sh exists"
    else
        fail "30-language.sh does not exist"
        return
    fi

    if [ -x "$TARGET_SCRIPT" ]; then
        pass "30-language.sh is executable"
    else
        fail "30-language.sh should be executable"
    fi
}

# ============================================================
# Test: LANG=ja_JP.UTF-8 → Japanese instruction
# ============================================================
test_japanese_lang() {
    echo ""
    echo "=== Testing LANG=ja_JP.UTF-8 ==="

    local output
    output=$(LANG="ja_JP.UTF-8" bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "default to Japanese"; then
        pass "Outputs Japanese default instruction for LANG=ja_JP.UTF-8"
    else
        fail "Expected Japanese default instruction, got: $output"
    fi

    if echo "$output" | grep -q "ja_JP.UTF-8"; then
        pass "Echoes the LANG value back in the Japanese instruction"
    else
        fail "Expected LANG value in output, got: $output"
    fi
}

# ============================================================
# Test: LANG unset or non-Japanese → English instruction
# ============================================================
test_non_japanese_lang() {
    echo ""
    echo "=== Testing LANG=en_US.UTF-8 ==="

    local output
    output=$(LANG="en_US.UTF-8" bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "default to English"; then
        pass "Outputs English default instruction for LANG=en_US.UTF-8"
    else
        fail "Expected English default instruction, got: $output"
    fi

    if echo "$output" | grep -q "en_US.UTF-8"; then
        pass "Echoes the LANG value back in the English instruction"
    else
        fail "Expected LANG value in output, got: $output"
    fi
}

test_unset_lang() {
    echo ""
    echo "=== Testing LANG unset ==="

    local output
    output=$(env -u LANG bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "default to English"; then
        pass "Falls back to English default instruction when LANG is unset"
    else
        fail "Expected English default instruction when LANG unset, got: $output"
    fi

    if echo "$output" | grep -q "LANG=unset"; then
        pass "Shows 'unset' placeholder when LANG is unset"
    else
        fail "Expected 'unset' placeholder in output, got: $output"
    fi
}

# ============================================================
# Test: Output always tells the AI to match the user's language
# ============================================================
test_always_matches_user_language() {
    echo ""
    echo "=== Testing output always defers to the user's actual language ==="

    local output_ja output_en
    output_ja=$(LANG="ja_JP.UTF-8" bash "$TARGET_SCRIPT")
    output_en=$(LANG="en_US.UTF-8" bash "$TARGET_SCRIPT")

    if echo "$output_ja" | grep -q "always match whatever language the user actually writes in" \
        && echo "$output_en" | grep -q "always match whatever language the user actually writes in"; then
        pass "Both branches instruct the AI to match the user's actual language"
    else
        fail "Expected both branches to defer to the user's actual language, got ja: '$output_ja' / en: '$output_en'"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "language Setup Script Tests"
    echo "========================================"

    test_script_executable
    test_japanese_lang
    test_non_japanese_lang
    test_unset_lang
    test_always_matches_user_language

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

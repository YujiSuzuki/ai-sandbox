#!/bin/bash
# test-claude-data.sh
# Test script for claude-data.py
#
# claude-data.py のテストスクリプト
#
# Usage: ./test-claude-data.sh
# 使用方法: ./test-claude-data.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/claude-data.py"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
pass() {
    echo -e "${GREEN}PASS: $1${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL: $1${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

info() {
    echo -e "${YELLOW}TEST: $1${NC}"
}

# Test: --help shows usage
test_help() {
    info "--help shows usage"

    local output
    output=$("$SCRIPT" --help 2>&1) || true

    if echo "$output" | grep -q "Usage"; then
        pass "--help shows usage"
    else
        fail "--help should show usage"
        echo "  Output: $output"
    fi
}

# Test: no arguments lists memory/plans instead of copying
test_default_lists() {
    info "No arguments lists memory/plans (does not copy)"

    local output
    output=$("$SCRIPT" 2>&1)

    if echo "$output" | grep -q "^Done"; then
        fail "Default invocation should not copy (found 'Done' message)"
        echo "  Output: $output"
    else
        pass "Default invocation does not copy"
    fi
}

# Test: default output lists memory/ file paths when present
test_default_lists_memory() {
    info "Default invocation lists memory/ files"

    local memory_dir="/home/node/.claude/projects/-workspace/memory"
    if [ ! -d "$memory_dir" ]; then
        echo "  Skipping: no memory/ dir in this environment"
        pass "Default lists memory/ (skipped)"
        return
    fi

    local output
    output=$("$SCRIPT" 2>&1)

    if echo "$output" | grep -q "$memory_dir"; then
        pass "Default invocation lists memory/ files"
    else
        fail "Default invocation should list memory/ files"
        echo "  Output: $output"
    fi
}

# Test: default (no --with-settings) excludes settings.json from listing
test_default_excludes_settings() {
    info "Default invocation excludes settings.json"

    local output
    output=$("$SCRIPT" 2>&1)

    if echo "$output" | grep -q "settings.json"; then
        fail "Default invocation should not list settings.json without --with-settings"
        echo "  Output: $output"
    else
        pass "Default invocation excludes settings.json"
    fi
}

# Test: --with-settings (without --copy) includes settings.json/plugins when present
test_with_settings_lists_settings() {
    info "--with-settings lists settings.json/plugins when present"

    local settings_file="/home/node/.claude/settings.json"
    if [ ! -f "$settings_file" ]; then
        echo "  Skipping: no settings.json in this environment"
        pass "--with-settings lists settings.json (skipped)"
        return
    fi

    local output
    output=$("$SCRIPT" --with-settings 2>&1)

    if echo "$output" | grep -q "$settings_file"; then
        pass "--with-settings lists settings.json"
    else
        fail "--with-settings should list settings.json"
        echo "  Output: $output"
    fi
}

# Test: --copy without a dest-dir shows an error
test_copy_missing_destdir() {
    info "--copy without dest-dir shows error"

    local output
    output=$("$SCRIPT" --copy 2>&1) || true

    if echo "$output" | grep -q "requires a dest-dir"; then
        pass "--copy without dest-dir shows error"
    else
        fail "--copy without dest-dir should show error"
        echo "  Output: $output"
    fi
}

# Test: --copy followed by another flag (no dest-dir) shows an error
test_copy_followed_by_flag() {
    info "--copy followed by --with-settings (no dest-dir) shows error"

    local output
    output=$("$SCRIPT" --copy --with-settings 2>&1) || true

    if echo "$output" | grep -q "requires a dest-dir"; then
        pass "--copy followed by a flag shows error"
    else
        fail "--copy followed by a flag should show error"
        echo "  Output: $output"
    fi
}

# Test: --copy followed by an empty string dest-dir shows an error
test_copy_empty_destdir() {
    info "--copy with an empty string dest-dir shows error"

    local output
    output=$("$SCRIPT" --copy "" 2>&1) || true

    if echo "$output" | grep -q "requires a dest-dir"; then
        pass "--copy with an empty string dest-dir shows error"
    else
        fail "--copy with an empty string dest-dir should show error"
        echo "  Output: $output"
    fi
}

# Test: unknown option shows error and usage
test_unknown_option() {
    info "Unknown option shows error"

    local output
    output=$("$SCRIPT" --bogus-flag 2>&1) || true

    if echo "$output" | grep -q "Unknown option"; then
        pass "Unknown option shows error"
    else
        fail "Unknown option should show error"
        echo "  Output: $output"
    fi
}

# Test: --copy <dest-dir> actually copies memory/plans into dest-dir
test_copy_copies_files() {
    info "--copy <dest-dir> copies memory/plans into dest-dir"

    local memory_dir="/home/node/.claude/projects/-workspace/memory"
    if [ ! -d "$memory_dir" ]; then
        echo "  Skipping: no memory/ dir in this environment"
        pass "--copy copies files (skipped)"
        return
    fi

    local dest_dir
    dest_dir=$(mktemp -d)

    local output
    output=$("$SCRIPT" --copy "$dest_dir" 2>&1)

    if echo "$output" | grep -q "^Done" && [ -d "$dest_dir/memory" ]; then
        pass "--copy <dest-dir> copies memory/ into dest-dir"
    else
        fail "--copy <dest-dir> should copy memory/ into dest-dir"
        echo "  Output: $output"
    fi

    rm -rf "$dest_dir"
}

# Test: --copy without --with-settings does not copy settings.json
test_copy_excludes_settings_by_default() {
    info "--copy without --with-settings excludes settings.json"

    local settings_file="/home/node/.claude/settings.json"
    if [ ! -f "$settings_file" ]; then
        echo "  Skipping: no settings.json in this environment"
        pass "--copy excludes settings.json (skipped)"
        return
    fi

    local dest_dir
    dest_dir=$(mktemp -d)

    "$SCRIPT" --copy "$dest_dir" > /dev/null 2>&1 || true

    if [ -f "$dest_dir/settings.json" ]; then
        fail "--copy without --with-settings should not copy settings.json"
    else
        pass "--copy without --with-settings excludes settings.json"
    fi

    rm -rf "$dest_dir"
}

# Run all tests
main() {
    echo "========================================"
    echo "Testing claude-data.py"
    echo "claude-data.py のテスト"
    echo "========================================"
    echo ""

    test_help
    test_default_lists
    test_default_lists_memory
    test_default_excludes_settings
    test_with_settings_lists_settings
    test_copy_missing_destdir
    test_copy_followed_by_flag
    test_copy_empty_destdir
    test_unknown_option
    test_copy_copies_files
    test_copy_excludes_settings_by_default

    echo ""
    echo "========================================"
    echo "Results / 結果"
    echo "========================================"
    echo -e "Passed / 成功: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed / 失敗: ${RED}${TESTS_FAILED}${NC}"

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
}

main "$@"

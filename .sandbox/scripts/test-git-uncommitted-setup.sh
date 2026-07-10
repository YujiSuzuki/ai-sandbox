#!/bin/bash
# test-git-uncommitted-setup.sh
# Test .sandbox/sandbox-mcp-setup/20-git-uncommitted.sh behavior
# .sandbox/sandbox-mcp-setup/20-git-uncommitted.sh の動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TARGET_SCRIPT="$WORKSPACE/.sandbox/sandbox-mcp-setup/20-git-uncommitted.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

# Test helpers
pass() { echo -e "${GREEN}PASS${NC}: $1"; ((TESTS_PASSED++)) || true; }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((TESTS_FAILED++)) || true; }

# Fake workspace with an outer repo (should be ignored, matches VSCode gitStatus
# coverage) and nested repos at varying depth/dirtiness.
# 外側リポジトリ（VSCode gitStatus がカバーするため除外対象）と、深さ・変更状態が
# 異なるネストしたリポジトリを持つフェイクワークスペース。
FAKE_WORKSPACE=""

init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
}

setup() {
    FAKE_WORKSPACE=$(mktemp -d)
    init_repo "$FAKE_WORKSPACE"

    # Clean nested repo at depth 1
    init_repo "$FAKE_WORKSPACE/clean-repo"
    echo "committed" > "$FAKE_WORKSPACE/clean-repo/file.txt"
    git -C "$FAKE_WORKSPACE/clean-repo" add file.txt
    git -C "$FAKE_WORKSPACE/clean-repo" commit -q -m "init"

    # Dirty nested repo at depth 1 (untracked file)
    init_repo "$FAKE_WORKSPACE/dirty-repo"
    echo "untracked" > "$FAKE_WORKSPACE/dirty-repo/new-file.txt"

    # Dirty nested repo at depth 2 (nested one level deeper)
    init_repo "$FAKE_WORKSPACE/sub/dirty-nested-repo"
    echo "untracked" > "$FAKE_WORKSPACE/sub/dirty-nested-repo/new-file.txt"
}

teardown() {
    [ -n "$FAKE_WORKSPACE" ] && rm -rf "$FAKE_WORKSPACE"
}

# ============================================================
# Test: Script is executable
# ============================================================
test_script_executable() {
    echo ""
    echo "=== Testing script is executable ==="

    if [ -f "$TARGET_SCRIPT" ]; then
        pass "20-git-uncommitted.sh exists"
    else
        fail "20-git-uncommitted.sh does not exist"
        return
    fi

    if [ -x "$TARGET_SCRIPT" ]; then
        pass "20-git-uncommitted.sh is executable"
    else
        fail "20-git-uncommitted.sh should be executable"
    fi
}

# ============================================================
# Test: outer repo is excluded, dirty nested repos are reported
# ============================================================
test_reports_dirty_nested_repos_and_excludes_outer() {
    echo ""
    echo "=== Testing dirty nested repo detection ==="

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "dirty-repo (1 file"; then
        pass "Reports the depth-1 dirty repo with its file count"
    else
        fail "Should report dirty-repo with file count, got: '$output'"
    fi

    if echo "$output" | grep -q "sub/dirty-nested-repo (1 file"; then
        pass "Reports the depth-2 dirty nested repo with its file count"
    else
        fail "Should report sub/dirty-nested-repo with file count, got: '$output'"
    fi

    if echo "$output" | grep -q "clean-repo"; then
        fail "Should not report the clean repo, got: '$output'"
    else
        pass "Does not report the clean repo"
    fi

    # The outer repo itself (FAKE_WORKSPACE/.git) must never be reported --
    # VSCode's own gitStatus already covers it.
    if echo "$output" | grep -qE "^Uncommitted changes in nested repo: \.git"; then
        fail "Should not report the outer repo's own .git, got: '$output'"
    else
        pass "Excludes the outer repo from nested-repo reporting"
    fi
}

# ============================================================
# Test: all-clean workspace prints the all-clean message
# ============================================================
test_all_clean_message() {
    echo ""
    echo "=== Testing all-clean message ==="

    local clean_workspace
    clean_workspace=$(mktemp -d)
    init_repo "$clean_workspace"
    init_repo "$clean_workspace/only-clean-repo"
    echo "committed" > "$clean_workspace/only-clean-repo/file.txt"
    git -C "$clean_workspace/only-clean-repo" add file.txt
    git -C "$clean_workspace/only-clean-repo" commit -q -m "init"

    local output
    output=$(WORKSPACE="$clean_workspace" bash "$TARGET_SCRIPT")

    if [ "$output" = "All nested git repos are clean." ]; then
        pass "Prints all-clean message when every nested repo is clean"
    else
        fail "Should print all-clean message, got: '$output'"
    fi

    rm -rf "$clean_workspace"
}

# ============================================================
# Test: workspace with no nested repos at all produces no output
# ============================================================
test_no_nested_repos_silent() {
    echo ""
    echo "=== Testing no nested repos ==="

    local bare_workspace
    bare_workspace=$(mktemp -d)
    init_repo "$bare_workspace"

    local output
    output=$(WORKSPACE="$bare_workspace" bash "$TARGET_SCRIPT")

    if [ -z "$output" ]; then
        pass "Produces no output when there are no nested repos"
    else
        fail "Should produce no output with no nested repos, got: '$output'"
    fi

    rm -rf "$bare_workspace"
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "git-uncommitted Setup Script Tests"
    echo "========================================"

    setup
    trap teardown EXIT

    test_script_executable
    test_reports_dirty_nested_repos_and_excludes_outer
    test_all_clean_message
    test_no_nested_repos_silent

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

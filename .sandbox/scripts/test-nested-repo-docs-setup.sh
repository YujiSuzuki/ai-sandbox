#!/bin/bash
# test-nested-repo-docs-setup.sh
# Test .sandbox/sandbox-mcp-setup/22-nested-repo-docs.sh behavior
# .sandbox/sandbox-mcp-setup/22-nested-repo-docs.sh の動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TARGET_SCRIPT="$WORKSPACE/.sandbox/sandbox-mcp-setup/22-nested-repo-docs.sh"

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

# Fake workspace with an outer repo (should be ignored, same as
# 20-git-uncommitted.sh) and nested repos with varying doc files.
# 外側リポジトリ（20-git-uncommitted.sh と同様に除外対象）と、
# ドキュメントファイルの構成が異なるネストしたリポジトリを持つフェイクワークスペース。
FAKE_WORKSPACE=""

init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
}

setup() {
    FAKE_WORKSPACE=$(mktemp -d)
    init_repo "$FAKE_WORKSPACE"
    echo "# outer" > "$FAKE_WORKSPACE/CLAUDE.md"

    # Nested repo with all three doc files
    init_repo "$FAKE_WORKSPACE/full-docs-repo"
    echo "# claude" > "$FAKE_WORKSPACE/full-docs-repo/CLAUDE.md"
    echo "# readme" > "$FAKE_WORKSPACE/full-docs-repo/README.md"
    echo "# readme ja" > "$FAKE_WORKSPACE/full-docs-repo/README.ja.md"

    # Nested repo with only README.md (no CLAUDE.md)
    init_repo "$FAKE_WORKSPACE/readme-only-repo"
    echo "# readme" > "$FAKE_WORKSPACE/readme-only-repo/README.md"

    # Nested repo with no doc files at all
    init_repo "$FAKE_WORKSPACE/no-docs-repo"
    echo "code" > "$FAKE_WORKSPACE/no-docs-repo/main.go"

    # Vendored repo under an excluded directory name -- must be pruned,
    # not reported as a nested repo.
    # 除外対象ディレクトリ名の配下にあるvendoredリポジトリ -- ネストした
    # リポジトリとして報告されず、探索対象から除外されなければならない。
    init_repo "$FAKE_WORKSPACE/pkg/node_modules/some-dep"
    echo "# vendored" > "$FAKE_WORKSPACE/pkg/node_modules/some-dep/README.md"
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
        pass "22-nested-repo-docs.sh exists"
    else
        fail "22-nested-repo-docs.sh does not exist"
        return
    fi

    if [ -x "$TARGET_SCRIPT" ]; then
        pass "22-nested-repo-docs.sh is executable"
    else
        fail "22-nested-repo-docs.sh should be executable"
    fi
}

# ============================================================
# Test: reports doc files per nested repo, missing files as (none)
# ============================================================
test_reports_docs_and_excludes_outer() {
    echo ""
    echo "=== Testing nested repo doc detection ==="

    local output
    if ! output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        return
    fi

    if echo "$output" | grep -q "full-docs-repo: CLAUDE.md, README.md, README.ja.md"; then
        pass "Reports all three doc files for full-docs-repo"
    else
        fail "Should report all three doc files, got: '$output'"
    fi

    if echo "$output" | grep -q "readme-only-repo: README.md"; then
        pass "Reports only README.md for readme-only-repo"
    else
        fail "Should report only README.md, got: '$output'"
    fi

    if echo "$output" | grep -q "readme-only-repo: README.md, README.ja.md\|readme-only-repo: README.md, CLAUDE.md"; then
        fail "Should not report doc files that don't exist for readme-only-repo, got: '$output'"
    else
        pass "Does not report nonexistent doc files for readme-only-repo"
    fi

    if echo "$output" | grep -q "no-docs-repo: (none)"; then
        pass "Reports (none) for no-docs-repo"
    else
        fail "Should report (none) for no-docs-repo, got: '$output'"
    fi

    # The outer repo itself must never be reported -- same rule as
    # 20-git-uncommitted.sh (VSCode already shows the outer repo's own files).
    if echo "$output" | grep -qF -- "- $FAKE_WORKSPACE:"; then
        fail "Should not report the outer repo, got: '$output'"
    else
        pass "Excludes the outer repo from nested-repo reporting"
    fi

    # A repo vendored under an excluded directory name (node_modules) must
    # be pruned from the search, not reported.
    if echo "$output" | grep -q "node_modules"; then
        fail "Should not report repos under excluded directories, got: '$output'"
    else
        pass "Excludes repos nested under excluded directory names (node_modules)"
    fi
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
    if ! output=$(WORKSPACE="$bare_workspace" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        rm -rf "$bare_workspace"
        return
    fi

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
    echo "nested-repo-docs Setup Script Tests"
    echo "========================================"

    setup
    trap teardown EXIT

    test_script_executable
    test_reports_docs_and_excludes_outer
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

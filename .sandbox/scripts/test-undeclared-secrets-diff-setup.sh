#!/bin/bash
# test-undeclared-secrets-diff-setup.sh
# Test .sandbox/sandbox-mcp-setup/25-undeclared-secrets-diff.sh behavior
# .sandbox/sandbox-mcp-setup/25-undeclared-secrets-diff.sh の動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TARGET_SCRIPT="$WORKSPACE/.sandbox/sandbox-mcp-setup/25-undeclared-secrets-diff.sh"

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

FAKE_WORKSPACE=""

# Stub for DIFF_SCRIPT: a fake check-undeclared-secrets-diff.py with
# configurable stdout/exit behavior, so tests don't depend on the real
# scanner or on scratch-state left in the actual workspace.
# DIFF_SCRIPT 用スタブ: 標準出力と終了コードを設定できる偽の
# check-undeclared-secrets-diff.py。実際のスキャナーやワークスペースの
# 状態に依存させない。
make_stub_diff_script() {
    local dir="$1" stdout="$2"
    cat > "$dir/stub-diff.sh" <<EOF
#!/bin/bash
printf '%s' "$stdout"
exit 0
EOF
    chmod +x "$dir/stub-diff.sh"
}

setup_fake_workspace() {
    FAKE_WORKSPACE=$(mktemp -d)
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
        pass "25-undeclared-secrets-diff.sh exists"
    else
        fail "25-undeclared-secrets-diff.sh does not exist"
        return
    fi

    if [ -x "$TARGET_SCRIPT" ]; then
        pass "25-undeclared-secrets-diff.sh is executable"
    else
        fail "25-undeclared-secrets-diff.sh should be executable"
    fi
}

# ============================================================
# Test: DIFF_SCRIPT missing/non-executable -> silent, exit 0
# ============================================================
test_missing_diff_script_silent() {
    echo ""
    echo "=== Testing missing DIFF_SCRIPT ==="

    setup_fake_workspace

    local output exit_code
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        DIFF_SCRIPT="$FAKE_WORKSPACE/does-not-exist.sh" \
        bash "$TARGET_SCRIPT")
    exit_code=$?

    if [ -z "$output" ]; then
        pass "Produces no output when DIFF_SCRIPT is missing"
    else
        fail "Should produce no output with a missing DIFF_SCRIPT, got: '$output'"
    fi

    if [ "$exit_code" -eq 0 ]; then
        pass "Exits 0 when DIFF_SCRIPT is missing"
    else
        fail "Should exit 0 when DIFF_SCRIPT is missing, got $exit_code"
    fi

    teardown
}

# ============================================================
# Test: DIFF_SCRIPT output is passed through unchanged
# ============================================================
test_diff_script_output_passed_through() {
    echo ""
    echo "=== Testing DIFF_SCRIPT output pass-through ==="

    setup_fake_workspace
    make_stub_diff_script "$FAKE_WORKSPACE" "new undeclared file: api/.env.local"

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        DIFF_SCRIPT="$FAKE_WORKSPACE/stub-diff.sh" \
        bash "$TARGET_SCRIPT")

    if [ "$output" = "new undeclared file: api/.env.local" ]; then
        pass "Passes through DIFF_SCRIPT's stdout unchanged"
    else
        fail "Should pass through DIFF_SCRIPT's stdout, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: DIFF_SCRIPT produces no output -> silent (nothing new found)
# ============================================================
test_diff_script_no_output_silent() {
    echo ""
    echo "=== Testing DIFF_SCRIPT with no output ==="

    setup_fake_workspace
    make_stub_diff_script "$FAKE_WORKSPACE" ""

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        DIFF_SCRIPT="$FAKE_WORKSPACE/stub-diff.sh" \
        bash "$TARGET_SCRIPT")

    if [ -z "$output" ]; then
        pass "Produces no output when DIFF_SCRIPT reports nothing new"
    else
        fail "Should produce no output, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: CHECK_TIMEOUT_SECS caps a hanging DIFF_SCRIPT well within
# sandbox-mcp's outer 5s runSetupScripts() budget
# CHECK_TIMEOUT_SECSが、sandbox-mcp外側のrunSetupScripts()5秒予算内に
# ハングするDIFF_SCRIPTを確実に収める
# ============================================================
test_hanging_diff_script_capped_by_timeout() {
    echo ""
    echo "=== Testing hanging DIFF_SCRIPT is capped by CHECK_TIMEOUT_SECS ==="

    setup_fake_workspace
    cat > "$FAKE_WORKSPACE/stub-diff.sh" <<'EOF'
#!/bin/bash
sleep 30
echo "should never print"
EOF
    chmod +x "$FAKE_WORKSPACE/stub-diff.sh"

    local start_time end_time elapsed output
    start_time=$(date +%s)
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        DIFF_SCRIPT="$FAKE_WORKSPACE/stub-diff.sh" \
        CHECK_TIMEOUT_SECS=1 \
        timeout 5 bash "$TARGET_SCRIPT")
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    if [ "$elapsed" -lt 5 ]; then
        pass "Returns well within the outer 5s budget even when DIFF_SCRIPT hangs (took ${elapsed}s)"
    else
        fail "Should return in under 5s even when DIFF_SCRIPT hangs, took ${elapsed}s"
    fi

    if [ -z "$output" ]; then
        pass "Produces no output when DIFF_SCRIPT is killed by the timeout"
    else
        fail "Should produce no output when timed out, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: default DIFF_SCRIPT path resolves under $WORKSPACE when
# DIFF_SCRIPT is not overridden
# DIFF_SCRIPTを上書きしない場合、既定のパスが$WORKSPACE配下を指す
# ============================================================
test_default_diff_script_path_under_workspace() {
    echo ""
    echo "=== Testing default DIFF_SCRIPT path resolution ==="

    setup_fake_workspace
    mkdir -p "$FAKE_WORKSPACE/.sandbox/scripts"
    cat > "$FAKE_WORKSPACE/.sandbox/scripts/check-undeclared-secrets-diff.py" <<'EOF'
#!/bin/bash
echo "found via default path"
EOF
    chmod +x "$FAKE_WORKSPACE/.sandbox/scripts/check-undeclared-secrets-diff.py"

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT")

    if [ "$output" = "found via default path" ]; then
        pass "Resolves DIFF_SCRIPT under \$WORKSPACE/.sandbox/scripts/ by default"
    else
        fail "Should resolve default DIFF_SCRIPT path under \$WORKSPACE, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: script's own exit code is always 0
# 自スクリプトの終了コードは常に0であること
# ============================================================
test_always_exits_zero() {
    echo ""
    echo "=== Testing script always exits 0 ==="

    setup_fake_workspace
    make_stub_diff_script "$FAKE_WORKSPACE" "some finding"

    WORKSPACE="$FAKE_WORKSPACE" \
        DIFF_SCRIPT="$FAKE_WORKSPACE/stub-diff.sh" \
        bash "$TARGET_SCRIPT" >/dev/null
    if [ "$?" -eq 0 ]; then
        pass "Exits 0 when DIFF_SCRIPT reports a finding"
    else
        fail "Should exit 0, got $?"
    fi

    teardown
}

# ============================================================
# Test: PENDING_FILE is exported scoped to this session's own
# sandbox-mcp-pids/<pid> spill directory, not a global path
# PENDING_FILEはグローバルパスではなく、このセッション自身の
# sandbox-mcp-pids/<pid> 退避ディレクトリ配下にエクスポートされる
# ============================================================
test_exports_pending_file_scoped_to_own_pid() {
    echo ""
    echo "=== Testing PENDING_FILE is exported scoped to this session's own PID directory ==="

    setup_fake_workspace
    cat > "$FAKE_WORKSPACE/stub-diff.sh" <<'EOF'
#!/bin/bash
printf '%s' "$PENDING_FILE"
EOF
    chmod +x "$FAKE_WORKSPACE/stub-diff.sh"

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        DIFF_SCRIPT="$FAKE_WORKSPACE/stub-diff.sh" \
        bash "$TARGET_SCRIPT")

    if [[ "$output" =~ ^"$FAKE_WORKSPACE"/\.sandbox/\.state/setup-output/sandbox-mcp-pids/[0-9]+/25-undeclared-secrets-diff\.pending\.json$ ]]; then
        pass "PENDING_FILE is exported under this session's own sandbox-mcp-pids/<pid>/ directory"
    else
        fail "PENDING_FILE should be scoped under sandbox-mcp-pids/<pid>/, got: '$output'"
    fi

    teardown
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "undeclared-secrets-diff Setup Script Tests"
    echo "========================================"

    test_script_executable
    test_missing_diff_script_silent
    test_diff_script_output_passed_through
    test_diff_script_no_output_silent
    test_hanging_diff_script_capped_by_timeout
    test_default_diff_script_path_under_workspace
    test_always_exits_zero
    test_exports_pending_file_scoped_to_own_pid

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

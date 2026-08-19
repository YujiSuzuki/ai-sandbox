#!/bin/bash
# test-hostmcp-host-tools-hint.sh
# Test .sandbox/sandbox-mcp-setup/40-hostmcp-host-tools-hint.sh behavior
# .sandbox/sandbox-mcp-setup/40-hostmcp-host-tools-hint.sh の動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TARGET_SCRIPT="$WORKSPACE/.sandbox/sandbox-mcp-setup/40-hostmcp-host-tools-hint.sh"

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

# Stub for HOSTMCP_CHECK_SCRIPT: a fake setup-hostmcp.sh that only understands
# --check and exits with a pre-set code, so tests don't depend on real
# registration state or network connectivity.
# HOSTMCP_CHECK_SCRIPT 用スタブ: --check のみを理解し、事前に設定した終了コードで
# 終了する偽の setup-hostmcp.sh。実際の登録状態やネットワーク疎通に依存させない。
make_stub_check_script() {
    local dir="$1" exit_code="$2"
    cat > "$dir/stub-setup-hostmcp.sh" <<EOF
#!/bin/bash
[ "\$1" = "--check" ] || exit 99
exit $exit_code
EOF
    chmod +x "$dir/stub-setup-hostmcp.sh"
}

setup_fake_workspace() {
    FAKE_WORKSPACE=$(mktemp -d)
    mkdir -p "$FAKE_WORKSPACE/.sandbox/host-tools"
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
        pass "40-hostmcp-host-tools-hint.sh exists"
    else
        fail "40-hostmcp-host-tools-hint.sh does not exist"
        return
    fi

    if [ -x "$TARGET_SCRIPT" ]; then
        pass "40-hostmcp-host-tools-hint.sh is executable"
    else
        fail "40-hostmcp-host-tools-hint.sh should be executable"
    fi
}

# ============================================================
# Test: no host-tools scripts -> no output, regardless of connectivity
# ============================================================
test_no_host_tools_silent() {
    echo ""
    echo "=== Testing no host-tools scripts ==="

    setup_fake_workspace
    make_stub_check_script "$FAKE_WORKSPACE" 2

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        HOSTMCP_CHECK_SCRIPT="$FAKE_WORKSPACE/stub-setup-hostmcp.sh" \
        bash "$TARGET_SCRIPT")

    if [ -z "$output" ]; then
        pass "Produces no output when host-tools has no scripts"
    else
        fail "Should produce no output with empty host-tools, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: check script missing -> no output (fails silently, not an error)
# ============================================================
test_missing_check_script_silent() {
    echo ""
    echo "=== Testing missing check script ==="

    setup_fake_workspace
    echo "#!/bin/bash" > "$FAKE_WORKSPACE/.sandbox/host-tools/some-tool.sh"
    chmod +x "$FAKE_WORKSPACE/.sandbox/host-tools/some-tool.sh"

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        HOSTMCP_CHECK_SCRIPT="$FAKE_WORKSPACE/does-not-exist.sh" \
        bash "$TARGET_SCRIPT")

    if [ -z "$output" ]; then
        pass "Produces no output when the check script is missing"
    else
        fail "Should produce no output with a missing check script, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: HostMCP connected (exit 0) -> no output
# ============================================================
test_connected_silent() {
    echo ""
    echo "=== Testing connected HostMCP ==="

    setup_fake_workspace
    echo "#!/bin/bash" > "$FAKE_WORKSPACE/.sandbox/host-tools/some-tool.sh"
    chmod +x "$FAKE_WORKSPACE/.sandbox/host-tools/some-tool.sh"
    make_stub_check_script "$FAKE_WORKSPACE" 0

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        HOSTMCP_CHECK_SCRIPT="$FAKE_WORKSPACE/stub-setup-hostmcp.sh" \
        bash "$TARGET_SCRIPT")

    if [ -z "$output" ]; then
        pass "Produces no output when HostMCP is connected"
    else
        fail "Should produce no output when connected, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: HostMCP not registered (exit 1) -> hint mentions host-tools
# ============================================================
test_not_registered_hints() {
    echo ""
    echo "=== Testing not-registered HostMCP ==="

    setup_fake_workspace
    echo "#!/bin/bash" > "$FAKE_WORKSPACE/.sandbox/host-tools/run-host-setup-tests.sh"
    chmod +x "$FAKE_WORKSPACE/.sandbox/host-tools/run-host-setup-tests.sh"
    make_stub_check_script "$FAKE_WORKSPACE" 1

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        HOSTMCP_CHECK_SCRIPT="$FAKE_WORKSPACE/stub-setup-hostmcp.sh" \
        bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "host-tools"; then
        pass "Hint mentions host-tools when not registered"
    else
        fail "Should mention host-tools, got: '$output'"
    fi

    if echo "$output" | grep -q "run-host-setup-tests.sh"; then
        pass "Hint includes an example script filename"
    else
        fail "Should include example filename, got: '$output'"
    fi

    if echo "$output" | grep -q "setup-hostmcp.py"; then
        pass "Hint tells the user how to fix it (setup-hostmcp.py)"
    else
        fail "Should mention setup-hostmcp.py as the fix, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: HostMCP registered but offline (exit 2) -> hint mentions host-tools
# ============================================================
test_offline_hints() {
    echo ""
    echo "=== Testing offline HostMCP ==="

    setup_fake_workspace
    echo "#!/bin/bash" > "$FAKE_WORKSPACE/.sandbox/host-tools/run-host-setup-tests.sh"
    chmod +x "$FAKE_WORKSPACE/.sandbox/host-tools/run-host-setup-tests.sh"
    make_stub_check_script "$FAKE_WORKSPACE" 2

    local output
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        HOSTMCP_CHECK_SCRIPT="$FAKE_WORKSPACE/stub-setup-hostmcp.sh" \
        bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "host-tools"; then
        pass "Hint mentions host-tools when offline"
    else
        fail "Should mention host-tools, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: check script hangs (e.g. VS Code port-forward stuck) -> the outer
# script must still return well within Go's 5s runSetupScripts() budget,
# and still surface the hint (a hang is itself evidence of "not usable now").
# チェックスクリプトがハングする場合（VS Codeのポートフォワード固着など）でも、
# Go側runSetupScripts()の5秒予算内に確実に収まり、ヒントも出力すること
# （ハング自体が「今は使えない」ことの証拠なので、ヒントは出す）。
# ============================================================
test_hanging_check_script_still_hints_within_budget() {
    echo ""
    echo "=== Testing hanging check script ==="

    setup_fake_workspace
    echo "#!/bin/bash" > "$FAKE_WORKSPACE/.sandbox/host-tools/run-host-setup-tests.sh"
    chmod +x "$FAKE_WORKSPACE/.sandbox/host-tools/run-host-setup-tests.sh"
    cat > "$FAKE_WORKSPACE/stub-setup-hostmcp.sh" <<'EOF'
#!/bin/bash
[ "$1" = "--check" ] || exit 99
sleep 30
exit 2
EOF
    chmod +x "$FAKE_WORKSPACE/stub-setup-hostmcp.sh"

    local start_time end_time elapsed output
    start_time=$(date +%s)
    output=$(WORKSPACE="$FAKE_WORKSPACE" \
        HOSTMCP_CHECK_SCRIPT="$FAKE_WORKSPACE/stub-setup-hostmcp.sh" \
        timeout 5 bash "$TARGET_SCRIPT")
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    if [ "$elapsed" -lt 5 ]; then
        pass "Returns well within the outer 5s budget even when the check hangs (took ${elapsed}s)"
    else
        fail "Should return in under 5s even when the check hangs, took ${elapsed}s"
    fi

    if echo "$output" | grep -q "host-tools"; then
        pass "Still hints when the check script hangs"
    else
        fail "Should still hint on a hanging check script, got: '$output'"
    fi

    teardown
}

# ============================================================
# Test: script's own exit code is always 0 (a non-zero exit makes
# runSetupScripts() discard the output even if it printed a hint)
# 自スクリプトの終了コードは常に0であること
# （非0だとヒントを出力していてもrunSetupScripts()に破棄される）
# ============================================================
test_always_exits_zero() {
    echo ""
    echo "=== Testing script always exits 0 ==="

    setup_fake_workspace
    echo "#!/bin/bash" > "$FAKE_WORKSPACE/.sandbox/host-tools/some-tool.sh"
    chmod +x "$FAKE_WORKSPACE/.sandbox/host-tools/some-tool.sh"

    for code in 0 1 2; do
        make_stub_check_script "$FAKE_WORKSPACE" "$code"
        WORKSPACE="$FAKE_WORKSPACE" \
            HOSTMCP_CHECK_SCRIPT="$FAKE_WORKSPACE/stub-setup-hostmcp.sh" \
            bash "$TARGET_SCRIPT" >/dev/null
        if [ "$?" -eq 0 ]; then
            pass "Exits 0 when check script exits $code"
        else
            fail "Should exit 0 when check script exits $code, got $?"
        fi
    done

    teardown
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "hostmcp-host-tools-hint Setup Script Tests"
    echo "========================================"

    test_script_executable
    test_no_host_tools_silent
    test_missing_check_script_silent
    test_connected_silent
    test_not_registered_hints
    test_offline_hints
    test_hanging_check_script_still_hints_within_budget
    test_always_exits_zero

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

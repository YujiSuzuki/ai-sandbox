#!/bin/bash
# test-startup-hostmcp.sh
# Test HostMCP auto-registration logic in startup.sh
#
# Tests the step 8 behavior:
#   - Registered + connected: one-liner summary
#   - Registered but offline: one-liner warning
#   - Not registered: full registration output
#
# Uses stub scripts to isolate from real startup dependencies.
#
# Usage: ./test-startup-hostmcp.sh
#
# Environment: AI Sandbox (requires /workspace)
# ---
# startup.sh の HostMCP 自動登録ロジックのテスト
#
# ステップ8の動作をテスト:
#   - 登録済み＋接続OK: 1行サマリー
#   - 登録済みだがオフライン: 1行警告
#   - 未登録: フル登録出力
#
# スタブスクリプトで実際の起動処理から分離してテスト。
#
# 使用方法: ./test-startup-hostmcp.sh
# 実行環境: AI Sandbox（/workspace が必要）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STARTUP_SCRIPT="$SCRIPT_DIR/startup.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}✅ $1${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}❌ $1${NC}"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# ─── Setup / Cleanup ────────────────────────────────────────

TEST_DIR=""

setup() {
    unset WORKSPACE
    TEST_DIR=$(mktemp -d)

    # Create stub scripts directory mirroring .sandbox/scripts/
    mkdir -p "$TEST_DIR/workspace/.sandbox/scripts"

    # Create no-op stubs for steps 1-5 (not under test)
    for script in merge-claude-settings.sh compare-secret-config.sh \
                  validate-secrets.sh check-secret-sync.sh check-upstream-updates.sh; do
        cat > "$TEST_DIR/workspace/.sandbox/scripts/$script" << 'STUB'
#!/bin/bash
exit 0
STUB
        chmod +x "$TEST_DIR/workspace/.sandbox/scripts/$script"
    done

    # Create no-op stub for _startup_common.sh
    cat > "$TEST_DIR/workspace/.sandbox/scripts/_startup_common.sh" << 'STUB'
#!/bin/bash
# Stub: no-op common functions
STUB

    # Create stub bin directory for go/claude/gemini (default stubs; overridden in SandboxMCP-specific tests)
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/go" << 'STUB'
#!/bin/bash
# Stub: go install succeeds silently
exit 0
STUB
    cat > "$TEST_DIR/bin/claude" << 'STUB'
#!/bin/bash
# Stub: claude mcp add succeeds silently
exit 0
STUB
    cat > "$TEST_DIR/bin/gemini" << 'STUB'
#!/bin/bash
# Stub: gemini mcp add succeeds silently
exit 0
STUB
    chmod +x "$TEST_DIR/bin/go" "$TEST_DIR/bin/claude" "$TEST_DIR/bin/gemini"
    export PATH="$TEST_DIR/bin:$PATH"

    # Copy actual startup.sh and rewrite paths to use test directory
    sed "s|/workspace|$TEST_DIR/workspace|g" "$STARTUP_SCRIPT" \
        > "$TEST_DIR/workspace/.sandbox/scripts/startup.sh"
    chmod +x "$TEST_DIR/workspace/.sandbox/scripts/startup.sh"
}

cleanup() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
    TEST_DIR=""
}

trap cleanup EXIT

# Helper: create setup-hostmcp.sh stub with specified exit codes
# --check 時と通常実行時の exit code をそれぞれ指定
create_hostmcp_stub() {
    local check_exit="$1"     # exit code for --check
    local register_exit="${2:-0}"  # exit code for default mode (register)
    local register_output="${3:-HostMCP full registration output}"  # output for default mode

    cat > "$TEST_DIR/workspace/.sandbox/scripts/setup-hostmcp.sh" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "--check" ]; then
        exit $check_exit
    fi
done
echo "$register_output"
exit $register_exit
STUB
    chmod +x "$TEST_DIR/workspace/.sandbox/scripts/setup-hostmcp.sh"
}

# ─── Tests ──────────────────────────────────────────────────

# Test 0: SandboxMCP registration shows per-CLI success/failure output
test_sandboxmcp_registration_output() {
    echo ""
    echo "=== Test: SandboxMCP registration shows per-CLI output ==="

    setup
    create_hostmcp_stub 0

    # claude succeeds, gemini fails
    cat > "$TEST_DIR/bin/claude" << 'STUB'
#!/bin/bash
exit 0
STUB
    cat > "$TEST_DIR/bin/gemini" << 'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$TEST_DIR/bin/claude" "$TEST_DIR/bin/gemini"

    local output
    output=$(bash "$TEST_DIR/workspace/.sandbox/scripts/startup.sh" 2>&1)

    if echo "$output" | grep -q "\[Claude\].*registered\|\[Claude\].*登録済み"; then
        pass "Shows [Claude] success message"
    else
        fail "Should show [Claude] success message"
    fi

    if echo "$output" | grep -q "\[Gemini\].*failed\|\[Gemini\].*失敗"; then
        pass "Shows [Gemini] failure message"
    else
        fail "Should show [Gemini] failure message"
    fi

    cleanup
}

# Test: When sandbox-mcp is already installed, skip go install and show already-installed message
test_sandboxmcp_skip_when_already_installed() {
    echo ""
    echo "=== Test: Skip go install when sandbox-mcp already installed ==="

    setup
    create_hostmcp_stub 0

    # Add sandbox-mcp stub to PATH so command -v sandbox-mcp succeeds
    cat > "$TEST_DIR/bin/sandbox-mcp" << 'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$TEST_DIR/bin/sandbox-mcp"

    # Make go stub fail if called (should be skipped)
    cat > "$TEST_DIR/bin/go" << 'STUB'
#!/bin/bash
echo "UNEXPECTED: go install was called"
exit 1
STUB
    chmod +x "$TEST_DIR/bin/go"

    local output
    output=$(bash "$TEST_DIR/workspace/.sandbox/scripts/startup.sh" 2>&1)

    if echo "$output" | grep -q "UNEXPECTED: go install was called"; then
        fail "Should skip go install when sandbox-mcp is already installed"
    else
        pass "Skips go install when sandbox-mcp is already installed"
    fi

    if echo "$output" | grep -q "already installed\|既にインストール済み"; then
        pass "Shows already-installed message"
    else
        fail "Should show already-installed message"
    fi

    cleanup
}


# Test 1: When --check returns 0 (registered + connected), shows one-liner with "connected"
test_oneliner_when_registered_and_connected() {
    echo ""
    echo "=== Test: One-liner when HostMCP is registered and connected ==="

    setup
    create_hostmcp_stub 0

    local output
    output=$(bash "$TEST_DIR/workspace/.sandbox/scripts/startup.sh" 2>&1)

    # Should show one-liner with HostMCP and connected
    if echo "$output" | grep -q "HostMCP.*connected\|HostMCP.*接続OK"; then
        pass "Shows one-liner with connected status"
    else
        fail "Should show one-liner with connected status"
    fi

    # Should NOT show full registration output
    if echo "$output" | grep -q "HostMCP full registration output"; then
        fail "Should not show full registration output when already registered"
    else
        pass "Does not show full registration output"
    fi

    cleanup
}

# Test 2: When --check returns 2 (registered but offline), shows one-liner warning
test_oneliner_when_registered_but_offline() {
    echo ""
    echo "=== Test: One-liner warning when HostMCP is registered but offline ==="

    setup
    create_hostmcp_stub 2

    local output
    output=$(bash "$TEST_DIR/workspace/.sandbox/scripts/startup.sh" 2>&1)

    # Should show one-liner with not reachable / offline warning
    if echo "$output" | grep -q "HostMCP.*not reachable\|HostMCP.*接続不可"; then
        pass "Shows one-liner with offline warning"
    else
        fail "Should show one-liner with offline warning"
    fi

    # Should NOT show full registration output
    if echo "$output" | grep -q "HostMCP full registration output"; then
        fail "Should not show full registration output when already registered"
    else
        pass "Does not show full registration output"
    fi

    cleanup
}

# Test 3: When --check returns 1 (not registered), runs full registration
test_full_output_when_not_registered() {
    echo ""
    echo "=== Test: Full registration when HostMCP is not registered ==="

    setup
    create_hostmcp_stub 1 0 "HostMCP full registration output"

    local output
    output=$(bash "$TEST_DIR/workspace/.sandbox/scripts/startup.sh" 2>&1)

    if echo "$output" | grep -q "HostMCP full registration output"; then
        pass "Runs full registration and shows output when not registered"
    else
        fail "Should show full registration output, but it was missing"
    fi

    cleanup
}

# Test 4: When registration fails, shows error message and continues
test_registration_failure_continues() {
    echo ""
    echo "=== Test: Registration failure shows error and continues ==="

    setup
    create_hostmcp_stub 1 1 "some error"

    local output
    local exit_code=0
    output=$(bash "$TEST_DIR/workspace/.sandbox/scripts/startup.sh" 2>&1) || exit_code=$?

    # Should contain the failure message
    if echo "$output" | grep -qi "HostMCP.*failed\|HostMCP.*失敗"; then
        pass "Registration failure shows error message"
    else
        fail "Registration failure did not show error message"
    fi

    # Should still complete (not crash)
    if echo "$output" | grep -qi "complete\|完了"; then
        pass "Startup completes even after HostMCP registration failure"
    else
        fail "Startup did not complete after HostMCP registration failure"
    fi

    cleanup
}

# Test 5: Startup completes successfully with HostMCP step
test_startup_completes_with_hostmcp() {
    echo ""
    echo "=== Test: Startup completes with HostMCP step ==="

    setup
    create_hostmcp_stub 0

    local exit_code=0
    bash "$TEST_DIR/workspace/.sandbox/scripts/startup.sh" >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        pass "Startup completes with exit 0"
    else
        fail "Startup exited with $exit_code, expected 0"
    fi

    cleanup
}

# ─── Main ───────────────────────────────────────────────────

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  startup.sh HostMCP Auto-Registration Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    test_sandboxmcp_registration_output
    test_sandboxmcp_skip_when_already_installed
    test_oneliner_when_registered_and_connected
    test_oneliner_when_registered_but_offline
    test_full_output_when_not_registered
    test_registration_failure_continues
    test_startup_completes_with_hostmcp

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ "$TESTS_FAILED" -gt 0 ]; then
        exit 1
    fi
}

main "$@"

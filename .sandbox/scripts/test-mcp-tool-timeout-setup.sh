#!/bin/bash
# test-mcp-tool-timeout-setup.sh
# Test .sandbox/sandbox-mcp-setup/50-mcp-tool-timeout.sh behavior
# .sandbox/sandbox-mcp-setup/50-mcp-tool-timeout.sh の動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TARGET_SCRIPT="$WORKSPACE/.sandbox/sandbox-mcp-setup/50-mcp-tool-timeout.sh"

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
        pass "50-mcp-tool-timeout.sh exists"
    else
        fail "50-mcp-tool-timeout.sh does not exist"
        return
    fi

    if [ -x "$TARGET_SCRIPT" ]; then
        pass "50-mcp-tool-timeout.sh is executable"
    else
        fail "50-mcp-tool-timeout.sh should be executable"
    fi
}

# ============================================================
# Test: MCP_TOOL_TIMEOUT unset -> reports the 60s HTTP/SSE default
# ============================================================
test_unset_reports_default() {
    echo ""
    echo "=== Testing MCP_TOOL_TIMEOUT unset ==="

    local output
    output=$(env -u MCP_TOOL_TIMEOUT bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "60s default"; then
        pass "Reports the 60s default when MCP_TOOL_TIMEOUT is unset"
    else
        fail "Expected the 60s default to be reported, got: $output"
    fi
}

# ============================================================
# Test: MCP_TOOL_TIMEOUT set (ms) -> converts to seconds correctly
# ============================================================
test_set_converts_ms_to_seconds() {
    echo ""
    echo "=== Testing MCP_TOOL_TIMEOUT=300000 (ms) ==="

    local output
    output=$(MCP_TOOL_TIMEOUT=300000 bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "300s"; then
        pass "Converts 300000ms to 300s"
    else
        fail "Expected 300s in output, got: $output"
    fi

    if echo "$output" | grep -q "MCP_TOOL_TIMEOUT=300000ms"; then
        pass "Echoes the raw MCP_TOOL_TIMEOUT value back"
    else
        fail "Expected raw MCP_TOOL_TIMEOUT value in output, got: $output"
    fi
}

# ============================================================
# Test: MCP_TOOL_TIMEOUT set to a non-numeric value -> falls back to default
# ============================================================
test_malformed_value_falls_back_to_default() {
    echo ""
    echo "=== Testing MCP_TOOL_TIMEOUT=not-a-number ==="

    local output
    output=$(MCP_TOOL_TIMEOUT="not-a-number" bash "$TARGET_SCRIPT")

    if echo "$output" | grep -q "60s default"; then
        pass "Falls back to the 60s default for a non-numeric MCP_TOOL_TIMEOUT"
    else
        fail "Expected fallback to the 60s default, got: $output"
    fi

    # A malformed-but-set value is not the same state as "unset" -- the message
    # must say so, otherwise debugging a bad MCP_TOOL_TIMEOUT looks identical to
    # never having set it at all.
    if echo "$output" | grep -q "invalid value 'not-a-number'"; then
        pass "Reports the invalid value distinctly, not as 'unset'"
    else
        fail "Expected the message to call out the invalid value (not claim 'unset'), got: $output"
    fi
    if echo "$output" | grep -q "is unset"; then
        fail "Malformed MCP_TOOL_TIMEOUT was misreported as 'unset', got: $output"
    else
        pass "Does not misreport the malformed value as 'unset'"
    fi
}

# ============================================================
# Test: MCP_TOOL_TIMEOUT with a leading zero -> parsed as base-10, not octal
# ============================================================
test_leading_zero_parsed_as_base_10() {
    echo ""
    echo "=== Testing MCP_TOOL_TIMEOUT=0100000 (leading zero) ==="

    local output
    output=$(MCP_TOOL_TIMEOUT=0100000 bash "$TARGET_SCRIPT")

    # 0100000 must be read as decimal 100000ms (=100s), not bash's octal
    # interpretation of a leading-zero literal (which would silently yield 32s).
    if echo "$output" | grep -q "100s"; then
        pass "Leading-zero MCP_TOOL_TIMEOUT is parsed as base-10 (100000ms -> 100s)"
    else
        fail "Expected 100s (base-10 parse of 0100000), got: $output"
    fi

    # A value containing 8/9 is invalid octal but valid decimal; naive octal
    # arithmetic (bash's default for a leading-zero literal) crashes on it.
    local output2 exit_code2
    output2=$(MCP_TOOL_TIMEOUT=008000 bash "$TARGET_SCRIPT" 2>&1)
    exit_code2=$?
    if [ "$exit_code2" -eq 0 ] && echo "$output2" | grep -q "8s"; then
        pass "MCP_TOOL_TIMEOUT with 8/9 digits (008000) does not crash and parses as base-10"
    else
        fail "Expected exit 0 and 8s reported for 008000, got exit $exit_code2: $output2"
    fi
}

# ============================================================
# Test: Output always mentions the escape hatch (hostmcp client --timeout)
# ============================================================
test_mentions_escape_hatch() {
    echo ""
    echo "=== Testing output mentions the hostmcp client workaround ==="

    local output_unset output_set
    output_unset=$(env -u MCP_TOOL_TIMEOUT bash "$TARGET_SCRIPT")
    output_set=$(MCP_TOOL_TIMEOUT=300000 bash "$TARGET_SCRIPT")

    if echo "$output_unset" | grep -q "hostmcp client" && echo "$output_set" | grep -q "hostmcp client"; then
        pass "Both branches mention the 'hostmcp client --timeout' workaround"
    else
        fail "Expected both branches to mention 'hostmcp client', got unset: '$output_unset' / set: '$output_set'"
    fi
}

# ============================================================
# Test: Output tells the AI to pass client_timeout_seconds to run_host_tool
# ============================================================
test_mentions_client_timeout_seconds() {
    echo ""
    echo "=== Testing output mentions client_timeout_seconds ==="

    local output_unset output_set
    output_unset=$(env -u MCP_TOOL_TIMEOUT bash "$TARGET_SCRIPT")
    output_set=$(MCP_TOOL_TIMEOUT=300000 bash "$TARGET_SCRIPT")

    # hostmcp's run_host_tool now refuses to run a tool whose own timeout
    # exceeds its global default unless client_timeout_seconds is passed --
    # the AI needs this value (in seconds) from this hint script to supply it.
    if echo "$output_unset" | grep -q "client_timeout_seconds" && echo "$output_set" | grep -q "client_timeout_seconds"; then
        pass "Both branches mention client_timeout_seconds"
    else
        fail "Expected both branches to mention client_timeout_seconds, got unset: '$output_unset' / set: '$output_set'"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "mcp-tool-timeout Setup Script Tests"
    echo "========================================"

    test_script_executable
    test_unset_reports_default
    test_set_converts_ms_to_seconds
    test_malformed_value_falls_back_to_default
    test_leading_zero_parsed_as_base_10
    test_mentions_escape_hatch
    test_mentions_client_timeout_seconds

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

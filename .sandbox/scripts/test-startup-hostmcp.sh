#!/bin/bash
# test-startup-hostmcp.sh
# Test HostMCP and SandboxMCP auto-registration logic in startup.sh
#
# Tests the step 7 (SandboxMCP) behavior:
#   - Already installed: skip go install
#   - Go available: go install
#   - Go unavailable: download prebuilt binary from GitHub Releases (success/failure)
#
# Tests the step 9 (HostMCP) behavior:
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
# startup.sh の HostMCP / SandboxMCP 自動登録ロジックのテスト
#
# ステップ7（SandboxMCP）の動作をテスト:
#   - インストール済み: go install をスキップ
#   - Go がある: go install
#   - Go がない: GitHub Releases からビルド済みバイナリをダウンロード（成功/失敗）
#
# ステップ9（HostMCP）の動作をテスト:
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

    # Create _startup_common.sh stub: no-op for everything except
    # install_sandbox_mcp_binary, which is extracted (not duplicated) from the
    # real file since the binary-download tests below exercise its actual logic.
    {
        echo '#!/bin/bash'
        echo '# Stub: no-op common functions, except install_sandbox_mcp_binary (extracted below)'
        awk '/^install_sandbox_mcp_binary\(\)/,/^}/' "$SCRIPT_DIR/_startup_common.sh"
    } > "$TEST_DIR/workspace/.sandbox/scripts/_startup_common.sh"

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

    # step 8 (hostmcp CLI install) independently calls `go install` when
    # hostmcp isn't on PATH, unrelated to the SandboxMCP step under test.
    # Stub it as already-installed so step 8 doesn't hit the go stub below.
    cat > "$TEST_DIR/bin/hostmcp" << 'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$TEST_DIR/bin/hostmcp"

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


# Build a PATH dir with symlinks to every real binary except go/gofmt/claude/
# gemini/curl, so "no go" tests behave the same regardless of where this host
# installs Go (e.g. /usr/local/go/bin on a devcontainer vs. /usr/bin on CI
# images that apt-install golang-go). Without this, appending the raw system
# dirs (/usr/bin:/bin) to PATH can leak a real `go`, so `command -v go` in
# startup.sh unexpectedly succeeds for real and the script takes the go-install
# branch instead of the binary-download branch this test means to exercise —
# and a real `go install` then actually runs, hitting the network and leaving
# a read-only Go module cache that later trips up plain `rm -rf` cleanup.
# claude/gemini are excluded too: a real one under /usr/local/bin would
# otherwise shadow this test's own fake stubs in $TEST_DIR/bin, since $mb is
# listed before $TEST_DIR/bin in the PATH these tests construct.
# 実際のgoバイナリがこのホストのどこにインストールされているかによらず
# 「goがない」テストが同じ結果になるよう、go/gofmt/claude/gemini/curl以外の
# 実バイナリへのシンボリックリンクを持つPATH用ディレクトリを作る（例:
# devcontainerでは/usr/local/go/bin、golang-goをaptで入れる一部のCIイメージ
# では/usr/bin）。これがないと、生のシステムディレクトリ(/usr/bin:/bin)を
# PATHに追加した際に本物のgoが漏れてしまい、startup.sh内の`command -v go`が
# 本当に成功してしまう結果、このテストが検証したいバイナリダウンロード分岐
# ではなくgo installの分岐を通ってしまう — そして本物の`go install`が実際に
# ネットワークにアクセスして実行され、読み取り専用のGoモジュールキャッシュが
# 残り、後の`rm -rf`によるクリーンアップが失敗する原因になる。
# claude/geminiも除外対象に含める: これらのテストが組み立てるPATHでは$mbが
# $TEST_DIR/binより前に来るため、除外しないと/usr/local/bin配下の実バイナリ
# がこのテスト自身の偽スタブ($TEST_DIR/bin)を覆い隠してしまう。
_isolate_go_absent() {
    local _mb_var="$1"
    local _mb
    _mb=$(mktemp -d)
    eval "$_mb_var='$_mb'"

    local dir base f
    for dir in /bin /usr/bin /usr/local/bin /opt/homebrew/bin; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            case "$base" in
                go|gofmt|claude|gemini|curl) continue ;;
            esac
            [ -e "$_mb/$base" ] && continue
            ln -sf "$f" "$_mb/$base" 2>/dev/null
        done
    done
}

# Helper: remove the default go stub and add a mock curl for binary-download tests
# デフォルトの go スタブを削除し、バイナリダウンロードテスト用のモック curl を追加
#
# Named _new_mb (not _mb) so it doesn't collide with _isolate_go_absent's own
# internal `local _mb` — eval-assigning through a same-named local would
# silently write to the helper's local instead of this function's variable
# (same hazard as _setup_binary_download_mocks in test-install-hostmcp.sh).
# _isolate_go_absent 内部の `local _mb` と衝突しないよう _mb ではなく _new_mb と
# いう名前にしている — 同名の local だと eval 代入がこの関数の変数ではなく
# ヘルパー側のローカル変数に対して行われてしまう
# （test-install-hostmcp.sh の _setup_binary_download_mocks と同じ問題）。
_setup_sandboxmcp_binary_download_mocks() {
    local _mb_var="$1"
    local _new_mb
    _isolate_go_absent _new_mb
    eval "$_mb_var='$_new_mb'"

    rm -f "$TEST_DIR/bin/go"

    # Fake curl: writes a stub file to the -o target path
    cat > "$_new_mb/curl" << 'CURLEOF'
#!/bin/bash
out=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-o" ] && out="$arg"
    prev="$arg"
done
if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '#!/bin/bash\nexit 0\n' > "$out"
fi
exit 0
CURLEOF
    chmod +x "$_new_mb/curl"
}

# Test: no go, curl succeeds → binary downloaded and registration proceeds
test_sandboxmcp_no_go_binary_download_success() {
    echo ""
    echo "=== Test: no go, curl succeeds → binary downloaded, registration proceeds ==="

    setup
    create_hostmcp_stub 0
    local mb fake_home
    _setup_sandboxmcp_binary_download_mocks mb
    fake_home=$(mktemp -d)

    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:$TEST_DIR/bin'
        bash '$TEST_DIR/workspace/.sandbox/scripts/startup.sh'
    " 2>&1)

    if echo "$output" | grep -q "Go not found\|Go が見つかりません"; then
        pass "Shows Go-not-found message"
    else
        fail "Expected Go-not-found message, got: $output"
    fi

    if echo "$output" | grep -q "installed to\|インストールしました"; then
        pass "Shows binary install success message"
    else
        fail "Expected install success message, got: $output"
    fi

    if echo "$output" | grep -q "\[Claude\].*registered\|\[Claude\].*登録済み"; then
        pass "Registration proceeds after successful binary download"
    else
        fail "Expected registration to proceed, got: $output"
    fi

    rm -rf "$mb" "$fake_home"
    cleanup
}

# Test: no go, curl fails → download failure message, registration skipped
test_sandboxmcp_no_go_binary_download_failure() {
    echo ""
    echo "=== Test: no go, curl fails → download failure, registration skipped ==="

    setup
    create_hostmcp_stub 0
    local mb fake_home
    _setup_sandboxmcp_binary_download_mocks mb
    fake_home=$(mktemp -d)

    # Override curl to fail
    printf '#!/bin/bash\nexit 1\n' > "$mb/curl"
    chmod +x "$mb/curl"

    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:$TEST_DIR/bin'
        bash '$TEST_DIR/workspace/.sandbox/scripts/startup.sh'
    " 2>&1)

    if echo "$output" | grep -q "Download failed\|ダウンロードに失敗"; then
        pass "Shows download failure message"
    else
        fail "Expected download failure message, got: $output"
    fi

    if echo "$output" | grep -q "\[Claude\]"; then
        fail "Registration should NOT proceed after failed binary download"
    else
        pass "Registration skipped after failed binary download"
    fi

    if echo "$output" | grep -qi "complete\|完了"; then
        pass "Startup still completes after binary download failure"
    else
        fail "Startup did not complete after binary download failure"
    fi

    rm -rf "$mb" "$fake_home"
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
    test_sandboxmcp_no_go_binary_download_success
    test_sandboxmcp_no_go_binary_download_failure
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

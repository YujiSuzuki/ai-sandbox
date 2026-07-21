#!/bin/bash
# test-check-sandbox-mcp-updates.sh
# Test sandbox-mcp binary update check functionality
# sandbox-mcp バイナリの更新チェック機能のテスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

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
info() { echo -e "${YELLOW}INFO${NC}: $1"; }

# Temp directory for tests
TEST_TMP_DIR=""
FAKE_BIN_DIR=""

setup() {
    TEST_TMP_DIR=$(mktemp -d)
    mkdir -p "$TEST_TMP_DIR/.sandbox/config"
    mkdir -p "$TEST_TMP_DIR/.sandbox/scripts"
    # Symlink shared files so mock WORKSPACE can source them
    ln -sf "$WORKSPACE/.sandbox/scripts/_startup_common.sh" "$TEST_TMP_DIR/.sandbox/scripts/_startup_common.sh"
    ln -sf "$WORKSPACE/.sandbox/config/startup.conf" "$TEST_TMP_DIR/.sandbox/config/startup.conf" 2>/dev/null || true

    # Fake `sandbox-mcp` binary directory, prepended to PATH in tests that need
    # an "installed" binary without depending on the real one.
    # フェイク sandbox-mcp バイナリ用ディレクトリ。実バイナリに依存せず
    # 「インストール済み」状態をテストするために PATH の先頭に追加する。
    FAKE_BIN_DIR="$TEST_TMP_DIR/bin"
    mkdir -p "$FAKE_BIN_DIR"
}

teardown() {
    [ -n "$TEST_TMP_DIR" ] && rm -rf "$TEST_TMP_DIR"
}

# Build a directory of symlinks to every real binary except go/gofmt, so tests
# simulating "go not installed" work regardless of where this host's go binary
# lives -- including hosts with more than one copy installed at once (e.g.
# both /usr/local/go/bin and an apt-installed golang-go under /usr/bin, as
# seen on some CI images). Every candidate directory must be scanned
# directly, since a single `command -v go` lookup only reports one location
# and would leave any other real `go` on PATH reachable.
# go/gofmt 以外の全実行ファイルへのシンボリックリンクを集めたディレクトリを作る。
# 「go 未インストール」を模擬するテストが、このホストの go の設置場所によらず、
# go が複数箇所（例: /usr/local/go/bin と、apt で golang-go を入れる一部の
# CI イメージにある /usr/bin の両方）に入っていても成立するようにするため。
# `command -v go` は1箇所しか報告しないため、候補ディレクトリそれぞれを
# 直接スキャンする必要がある（さもないと他の場所にある本物の go が
# PATH 上に残ってしまう）。
path_without_real_go() {
    local iso_dir="$TEST_TMP_DIR/go-isolated-bin"
    mkdir -p "$iso_dir"
    local dir f base
    for dir in /bin /usr/bin /usr/local/bin /opt/homebrew/bin; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            case "$base" in
                go|gofmt) continue ;;
            esac
            [ -e "$iso_dir/$base" ] && continue
            ln -sf "$f" "$iso_dir/$base" 2>/dev/null
        done
    done
    echo "$iso_dir"
}

# Create a fake `sandbox-mcp` executable that prints a fixed version
# 固定バージョンを出力するフェイク sandbox-mcp 実行ファイルを作成
make_fake_sandbox_mcp() {
    local version="$1"
    cat > "$FAKE_BIN_DIR/sandbox-mcp" <<EOF
#!/bin/bash
if [ "\$1" = "version" ]; then
    echo "sandbox-mcp ${version}"
fi
EOF
    chmod +x "$FAKE_BIN_DIR/sandbox-mcp"
}

# ============================================================
# Test: Script is executable
# ============================================================
test_script_executable() {
    echo ""
    echo "=== Testing script is executable ==="

    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"

    if [ -f "$script" ]; then
        pass "check-sandbox-mcp-updates.sh exists"
    else
        fail "check-sandbox-mcp-updates.sh does not exist"
        return
    fi

    if [ -x "$script" ]; then
        pass "check-sandbox-mcp-updates.sh is executable"
    else
        fail "check-sandbox-mcp-updates.sh should be executable"
    fi

    if head -1 "$script" | grep -q "^#!/bin/bash"; then
        pass "check-sandbox-mcp-updates.sh has correct shebang"
    else
        fail "check-sandbox-mcp-updates.sh should have #!/bin/bash shebang"
    fi
}

# ============================================================
# Test: sandbox-mcp not on PATH -> silent skip, no state file
# ============================================================
test_not_installed_skips() {
    echo ""
    echo "=== Testing not-installed skip behavior ==="

    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-not-installed"
    rm -f "$mock_state"

    local stdout_output exit_code
    stdout_output=$( (PATH="/nonexistent" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" "$script") 2>/dev/null )
    exit_code=$?

    if [ -z "$stdout_output" ]; then
        pass "No output when sandbox-mcp is not on PATH"
    else
        fail "Should produce no output when not installed, got: '$stdout_output'"
    fi

    if [ "$exit_code" -eq 0 ]; then
        pass "Exits cleanly (0) when sandbox-mcp is not on PATH"
    else
        fail "Should exit 0 when not installed, got $exit_code"
    fi

    if [ ! -f "$mock_state" ]; then
        pass "No state file created when sandbox-mcp is not installed"
    else
        fail "State file should not be created when not installed"
    fi
}

# ============================================================
# Test: installed version matches latest -> no notification
# ============================================================
test_same_version_no_notification() {
    echo ""
    echo "=== Testing same version (installed == latest) ==="

    make_fake_sandbox_mcp "v0.2.0"
    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-same"
    rm -f "$mock_state"

    local stdout_output
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=0 MOCK_LATEST_VERSION="v0.2.0" "$script") 2>/dev/null )

    if [ -z "$stdout_output" ]; then
        pass "No notification when installed version matches latest"
    else
        fail "Should produce no notification when versions match, got: '$stdout_output'"
    fi
}

# ============================================================
# Test: installed version differs from latest -> notification
# ============================================================
test_different_version_notifies() {
    echo ""
    echo "=== Testing different version (installed != latest) ==="

    make_fake_sandbox_mcp "v0.1.0"
    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-diff"
    rm -f "$mock_state"

    local stdout_output
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=0 MOCK_LATEST_VERSION="v0.2.0" "$script") 2>/dev/null )

    if echo "$stdout_output" | grep -q "v0.1.0" && echo "$stdout_output" | grep -q "v0.2.0"; then
        pass "Notification shows both current (v0.1.0) and latest (v0.2.0) version"
    else
        fail "Should notify with both versions, got: '$stdout_output'"
    fi

    if echo "$stdout_output" | grep -q "check-sandbox-mcp-updates.sh --auto-update"; then
        pass "Notification includes --auto-update update command"
    else
        fail "Should include --auto-update command, got: '$stdout_output'"
    fi

    # Re-checking immediately after (interval elapsed via CHECK_INTERVAL_HOURS=0) should notify again,
    # since ground truth (installed version) still differs -- unlike check-upstream-updates.sh's dedup.
    # インターバル経過後（CHECK_INTERVAL_HOURS=0）は再度通知される。インストール済みバージョンが
    # 実際にまだ古いままなので、check-upstream-updates.sh のような重複排除は行わない。
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=0 MOCK_LATEST_VERSION="v0.2.0" "$script") 2>/dev/null )
    if echo "$stdout_output" | grep -q "v0.1.0"; then
        pass "Re-notifies on next check while still on an outdated version"
    else
        fail "Should re-notify while outdated, got: '$stdout_output'"
    fi
}

# ============================================================
# Test: --auto-update is off by default (go/curl must not be invoked)
# ============================================================
test_auto_update_disabled_by_default() {
    echo ""
    echo "=== Testing auto-update is off by default ==="

    make_fake_sandbox_mcp "v0.1.0"
    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-no-autoupdate"
    rm -f "$mock_state"

    cat > "$FAKE_BIN_DIR/go" <<'EOF'
#!/bin/bash
echo "UNEXPECTED: go was called"
exit 1
EOF
    chmod +x "$FAKE_BIN_DIR/go"

    local stdout_output
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=0 MOCK_LATEST_VERSION="v0.2.0" "$script") 2>/dev/null )

    if echo "$stdout_output" | grep -q "UNEXPECTED: go was called"; then
        fail "Should not invoke go when --auto-update is not passed, got: '$stdout_output'"
    else
        pass "Does not attempt update when --auto-update / AUTO_UPDATE_SANDBOX_MCP is unset"
    fi
}

# ============================================================
# Test: --auto-update via go install, success (installed version changes)
# ============================================================
test_auto_update_go_install_success() {
    echo ""
    echo "=== Testing --auto-update via go install (success) ==="

    local version_file="$TEST_TMP_DIR/installed-version"
    echo "v0.1.0" > "$version_file"
    cat > "$FAKE_BIN_DIR/sandbox-mcp" <<EOF
#!/bin/bash
[ "\$1" = "version" ] && echo "sandbox-mcp \$(cat "$version_file")"
EOF
    chmod +x "$FAKE_BIN_DIR/sandbox-mcp"

    cat > "$FAKE_BIN_DIR/go" <<EOF
#!/bin/bash
echo "v0.2.0" > "$version_file"
exit 0
EOF
    chmod +x "$FAKE_BIN_DIR/go"

    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-autoupdate-go-ok"
    rm -f "$mock_state"

    local stdout_output exit_code
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=0 MOCK_LATEST_VERSION="v0.2.0" "$script" --auto-update) 2>/dev/null )
    exit_code=$?

    if echo "$stdout_output" | grep -q "updated to: v0.2.0\|を更新しました: v0.2.0"; then
        pass "Reports successful update to v0.2.0 via go install"
    else
        fail "Should report update success, got: '$stdout_output'"
    fi

    if [ "$exit_code" -eq 0 ]; then
        pass "Exits cleanly (0) after successful auto-update"
    else
        fail "Should exit 0 after successful auto-update, got $exit_code"
    fi
}

# ============================================================
# Test: --auto-update via go install, failure (go install itself fails)
# ============================================================
test_auto_update_go_install_failure() {
    echo ""
    echo "=== Testing --auto-update via go install (failure) ==="

    make_fake_sandbox_mcp "v0.1.0"

    # Simulate a genuine `go install` failure (e.g. network error): nonzero exit.
    # Success is judged by this exit status, not by version comparison -- `go
    # install pkg@latest` has no -ldflags and would never make the installed
    # version string match $latest even on a real success.
    # 実際の `go install` 失敗（ネットワークエラー等）を模擬: 非ゼロ終了。
    # 成否はこの終了コードで判定する（バージョン比較ではない）: 素の
    # `go install pkg@latest` には -ldflags が付かないため、実際に成功しても
    # インストール済みバージョン文字列は $latest と一致しない。
    cat > "$FAKE_BIN_DIR/go" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$FAKE_BIN_DIR/go"

    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-autoupdate-go-fail"
    rm -f "$mock_state"

    local stdout_output exit_code
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=0 MOCK_LATEST_VERSION="v0.2.0" "$script" --auto-update) 2>/dev/null )
    exit_code=$?

    if echo "$stdout_output" | grep -q "Auto-update failed\|自動更新に失敗しました"; then
        pass "Reports auto-update failure when go install itself fails"
    else
        fail "Should report auto-update failure, got: '$stdout_output'"
    fi

    if [ "$exit_code" -eq 0 ]; then
        pass "Still exits cleanly (0) after a failed auto-update"
    else
        fail "Should exit 0 even after failed auto-update, got $exit_code"
    fi

    if [ -f "$mock_state" ]; then
        pass "State file is still recorded after a failed auto-update"
    else
        fail "State file should be recorded even when auto-update fails"
    fi
}

# ============================================================
# Test: --auto-update falls back to prebuilt binary download when Go is absent
# ============================================================
test_auto_update_binary_download_fallback() {
    echo ""
    echo "=== Testing --auto-update binary download fallback (no go) ==="

    # Earlier tests may have left a `go` stub in FAKE_BIN_DIR; remove it so this
    # test genuinely exercises the "Go not found" fallback path.
    rm -f "$FAKE_BIN_DIR/go"

    local version_file="$TEST_TMP_DIR/installed-version-2"
    echo "v0.1.0" > "$version_file"
    cat > "$FAKE_BIN_DIR/sandbox-mcp" <<EOF
#!/bin/bash
[ "\$1" = "version" ] && echo "sandbox-mcp \$(cat "$version_file")"
EOF
    chmod +x "$FAKE_BIN_DIR/sandbox-mcp"

    # No go stub on PATH. Fake curl writes a stub binary reporting the new version.
    cat > "$FAKE_BIN_DIR/curl" <<EOF
#!/bin/bash
out=""
prev=""
for arg in "\$@"; do
    [ "\$prev" = "-o" ] && out="\$arg"
    prev="\$arg"
done
if [ -n "\$out" ]; then
    mkdir -p "\$(dirname "\$out")"
    echo "v0.2.0" > "$version_file"
    printf '#!/bin/bash\n[ "\$1" = "version" ] && echo "sandbox-mcp v0.2.0"\n' > "\$out"
    chmod +x "\$out"
fi
exit 0
EOF
    chmod +x "$FAKE_BIN_DIR/curl"

    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-autoupdate-binary"
    local fake_home="$TEST_TMP_DIR/fake-home"
    mkdir -p "$fake_home"
    rm -f "$mock_state"

    local stdout_output
    stdout_output=$( (HOME="$fake_home" PATH="$FAKE_BIN_DIR:$(path_without_real_go)" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=0 MOCK_LATEST_VERSION="v0.2.0" "$script" --auto-update) 2>/dev/null )

    if echo "$stdout_output" | grep -q "Go not found\|Go が見つかりません"; then
        pass "Falls back to binary download when go is not on PATH"
    else
        fail "Should report Go not found, got: '$stdout_output'"
    fi

    if echo "$stdout_output" | grep -q "updated to: v0.2.0\|を更新しました: v0.2.0"; then
        pass "Reports successful update to v0.2.0 via binary download"
    else
        fail "Should report update success via binary download, got: '$stdout_output'"
    fi
}

# ============================================================
# Test: interval throttling (reuses should_check from _startup_common.sh)
# ============================================================
test_interval_throttling() {
    echo ""
    echo "=== Testing interval throttling ==="

    make_fake_sandbox_mcp "v0.1.0"
    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-throttle"

    # Recent timestamp -> should not check again within interval
    echo "$(date +%s):v0.1.0" > "$mock_state"

    local stdout_output
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=24 MOCK_LATEST_VERSION="v0.2.0" "$script") 2>/dev/null )

    if [ -z "$stdout_output" ]; then
        pass "No notification when within interval, even if versions differ"
    else
        fail "Should not check within interval, got: '$stdout_output'"
    fi
}

# ============================================================
# Test: --auto-update bypasses interval throttling
# ============================================================
test_auto_update_bypasses_throttle() {
    echo ""
    echo "=== Testing --auto-update bypasses interval throttling ==="

    make_fake_sandbox_mcp "v0.1.0"
    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-throttle-autoupdate"

    # Recent timestamp -> a plain check would skip, but an explicit --auto-update
    # request must still run, since the user just asked for it directly.
    echo "$(date +%s):v0.1.0" > "$mock_state"

    cat > "$FAKE_BIN_DIR/go" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$FAKE_BIN_DIR/go"

    local stdout_output
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=24 MOCK_LATEST_VERSION="v0.2.0" "$script" --auto-update) 2>/dev/null )

    if [ -n "$stdout_output" ]; then
        pass "--auto-update produces output even within the throttle interval"
    else
        fail "--auto-update should bypass throttle, got no output"
    fi

    if echo "$stdout_output" | grep -q "updated to:\|を更新しました:"; then
        pass "--auto-update actually attempts the update despite the throttle interval"
    else
        fail "--auto-update should attempt update, got: '$stdout_output'"
    fi

    rm -f "$FAKE_BIN_DIR/go"
}

# ============================================================
# Test: fetch failure (no MOCK_LATEST_VERSION, unreachable API) skips silently
# ============================================================
test_fetch_failure_skips() {
    echo ""
    echo "=== Testing fetch failure skip behavior ==="

    make_fake_sandbox_mcp "v0.1.0"
    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local mock_state="$TEST_TMP_DIR/state-fetchfail"
    rm -f "$mock_state"

    # No MOCK_LATEST_VERSION set; force network failure via impossible connect timeout
    local stdout_output exit_code
    stdout_output=$( (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" \
        CHECK_INTERVAL_HOURS=0 MOCK_FORCE_FETCH_FAILURE=1 "$script") 2>/dev/null )
    exit_code=$?

    if [ -z "$stdout_output" ]; then
        pass "No notification on fetch failure"
    else
        fail "Should produce no notification on fetch failure, got: '$stdout_output'"
    fi

    if [ "$exit_code" -eq 0 ]; then
        pass "Exits cleanly (0) on fetch failure"
    else
        fail "Should exit 0 on fetch failure, got $exit_code"
    fi
}

# ============================================================
# Test: show_update_notification per verbosity mode
# ============================================================
test_show_update_notification() {
    echo ""
    echo "=== Testing show_update_notification verbosity ==="

    # shellcheck source=/dev/null
    source "$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh" 2>/dev/null || true
    setup_messages

    local output

    # Quiet mode: single line with version transition
    STARTUP_VERBOSITY="quiet"
    output=$(show_update_notification "v0.1.0" "v0.2.0")
    if echo "$output" | grep -q "v0.1.0 → v0.2.0"; then
        pass "Quiet mode shows version transition"
    else
        fail "Quiet mode should show 'v0.1.0 → v0.2.0', got: '$output'"
    fi

    local line_count
    line_count=$(echo "$output" | wc -l)
    if [ "$line_count" -eq 1 ]; then
        pass "Quiet mode outputs single line"
    else
        fail "Quiet mode should output 1 line, got $line_count"
    fi

    # Verbose mode: includes update command
    STARTUP_VERBOSITY="verbose"
    output=$(show_update_notification "v0.1.0" "v0.2.0")
    if echo "$output" | grep -q "check-sandbox-mcp-updates.sh --auto-update"; then
        pass "Verbose mode shows the --auto-update update command"
    else
        fail "Verbose mode should show --auto-update command, got: '$output'"
    fi
}

# ============================================================
# Test: script runs without error when CHECK_UPDATES=false
# ============================================================
test_script_runs() {
    echo ""
    echo "=== Testing script execution with CHECK_UPDATES=false ==="

    make_fake_sandbox_mcp "v0.1.0"
    local script="$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh"
    local exit_code

    (PATH="$FAKE_BIN_DIR:$PATH" WORKSPACE="$TEST_TMP_DIR" CHECK_UPDATES=false "$script" >/dev/null 2>&1)
    exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        pass "check-sandbox-mcp-updates.sh exits cleanly with CHECK_UPDATES=false"
    else
        fail "Should exit cleanly with CHECK_UPDATES=false, got exit code $exit_code"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "sandbox-mcp Update Check Tests"
    echo "========================================"

    setup

    test_script_executable
    test_not_installed_skips
    test_same_version_no_notification
    test_different_version_notifies
    test_auto_update_disabled_by_default
    test_auto_update_go_install_success
    test_auto_update_go_install_failure
    test_auto_update_binary_download_fallback
    test_interval_throttling
    test_auto_update_bypasses_throttle
    test_fetch_failure_skips
    test_show_update_notification
    test_script_runs

    teardown

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

#!/bin/bash
# test-install-hostmcp.sh
# Test script for install-hostmcp.sh
#
# install-hostmcp.sh のテストスクリプト
#
# Usage: ./test-install-hostmcp.sh
# 使用方法: ./test-install-hostmcp.sh
#
# Environment: Host OS (must NOT run inside AI Sandbox)
# 実行環境: ホスト OS（AI Sandbox 内では実行しないこと）

set -e

# Verify running on host OS (not inside AI Sandbox)
# ホスト OS 上での実行を確認（AI Sandbox 内ではない）
if [ -d "/workspace" ]; then
    echo "Error: This test must be run on the host OS, not inside AI Sandbox"
    echo "エラー: このテストはホスト OS 上で実行する必要があります（AI Sandbox 内では実行できません）"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/install-hostmcp.sh"
TEST_PROJECT=""

# Colors for output
# 出力用の色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color / 色なし

# Test counter
# テストカウンター
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
# ヘルパー関数
pass() {
    echo -e "${GREEN}✅ $1${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}❌ $1${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

# Remove a directory tree even if it contains read-only entries (e.g. a real
# `go install` accidentally populating a module cache, whose files/dirs Go
# marks read-only by design). Plain `rm -rf` cannot unlink those and would
# leave a wall of "Permission denied" noise burying the real test failure.
# 読み取り専用エントリ（例: go のモジュールキャッシュ）が混ざっていても
# 削除できるようにする。素の `rm -rf` では権限エラーが大量に出て
# 本来のテスト失敗が埋もれてしまうため。
safe_rm_rf() {
    for target in "$@"; do
        [ -e "$target" ] || continue
        chmod -R u+w "$target" 2>/dev/null
        rm -rf "$target"
    done
}

# Build a PATH dir with symlinks to every real binary except go/gofmt/hostmcp/
# curl/wget, so tests that assume "hostmcp not installed yet" behave the same
# regardless of what's actually installed on the machine running the test
# (e.g. a dev host that already has hostmcp installed system-wide in order to
# run HostMCP itself). Without this, `command -v hostmcp` / `command -v go`
# unexpectedly succeed for real, shifting the number of prompts the script
# asks and desyncing the piped answers from the questions they're meant to
# answer.
# go/gofmt/hostmcp/curl/wget 以外の実バイナリへのシンボリックリンクを持つ PATH を
# 作る。「hostmcp 未インストール」を前提とするテストが、実行するマシンに実際に
# 何がインストールされているかによらず同じ結果になるようにするため
# （例: HostMCP 自体を動かすために hostmcp がシステムにインストール済みの開発機）。
# これがないと `command -v hostmcp` / `command -v go` が実環境で本当に成功して
# しまい、スクリプトが尋ねるプロンプトの数がずれて、パイプで渡す回答が対応する
# 質問とずれてしまう。
_isolate_hostmcp_absent() {
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
                go|gofmt|hostmcp|curl|wget) continue ;;
            esac
            [ -e "$_mb/$base" ] && continue
            ln -sf "$f" "$_mb/$base" 2>/dev/null
        done
    done
}

# Setup test environment
# テスト環境のセットアップ
setup() {
    info "Setting up test environment..."
    TEST_PROJECT=$(mktemp -d)
}

# Cleanup test environment
# テスト環境のクリーンアップ
cleanup() {
    if [ -n "$TEST_PROJECT" ] && [ -d "$TEST_PROJECT" ]; then
        safe_rm_rf "$TEST_PROJECT"
    fi
    # Restore the real $HOME and remove the fake one if _setup_versioned_hostmcp_mock
    # isolated it for the test that just ran (see that function for why this
    # matters: forgetting it lets _upgrade_hostmcp resolve paths against the
    # real developer machine's home directory instead of a throwaway one).
    # _setup_versioned_hostmcp_mock がテストのために $HOME を隔離していた場合、
    # 実際の $HOME を復元し、偽の $HOME を削除する（理由は同関数のコメント参照:
    # これを忘れると _upgrade_hostmcp が使い捨てのディレクトリではなく、実際の
    # 開発機のホームディレクトリに対してパスを解決してしまう）。
    if [ -n "${_VERSIONED_MOCK_FAKE_HOME:-}" ]; then
        safe_rm_rf "$_VERSIONED_MOCK_FAKE_HOME"
        unset _VERSIONED_MOCK_FAKE_HOME
    fi
    if [ -n "${_VERSIONED_MOCK_REAL_HOME:-}" ]; then
        export HOME="$_VERSIONED_MOCK_REAL_HOME"
        unset _VERSIONED_MOCK_REAL_HOME
    fi
}

# Trap to ensure cleanup runs
# クリーンアップが必ず実行されるようトラップ設定
trap cleanup EXIT

# Test: Script is executable and has valid syntax
# テスト: スクリプトが実行可能で構文エラーがないか
test_script_executable_and_valid() {
    echo ""
    echo "=== Test: Script is executable and has valid syntax ==="

    if [ ! -f "$SCRIPT" ]; then
        fail "Script not found: $SCRIPT"
        return
    fi

    if [ ! -x "$SCRIPT" ]; then
        fail "Script is not executable"
        return
    fi

    if bash -n "$SCRIPT" 2>/dev/null; then
        pass "Script is executable and has valid syntax"
    else
        fail "Script has syntax errors"
    fi
}

# Test: --help option shows usage
# テスト: --help オプションが使用法を表示する
test_help_option() {
    echo ""
    echo "=== Test: --help option shows usage ==="

    local output
    output=$(bash "$SCRIPT" --help 2>&1)

    if echo "$output" | grep -q "project_root" && echo "$output" | grep -q "プロジェクトルート"; then
        pass "--help shows usage information"
    else
        fail "--help should show usage with project_root info, got: $output"
    fi
}

_setup_hostmcp_mocks() {
    local _fp_var="$1" _mb_var="$2"
    local _fp _mb
    _fp=$(mktemp -d)
    _mb=$(mktemp -d)
    eval "$_fp_var='$_fp'"
    eval "$_mb_var='$_mb'"

    # Fake go binary
    cat > "$_mb/go" << GOEOF
#!/bin/bash
if [ "\$1" = "env" ] && [ "\$2" = "GOPATH" ]; then
    echo "$_fp"
elif [ "\$1" = "install" ]; then
    mkdir -p "$_fp/bin"
    touch "$_fp/bin/hostmcp"
    chmod +x "$_fp/bin/hostmcp"
    exit 0
fi
GOEOF
    chmod +x "$_mb/go"

    # Default fake hostmcp (records calls, creates yaml on init)
    cat > "$_mb/hostmcp" << 'DKMCPEOF'
#!/bin/bash
if [ "$1" = "init" ]; then
    ws=""
    shift
    while [ $# -gt 0 ]; do
        [ "$1" = "--workspace" ] && ws="$2"
        shift
    done
    [ -n "$ws" ] && mkdir -p "$ws/.sandbox/config" && touch "$ws/.sandbox/config/hostmcp.yaml"
fi
exit 0
DKMCPEOF
    chmod +x "$_mb/hostmcp"

    export PATH="$_mb:$PATH"
}

_cleanup_mocks() {
    local fp="$1" mb="$2"
    safe_rm_rf "$fp" "$mb"
}

# ─── hostmcp tests ──────────────────────────────────────────────────────────────

# Test 22: hostmcp already installed → skip install prompt, run init
test_interactive_hostmcp_already_installed() {
    echo ""
    echo "=== Test: hostmcp already installed — no install prompt ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    # Input: port=default(1)
    local output
    output=$(bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "hostmcp が見つかりません"; then
        fail "Install prompt should NOT appear when hostmcp is already installed"
    else
        pass "No install prompt when hostmcp already installed"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 23: hostmcp not installed, user accepts → go install called, binary confirmed
# DISABLED: _setup_hostmcp_mocks always makes hostmcp findable via _mb,
# so the "not found" branch this test depends on can never execute.
# Not called from main().
test_interactive_hostmcp_install_accepted() {
    echo ""
    echo "=== Test: hostmcp install accepted → go install executed ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    # Input: install=1(yes), port=default(1)
    local output
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "installation complete"; then
        pass "hostmcp install completed message shown"
    else
        fail "Expected install completion message, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 24: hostmcp not installed, user declines → init and next steps skipped
# DISABLED: same _setup_hostmcp_mocks limitation as Test 23. Not called from main().
test_interactive_hostmcp_install_declined() {
    echo ""
    echo "=== Test: hostmcp install declined → init skipped ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    # Input: install=2(no)
    local output
    output=$(echo -e "2" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "Skipped HostMCP setup"; then
        pass "Skip message shown when install declined"
    else
        fail "Expected skip message, got: $output"
    fi

    if echo "$output" | grep -q "HostMCP setup complete"; then
        fail "Next-steps message should NOT appear when install declined"
    else
        pass "Next-steps message not shown when install declined"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 25: go not found → binary download option shown
test_interactive_hostmcp_no_go() {
    echo ""
    echo "=== Test: go not found → binary download option shown ==="

    setup
    local mb fake_home
    _isolate_hostmcp_absent mb
    fake_home=$(mktemp -d)

    # Fake curl (decline install so download isn't attempted)
    printf '#!/bin/bash\nexit 0\n' > "$mb/curl"
    chmod +x "$mb/curl"

    # Input: install=2(decline)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '2' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "download binary from GitHub Releases"; then
        pass "Binary download option shown when go is not found"
    else
        fail "Expected binary download option, got: $output"
    fi

    safe_rm_rf "$mb" "$fake_home"
    cleanup
}

# Regression test for the fix where the initial "hostmcp not found. Install
# it?" prompt used `read -r -p ... || true`, silently swallowing a genuine
# read failure. When this script is reached non-interactively (e.g. via
# HostMCP's run_host_tool bridge with closed/non-TTY stdin), that read hits
# real EOF, install_choice ends up empty, and the empty string matches the
# `*)` (install) branch of the case statement — the SAME branch a human
# pressing Enter to accept the bracketed "[1]" default would hit. Without
# distinguishing "no input available at all" from "user accepted the
# default", a non-interactive invocation would silently install/download
# software with no real consent. The fix aborts instead when `read` itself
# fails. This test asserts that abort, and that no download is even attempted.
#
# 「hostmcpが見つかりません。インストールしますか？」プロンプトの
# `read -r -p ... || true` が本物のread失敗を握りつぶしてしまう不具合の
# 回帰テスト。このスクリプトが非対話的に到達された場合（例: HostMCPの
# run_host_tool経由でstdinが閉じている/非TTY）、そのreadは本物のEOFに
# 到達し、install_choiceは空文字列になり、caseの`*)`（インストール）分岐に
# マッチしてしまう — これは人間がEnterキーで"[1]"のデフォルトを承認した
# 場合と同じ分岐である。「入力が全くない」場合と「ユーザーがデフォルトを
# 承認した」場合を区別しないと、非対話呼び出しで本当の同意なしにソフトウェアの
# インストール/ダウンロードが黙って実行されてしまう。修正では`read`自体が
# 失敗した場合は中止するようにした。このテストはその中止動作と、
# ダウンロードが一切試みられないことを確認する。
test_interactive_hostmcp_install_no_input_aborts() {
    echo ""
    echo "=== Test: no input at install prompt (EOF) → aborts, does not install ==="

    setup
    local mb fake_home
    mb=$(mktemp -d)
    fake_home=$(mktemp -d)

    # If the abort didn't work and the script fell through to the install
    # branch, this fake curl would be invoked — make that loudly detectable
    # instead of letting it silently "succeed".
    # 中止が機能せずインストール分岐に落ちてしまった場合、この偽curlが
    # 呼ばれる — それを黙って「成功」させず、はっきり検知できるようにする。
    cat > "$mb/curl" << 'CURLEOF'
#!/bin/bash
echo "CURL SHOULD NOT HAVE BEEN CALLED" >&2
exit 1
CURLEOF
    chmod +x "$mb/curl"

    # No input at all: stdin is closed, so the very first `read` (the install
    # prompt) hits real EOF — not a user pressing Enter for the bracketed
    # default.
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        bash '$SCRIPT' '$TEST_PROJECT' < /dev/null
    " 2>&1)

    if echo "$output" | grep -q "No input received"; then
        pass "Abort message shown when no input available at install prompt"
    else
        fail "Expected abort message, got: $output"
    fi

    if echo "$output" | grep -q "installation complete\|installed to:"; then
        fail "Should NOT install when no input was available (EOF)"
    else
        pass "No install performed when no input was available (EOF)"
    fi

    if echo "$output" | grep -q "CURL SHOULD NOT HAVE BEEN CALLED"; then
        fail "curl should never be invoked when the install prompt aborts on EOF"
    else
        pass "curl not invoked — abort happened before any download attempt"
    fi

    safe_rm_rf "$mb" "$fake_home"
    cleanup
}

# Test: go install producing hostmcp.exe (Windows) must not be reported as a
# failed install. Regression test for A2-3: the post-install check only
# looked for "$gopath_bin/hostmcp" with no .exe fallback, even though a
# Windows `go install` produces hostmcp.exe, not hostmcp.
# テスト: go install が hostmcp.exe を生成する場合(Windows)、インストール失敗と
# 誤報告されないことを確認する回帰テスト。修正前は "$gopath_bin/hostmcp" のみを
# 確認しており、.exe へのフォールバックがなかった。
test_interactive_hostmcp_go_install_windows_exe() {
    echo ""
    echo "=== Test: go install producing hostmcp.exe is not reported as failed ==="

    setup
    local mb fake_home fake_gopath
    mb=$(mktemp -d)
    fake_home=$(mktemp -d)
    fake_gopath=$(mktemp -d)

    # Fake go: GOPATH lookup + install creates hostmcp.exe only (simulating Windows)
    cat > "$mb/go" << GOEOF
#!/bin/bash
if [ "\$1" = "env" ] && [ "\$2" = "GOPATH" ]; then
    echo "$fake_gopath"
elif [ "\$1" = "install" ]; then
    mkdir -p "$fake_gopath/bin"
    touch "$fake_gopath/bin/hostmcp.exe"
    chmod +x "$fake_gopath/bin/hostmcp.exe"
    exit 0
fi
GOEOF
    chmod +x "$mb/go"

    # Input: install=1(accept), port=default(1)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1) || true

    if echo "$output" | grep -q "Failed to install hostmcp"; then
        fail "Should not report install failure when only hostmcp.exe exists, got: $output"
    elif echo "$output" | grep -q "installation complete"; then
        pass "Install correctly recognized via hostmcp.exe (Windows)"
    else
        fail "Expected install completion message, got: $output"
    fi

    safe_rm_rf "$mb" "$fake_home" "$fake_gopath"
    cleanup
}

# Test 26: default port → hostmcp init called without --port
test_interactive_hostmcp_init_default_port() {
    echo ""
    echo "=== Test: default port → hostmcp init without --port ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    # Override hostmcp to log args
    cat > "$mb/hostmcp" << DEOF
#!/bin/bash
echo "\$@" >> "$TEST_PROJECT/hostmcp-calls.log"
if [ "\$1" = "init" ]; then
    ws=""
    shift
    while [ \$# -gt 0 ]; do
        [ "\$1" = "--workspace" ] && ws="\$2"
        shift
    done
    [ -n "\$ws" ] && mkdir -p "\$ws/.sandbox/config" && touch "\$ws/.sandbox/config/hostmcp.yaml"
fi
exit 0
DEOF
    chmod +x "$mb/hostmcp"

    # Input: port=default(1)
    bash "$SCRIPT" "$TEST_PROJECT" < /dev/null > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/hostmcp-calls.log" ]; then
        local call
        call=$(cat "$TEST_PROJECT/hostmcp-calls.log")
        if echo "$call" | grep -q "\-\-port"; then
            fail "hostmcp init should NOT include --port for default: $call"
        else
            pass "hostmcp init called without --port for default"
        fi
    else
        fail "hostmcp was not called"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 27: custom port → hostmcp init called with --port 9999
test_interactive_hostmcp_init_custom_port() {
    echo ""
    echo "=== Test: custom port 9999 → hostmcp init --port 9999 ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    cat > "$mb/hostmcp" << DEOF
#!/bin/bash
echo "\$@" >> "$TEST_PROJECT/hostmcp-calls.log"
if [ "\$1" = "init" ]; then
    ws=""
    shift
    while [ \$# -gt 0 ]; do
        [ "\$1" = "--workspace" ] && ws="\$2"
        shift
    done
    [ -n "\$ws" ] && mkdir -p "\$ws/.sandbox/config" && touch "\$ws/.sandbox/config/hostmcp.yaml"
fi
exit 0
DEOF
    chmod +x "$mb/hostmcp"

    # Input: port=custom(2), port_number=9999
    echo -e "2\n9999" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/hostmcp-calls.log" ]; then
        local call
        call=$(cat "$TEST_PROJECT/hostmcp-calls.log")
        if echo "$call" | grep -q "\-\-port 9999"; then
            pass "hostmcp init called with --port 9999"
        else
            fail "Expected --port 9999 in: $call"
        fi
    else
        fail "hostmcp was not called"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test: leading-zero port input must not crash the script. Regression test
# for A2-1: bash arithmetic treats a leading-zero numeral as octal, and "8"/"9"
# are invalid octal digits, so `$((08080 + 0))` was a fatal error under
# `set -euo pipefail`.
# テスト: 先頭ゼロのポート入力でスクリプトがクラッシュしないことを確認する回帰
# テスト。bashの算術展開は先頭ゼロの数値を8進数として扱うため、"8"/"9"を含む
# 場合は無効な8進数となり `set -euo pipefail` 下で致命的エラーになっていた。
test_interactive_hostmcp_init_port_leading_zero_no_crash() {
    echo ""
    echo "=== Test: leading-zero port '08080' does not crash ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    # Input: port=custom(2), port_number=08080
    local exit_code
    echo -e "2\n08080" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1 && exit_code=0 || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        pass "Leading-zero port '08080' does not crash the script"
    else
        fail "Script crashed on leading-zero port '08080' (exit_code=$exit_code)"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test: leading-zero port input is validated using its decimal value, not a
# misinterpreted octal value. Regression test for A2-1's "silent wrong value"
# case: "01777" (decimal 1777, >1023) was previously misread as octal 1023
# (<=1023), triggering a spurious "may require administrator privileges"
# warning.
# テスト: 先頭ゼロのポート入力が誤って8進数として解釈されず、正しく10進数として
# 検証されることを確認する回帰テスト。「01777」(10進数で1777、1023超)は修正前は
# 8進数として1023と誤読され、不要な「管理者権限が必要」警告が出ていた。
test_interactive_hostmcp_init_port_leading_zero_decimal_value() {
    echo ""
    echo "=== Test: leading-zero port '01777' is validated as decimal 1777 ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    # Input: port=custom(2), port_number=01777
    local output
    output=$(echo -e "2\n01777" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1) || true

    if echo "$output" | grep -q "administrator privileges"; then
        fail "Port '01777' (decimal 1777) should not trigger the <=1023 admin-privileges warning, got: $output"
    else
        pass "Port '01777' is correctly validated as decimal 1777 (no spurious admin warning)"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 28: hostmcp.yaml already exists → init skipped, next steps shown
test_interactive_hostmcp_init_already_exists() {
    echo ""
    echo "=== Test: hostmcp.yaml exists → init skipped, next steps shown ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    mkdir -p "$TEST_PROJECT/.sandbox/config"
    touch "$TEST_PROJECT/.sandbox/config/hostmcp.yaml"

    local output
    output=$(LANG=C bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "HostMCP configuration already exists"; then
        pass "Existing yaml: skip message shown"
    else
        fail "Expected existing-yaml message, got: $output"
    fi

    if echo "$output" | grep -q "hostmcp serve"; then
        pass "Next steps shown even when yaml exists"
    else
        fail "Expected next-steps with hostmcp serve, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 29: init success → next steps shown
test_interactive_hostmcp_next_steps_shown() {
    echo ""
    echo "=== Test: init success → next steps shown ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    local output
    output=$(bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "hostmcp serve"; then
        pass "Next steps (hostmcp serve) shown after init success"
    else
        fail "Expected next steps, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 31: go install fails → error shown, init skipped
# DISABLED: same _setup_hostmcp_mocks limitation as Test 23. Not called from main().
test_interactive_hostmcp_install_go_install_fails() {
    echo ""
    echo "=== Test: go install fails → error shown, init skipped ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    # Override go to fail on install
    cat > "$mb/go" << GOEOF
#!/bin/bash
if [ "\$1" = "env" ] && [ "\$2" = "GOPATH" ]; then
    echo "$fp"
elif [ "\$1" = "install" ]; then
    echo "go install failed: some error" >&2
    exit 1
fi
GOEOF
    chmod +x "$mb/go"

    local output
    output=$(bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "Failed to install hostmcp"; then
        pass "Install failure error shown"
    else
        fail "Expected install failure message, got: $output"
    fi

    if echo "$output" | grep -q "HostMCP setup complete"; then
        fail "Next steps should NOT appear after install failure"
    else
        pass "Next steps not shown after install failure"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 32: go install succeeds but binary not found → failure
# DISABLED: same _setup_hostmcp_mocks limitation as Test 23. Not called from main().
test_interactive_hostmcp_install_binary_not_found_after_install() {
    echo ""
    echo "=== Test: go install ok but binary missing → install failure ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    # go install succeeds but does NOT create the binary
    cat > "$mb/go" << GOEOF
#!/bin/bash
if [ "\$1" = "env" ] && [ "\$2" = "GOPATH" ]; then
    echo "$fp"
elif [ "\$1" = "install" ]; then
    exit 0
fi
GOEOF
    chmod +x "$mb/go"

    local output
    output=$(bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "Failed to install hostmcp"; then
        pass "Binary-not-found after install treated as failure"
    else
        fail "Expected failure message, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 33: invalid port string → validation error
test_interactive_hostmcp_init_invalid_port_string() {
    echo ""
    echo "=== Test: invalid port string 'abc' → validation error ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    # Input: port=custom(2), bad=abc, then valid=8080
    local output
    output=$(echo -e "2\nabc\n8080" | LANG=C bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "Invalid port number"; then
        pass "Validation error shown for non-integer port"
    else
        fail "Expected validation error for 'abc', got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 34: out-of-range port → validation error
test_interactive_hostmcp_init_invalid_port_out_of_range() {
    echo ""
    echo "=== Test: out-of-range port 99999 → validation error ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    cat > "$mb/hostmcp" << DEOF
#!/bin/bash
echo "\$@" >> "$TEST_PROJECT/hostmcp-calls.log"
if [ "\$1" = "init" ]; then
    ws=""
    shift
    while [ \$# -gt 0 ]; do
        [ "\$1" = "--workspace" ] && ws="\$2"
        shift
    done
    [ -n "\$ws" ] && mkdir -p "\$ws/.sandbox/config" && touch "\$ws/.sandbox/config/hostmcp.yaml"
fi
exit 0
DEOF
    chmod +x "$mb/hostmcp"

    # bad=99999, then valid=8080
    local output
    output=$(echo -e "2\n99999\n8080" | LANG=C bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "Invalid port number"; then
        pass "Validation error for out-of-range port 99999"
    else
        fail "Expected validation error for 99999, got: $output"
    fi

    if [ -f "$TEST_PROJECT/hostmcp-calls.log" ]; then
        local call
        call=$(cat "$TEST_PROJECT/hostmcp-calls.log")
        if echo "$call" | grep -q "\-\-port 99999"; then
            fail "hostmcp init should NOT be called with invalid port 99999"
        else
            pass "hostmcp init not called with invalid port"
        fi
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 35: 3 invalid inputs → fallback to default port 18080
test_interactive_hostmcp_port_retry_fallback() {
    echo ""
    echo "=== Test: 3 invalid inputs → fallback to default port 18080 ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    cat > "$mb/hostmcp" << DEOF
#!/bin/bash
echo "\$@" >> "$TEST_PROJECT/hostmcp-calls.log"
if [ "\$1" = "init" ]; then
    ws=""
    shift
    while [ \$# -gt 0 ]; do
        [ "\$1" = "--workspace" ] && ws="\$2"
        shift
    done
    [ -n "\$ws" ] && mkdir -p "\$ws/.sandbox/config" && touch "\$ws/.sandbox/config/hostmcp.yaml"
fi
exit 0
DEOF
    chmod +x "$mb/hostmcp"

    # 3 invalid ports → fallback
    local output
    output=$(echo -e "2\nabc\nxyz\n99999" | LANG=C bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "Using default port (18080)"; then
        pass "Fallback message shown after 3 invalid ports"
    else
        fail "Expected fallback message, got: $output"
    fi

    if [ -f "$TEST_PROJECT/hostmcp-calls.log" ]; then
        local call
        call=$(cat "$TEST_PROJECT/hostmcp-calls.log")
        if echo "$call" | grep -q "\-\-port"; then
            fail "hostmcp init should NOT have --port on fallback: $call"
        else
            pass "hostmcp init called without --port on fallback"
        fi
    else
        fail "hostmcp init was not called after fallback"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 36: go env GOPATH returns empty → fallback to $HOME/go/bin
test_interactive_hostmcp_gopath_empty() {
    echo ""
    echo "=== Test: GOPATH empty → fallback to \$HOME/go/bin ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    local fake_home
    fake_home=$(mktemp -d)

    # go returns empty GOPATH; binary only in $HOME/go/bin
    cat > "$mb/go" << GOEOF
#!/bin/bash
if [ "\$1" = "env" ] && [ "\$2" = "GOPATH" ]; then
    echo ""
elif [ "\$1" = "install" ]; then
    mkdir -p "$fake_home/go/bin"
    touch "$fake_home/go/bin/hostmcp"
    chmod +x "$fake_home/go/bin/hostmcp"
    exit 0
fi
GOEOF
    chmod +x "$mb/go"

    cat > "$mb/hostmcp" << DEOF
#!/bin/bash
if [ "\$1" = "init" ]; then
    ws=""
    shift
    while [ \$# -gt 0 ]; do
        [ "\$1" = "--workspace" ] && ws="\$2"
        shift
    done
    [ -n "\$ws" ] && mkdir -p "\$ws/.sandbox/config" && touch "\$ws/.sandbox/config/hostmcp.yaml"
fi
exit 0
DEOF
    chmod +x "$mb/hostmcp"

    local output
    output=$(HOME="$fake_home" LANG=C bash -c "export PATH='$mb:$PATH'; echo -e '1\n1' | bash '$SCRIPT' '$TEST_PROJECT'" 2>&1)

    if echo "$output" | grep -q "installation complete\|setup complete"; then
        pass "Empty GOPATH: fallback to \$HOME/go/bin works"
    else
        fail "Expected success with HOME/go fallback, got: $output"
    fi

    safe_rm_rf "$fake_home"
    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 37: go env GOPATH exits non-zero → silent fallback to $HOME/go/bin, normal flow
test_interactive_hostmcp_gopath_command_fails() {
    echo ""
    echo "=== Test: go env GOPATH fails → silent fallback, normal flow ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    # go returns exit 1 for GOPATH (hostmcp is still discoverable via PATH from mock bin)
    cat > "$mb/go" << 'GOEOF'
#!/bin/bash
if [ "$1" = "env" ] && [ "$2" = "GOPATH" ]; then
    exit 1
fi
GOEOF
    chmod +x "$mb/go"

    local output
    output=$(bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "GOPATH が取得できません"; then
        fail "GOPATH error should not be shown (silent fallback expected)"
    else
        pass "No GOPATH error shown (silent fallback works)"
    fi

    # hostmcp is in PATH (mock bin), so normal flow should proceed
    if echo "$output" | grep -q "hostmcp serve\|セットアップが完了\|設定ファイルは既に存在"; then
        pass "Normal flow proceeds despite GOPATH failure"
    else
        fail "Expected normal flow to proceed, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 38: next steps shows absolute path (PROJECT_ROOT=.)
test_interactive_hostmcp_next_steps_shows_absolute_path() {
    echo ""
    echo "=== Test: next steps shows absolute path ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    local abs_path
    abs_path="$(cd "$TEST_PROJECT" && pwd)"

    local output
    output=$(cd "$TEST_PROJECT" && PATH="$mb:$PATH" bash "$SCRIPT" "." < /dev/null 2>&1)

    if echo "$output" | grep -q "$abs_path"; then
        pass "Next steps shows absolute path: $abs_path"
    else
        fail "Expected absolute path in next steps, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 39: hostmcp init fails → error shown, next steps skipped
test_interactive_hostmcp_init_fails_skips_next_steps() {
    echo ""
    echo "=== Test: hostmcp init fails → error shown, next steps skipped ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    # hostmcp init always fails
    cat > "$mb/hostmcp" << 'DEOF'
#!/bin/bash
if [ "$1" = "init" ]; then
    echo "init failed" >&2
    exit 1
fi
exit 0
DEOF
    chmod +x "$mb/hostmcp"

    local output
    output=$(LANG=C bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "Failed to generate HostMCP configuration file"; then
        pass "Error shown when hostmcp init fails"
    else
        fail "Expected init failure message, got: $output"
    fi

    if echo "$output" | grep -q "hostmcp serve"; then
        fail "Next steps should NOT appear after init failure"
    else
        pass "Next steps not shown after init failure"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# ─── binary download helper ────────────────────────────────────────────────────
# Set up mocks for binary download scenario: no go, fake curl that writes a hostmcp stub
_setup_binary_download_mocks() {
    local _home_var="$1" _mb_var="$2"
    # Named _new_mb (not _mb) so it doesn't collide with _isolate_hostmcp_absent's
    # own internal `local _mb` — eval-assigning through a same-named local would
    # silently write to the helper's local instead of this function's variable.
    # _isolate_hostmcp_absent 内部の `local _mb` と衝突しないよう _mb ではなく
    # _new_mb という名前にしている — 同名の local だと eval 代入がこの関数の
    # 変数ではなくヘルパー側のローカル変数に対して行われてしまう。
    local _home _new_mb
    _home=$(mktemp -d)
    _isolate_hostmcp_absent _new_mb
    eval "$_home_var='$_home'"
    eval "$_mb_var='$_new_mb'"

    # Fake curl: handles both version fetch (-o /dev/null) and binary download (-o <path>)
    cat > "$_new_mb/curl" << 'CURLEOF'
#!/bin/bash
out_file=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-o" ] && out_file="$arg"
    prev="$arg"
done
if [ "$out_file" = "/dev/null" ]; then
    printf 'https://github.com/YujiSuzuki/hostmcp/releases/tag/v0.0.1'
    exit 0
fi
if [ -n "$out_file" ]; then
    mkdir -p "$(dirname "$out_file")"
    printf '#!/bin/bash\nif [ "$1" = "init" ]; then ws=""; shift; while [ $# -gt 0 ]; do [ "$1" = "--workspace" ] && ws="$2"; shift; done; [ -n "$ws" ] && mkdir -p "$ws/.sandbox/config" && touch "$ws/.sandbox/config/hostmcp.yaml"; fi\nexit 0\n' > "$out_file"
fi
exit 0
CURLEOF
    chmod +x "$_new_mb/curl"
}

_cleanup_binary_download_mocks() {
    local home="$1" mb="$2"
    safe_rm_rf "$home" "$mb"
}

# ─── binary download tests ──────────────────────────────────────────────────────

# Test 40: no go, binary download declined → skip message with GitHub URL
test_interactive_hostmcp_binary_download_declined() {
    echo ""
    echo "=== Test: no go, binary download declined → skip with GitHub URL ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Input: install=2(decline)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '2' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "Skipped HostMCP setup"; then
        pass "Skip message shown when binary download declined"
    else
        fail "Expected skip message, got: $output"
    fi

    if echo "$output" | grep -q "releases/latest\|YujiSuzuki/hostmcp"; then
        pass "GitHub Releases URL shown in skip message"
    else
        fail "Expected GitHub URL in skip message, got: $output"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}

# Test 41: no go, binary download accepted, curl succeeds → install + next steps
test_interactive_hostmcp_binary_download_success() {
    echo ""
    echo "=== Test: no go, binary download accepted, curl succeeds → install ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Input: install=1(yes), install-dir=default(1, now ~/.local/bin), port=default(1)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "installed to:"; then
        pass "Binary install success message shown"
    else
        fail "Expected install success message, got: $output"
    fi

    if echo "$output" | grep -q "hostmcp serve"; then
        pass "Next steps shown after binary install success"
    else
        fail "Expected next steps (hostmcp serve), got: $output"
    fi

    if echo "$output" | grep -q "v0.0.1"; then
        pass "Version number shown in install prompt"
    else
        fail "Expected version number (v0.0.1) in output, got: $output"
    fi

    if [ -f "$fake_home/.local/bin/hostmcp" ]; then
        pass "Binary installed to default location (~/.local/bin) when option 1 selected"
    else
        fail "Expected binary at $fake_home/.local/bin/hostmcp, got: $output"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}

# Test 41b: no go, binary download accepted, install-dir=2 (~/go/bin) → installs there
test_interactive_hostmcp_binary_download_success_go_bin() {
    echo ""
    echo "=== Test: no go, binary download accepted, install-dir=~/go/bin ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Input: install=1(yes), install-dir=2(~/go/bin), port=default(1)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '1\n2\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "installed to:"; then
        pass "Binary install success message shown"
    else
        fail "Expected install success message, got: $output"
    fi

    if [ -f "$fake_home/go/bin/hostmcp" ]; then
        pass "Binary installed to ~/go/bin when option 2 selected"
    else
        fail "Expected binary at $fake_home/go/bin/hostmcp, got: $output"
    fi

    if [ -f "$fake_home/.local/bin/hostmcp" ]; then
        fail "Binary should NOT be installed to ~/.local/bin when option 2 was selected"
    else
        pass "Binary not installed to default ~/.local/bin when option 2 selected"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}

# Test 41c: no go, binary download accepted → install-dir prompt shows both options
test_interactive_hostmcp_binary_download_dir_prompt_shown() {
    echo ""
    echo "=== Test: install-dir prompt lists both ~/go/bin and ~/.local/bin ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Input: install=1(yes), install-dir=default(1), port=default(1)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "$fake_home/go/bin" && echo "$output" | grep -q "$fake_home/.local/bin"; then
        pass "Install-dir prompt lists both ~/go/bin and ~/.local/bin"
    else
        fail "Expected both directory options in prompt, got: $output"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}

# Test 41d: no go, binary download succeeds → warns that a shell with a stale
# `hash` cache should run `hash -r` (reproduces the real-world symptom where
# `hostmcp` resolves to a since-removed path even though `which hostmcp` finds
# the current binary).
test_interactive_hostmcp_binary_download_warns_hash_r() {
    echo ""
    echo "=== Test: binary download success warns about shell hash cache ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Input: install=1(yes), install-dir=default(1), port=default(1)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "hash -r"; then
        pass "Warns to run 'hash -r' after successful binary install"
    else
        fail "Expected a 'hash -r' reminder after install, got: $output"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}

# Test 41e: no go, binary download explicitly to ~/go/bin (option 2) while a
# stale binary already exists at ~/.local/bin → warns to remove the stale one.
# NOTE: this direction only (installing to go/bin while .local/bin has the
# leftover) is actually reachable: a leftover binary sitting at $gopath_bin
# itself trips the earlier "already installed?" check
# ([ -f "$gopath_bin/hostmcp" ]) and short-circuits before the download
# branch (and its install-dir prompt) is ever reached.
test_interactive_hostmcp_binary_download_warns_stale_other_location() {
    echo ""
    echo "=== Test: warns about leftover hostmcp binary at the other known location ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Simulate a previous install left behind at ~/.local/bin
    mkdir -p "$fake_home/.local/bin"
    printf '#!/bin/bash\nexit 0\n' > "$fake_home/.local/bin/hostmcp"
    chmod +x "$fake_home/.local/bin/hostmcp"

    # Input: install=1(yes), install-dir=2(~/go/bin), port=default(1)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '1\n2\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "$fake_home/.local/bin.*rm $fake_home/.local/bin/hostmcp\|rm $fake_home/.local/bin/hostmcp"; then
        pass "Warns about leftover binary at the other (unselected) install location"
    else
        fail "Expected a warning to remove $fake_home/.local/bin/hostmcp, got: $output"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}

# Test 42: no go, binary download accepted, curl fails → download error shown
test_interactive_hostmcp_binary_download_curl_fails() {
    echo ""
    echo "=== Test: no go, curl returns error → download failure message ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Override curl to fail
    printf '#!/bin/bash\nexit 1\n' > "$mb/curl"
    chmod +x "$mb/curl"

    # Input: install=1(yes), install-dir=default(1)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "Download failed"; then
        pass "Download failure error shown when curl returns non-zero"
    else
        fail "Expected download failure message, got: $output"
    fi

    if echo "$output" | grep -q "hostmcp serve"; then
        fail "Next steps should NOT appear after download failure"
    else
        pass "Next steps not shown after download failure"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}

# Test 43: no go, no curl, no wget → error shown
test_interactive_hostmcp_no_curl_no_wget() {
    echo ""
    echo "=== Test: no go, no curl, no wget → error shown ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    # Input: install=1(yes), install-dir=default(1) — no curl/wget in PATH
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "Neither curl nor wget found"; then
        pass "Error shown when curl/wget unavailable"
    else
        fail "Expected curl/wget error, got: $output"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test 44: version shown in install prompt when fetch succeeds
test_interactive_hostmcp_version_shown_in_prompt() {
    echo ""
    echo "=== Test: version fetch succeeds → version shown in install prompt ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Input: install=2(decline) — just to see the prompt text
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '2' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "v0.0.1"; then
        pass "Version number shown in install prompt"
    else
        fail "Expected version number (v0.0.1) in prompt, got: $output"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}

# Test 45: version fetch fails → installs anyway using latest URL
test_interactive_hostmcp_version_fetch_fails_installs_anyway() {
    echo ""
    echo "=== Test: version fetch fails → installs anyway (latest fallback) ==="

    setup
    local fake_home mb
    _setup_binary_download_mocks fake_home mb

    # Override curl: fail for version fetch (-o /dev/null), succeed for binary download
    cat > "$mb/curl" << 'CURLEOF'
#!/bin/bash
out_file=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-o" ] && out_file="$arg"
    prev="$arg"
done
if [ "$out_file" = "/dev/null" ]; then
    exit 1
fi
if [ -n "$out_file" ]; then
    mkdir -p "$(dirname "$out_file")"
    printf '#!/bin/bash\nif [ "$1" = "init" ]; then ws=""; shift; while [ $# -gt 0 ]; do [ "$1" = "--workspace" ] && ws="$2"; shift; done; [ -n "$ws" ] && mkdir -p "$ws/.sandbox/config" && touch "$ws/.sandbox/config/hostmcp.yaml"; fi\nexit 0\n' > "$out_file"
fi
exit 0
CURLEOF
    chmod +x "$mb/curl"

    # Input: install=1(yes), install-dir=default(1), port=default(1)
    local output
    output=$(HOME="$fake_home" LANG=C bash -c "
        export PATH='$mb'
        echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "installed to:"; then
        pass "Install succeeds even when version fetch fails"
    else
        fail "Expected install success despite version fetch failure, got: $output"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
    cleanup
}


# ─── hostmcp update-check tests ──────────────────────────────────────────────

# Build a fake hostmcp binary that responds to `version` with a fixed string,
# and to `init` the same way the default mock does (so setup_hostmcp_init
# doesn't hang/fail after the update-check portion runs).
# `version` に固定文字列を返し、`init` はデフォルトモックと同様に振る舞う
# 偽の hostmcp バイナリを作る（update-check の後に走る setup_hostmcp_init が
# 失敗/停止しないようにするため）。
_setup_versioned_hostmcp_mock() {
    local _fp_var="$1" _installed_version="$2"
    local _fp
    _fp=$(mktemp -d)
    eval "$_fp_var='$_fp'"

    mkdir -p "$_fp/bin"
    cat > "$_fp/bin/hostmcp" << VEOF
#!/bin/bash
if [ "\$1" = "version" ]; then
    echo "$_installed_version"
    exit 0
fi
if [ "\$1" = "init" ]; then
    ws=""
    shift
    while [ \$# -gt 0 ]; do
        [ "\$1" = "--workspace" ] && ws="\$2"
        shift
    done
    [ -n "\$ws" ] && mkdir -p "\$ws/.sandbox/config" && touch "\$ws/.sandbox/config/hostmcp.yaml"
fi
exit 0
VEOF
    chmod +x "$_fp/bin/hostmcp"
    export PATH="$_fp/bin:$PATH"

    # Also isolate $HOME, not just PATH. _upgrade_hostmcp falls back to
    # "$HOME/go/bin" whenever `go` isn't on PATH, to find where an existing
    # install lives. If a caller of this helper forgets to override $HOME
    # itself (several previously did), that fallback resolves to the REAL
    # $HOME of whoever runs this test suite — and since this suite is normally
    # run on a machine that already has a real hostmcp installed at
    # ~/go/bin/hostmcp (that's the whole point of it existing), an
    # accept-the-upgrade test would overwrite that real, currently-installed
    # binary with this mock's stub. Isolating $HOME here, once, for every
    # caller closes that off at the source instead of relying on each test to
    # remember it individually. Restored by cleanup().
    # PATHだけでなく$HOMEも隔離する。_upgrade_hostmcpは`go`がPATHにない場合、
    # 既存インストール先の探索に"$HOME/go/bin"へフォールバックする。この
    # ヘルパーの呼び出し元が$HOMEの上書きを忘れると（実際に複数箇所で
    # 忘れていた）、そのフォールバックはこのテストスイートを実行している人の
    # 「本物の」$HOMEを指してしまう。このスイートは通常、実際に
    # ~/go/bin/hostmcp にhostmcpがインストール済みのマシン上で実行される
    # （そもそもそれがこのスイートの存在意義）ため、更新を承認するテストが
    # 実際にインストール済みの本物のバイナリをこのモックのスタブで
    # 上書きしてしまう。ここで一度だけ$HOMEを隔離しておけば、各テストが
    # 個別に気をつける必要がなくなる。復元は cleanup() で行う。
    _VERSIONED_MOCK_REAL_HOME="${_VERSIONED_MOCK_REAL_HOME:-$HOME}"
    _VERSIONED_MOCK_FAKE_HOME=$(mktemp -d)
    export HOME="$_VERSIONED_MOCK_FAKE_HOME"
}

# Regression test for the A2-1 code-review finding: _check_hostmcp_update
# must query GitHub's stable-only release channel, not the library default
# ("all", which can surface pre-releases). Without CHECK_CHANNEL=stable set,
# this function's notion of "latest" could point at a pre-release that the
# actual upgrade paths (_fetch_hostmcp_version's /releases/latest redirect,
# and `go install ...@latest`) can never resolve to — producing an
# "update available" prompt that never goes away, since accepting it always
# reinstalls the same stable version instead of the announced one.
# This test asserts the actual URL queried by curl, not just a mocked
# version string, so it can't be satisfied by MOCK_LATEST_VERSION alone
# (which bypasses fetch_latest_release, and with it build_api_url's channel
# selection, entirely).
#
# コードレビュー指摘 A2-1 の回帰テスト: _check_hostmcp_update は GitHub の
# 安定版限定チャンネルを問い合わせる必要があり、ライブラリのデフォルト
# （"all" — プレリリースを含みうる）のままではいけない。CHECK_CHANNEL=stable が
# 設定されていないと、この関数が言う「最新」がプレリリースを指す可能性があり、
# 実際の更新経路（_fetch_hostmcp_version の /releases/latest リダイレクト、
# `go install ...@latest`）ではそのバージョンに到達できない — 結果として
# 「更新があります」の通知が、承諾しても常に同じ安定版が再インストールされる
# だけで、消えなくなってしまう。このテストはモックしたバージョン文字列ではなく
# curl が実際に問い合わせた URL を検証するため、fetch_latest_release ごと
# （build_api_url のチャンネル選択も含めて）バイパスしてしまう
# MOCK_LATEST_VERSION だけでは満たせない。
test_update_check_queries_stable_channel_only() {
    echo ""
    echo "=== Test: update check queries the stable-only GitHub API endpoint ==="

    setup
    local fp mb
    _setup_versioned_hostmcp_mock fp "v1.0.0"
    mb=$(mktemp -d)

    local url_log
    url_log=$(mktemp)

    # Fake curl: logs the requested URL, returns a minimal valid JSON body
    # and HTTP 200 regardless of endpoint shape (object for /releases/latest,
    # array for /releases?per_page=1) — this test only cares which URL was
    # requested, not how the response is parsed.
    # 偽の curl: 問い合わせられたURLを記録し、エンドポイントの形（
    # /releases/latest はオブジェクト、/releases?per_page=1 は配列）に関わらず
    # 最小限の有効なJSONとHTTP 200を返す — このテストが検証するのはどのURLが
    # 問い合わせられたかのみで、レスポンスの解析方法ではない。
    cat > "$mb/curl" << CURLEOF
#!/bin/bash
out_file=""
prev=""
url=""
for arg in "\$@"; do
    [ "\$prev" = "-o" ] && out_file="\$arg"
    prev="\$arg"
    url="\$arg"
done
echo "\$url" >> "$url_log"
[ -n "\$out_file" ] && printf '{"tag_name": "v1.0.0"}' > "\$out_file"
echo "200"
CURLEOF
    chmod +x "$mb/curl"
    export PATH="$mb:$PATH"

    bash "$SCRIPT" "$TEST_PROJECT" < /dev/null > /dev/null 2>&1

    if [ -f "$url_log" ] && grep -q "releases/latest" "$url_log" && ! grep -q "releases?per_page=1" "$url_log"; then
        pass "Update check queried the stable-only /releases/latest endpoint"
    else
        fail "Expected update check to query .../releases/latest (stable channel only), got URLs: $(cat "$url_log" 2>/dev/null)"
    fi

    rm -f "$url_log"
    safe_rm_rf "$fp" "$mb"
    cleanup
}

test_update_check_same_version_no_prompt() {
    echo ""
    echo "=== Test: installed version == latest → no update prompt ==="

    setup
    local fp
    _setup_versioned_hostmcp_mock fp "v1.0.0"

    local output
    output=$(MOCK_LATEST_VERSION="v1.0.0" LANG=C bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "up to date"; then
        pass "Up-to-date message shown"
    else
        fail "Expected up-to-date message, got: $output"
    fi

    if echo "$output" | grep -q "update available"; then
        fail "Update-available message should NOT appear when versions match"
    else
        pass "No update-available message when versions match"
    fi

    safe_rm_rf "$fp"
    cleanup
}

test_update_check_new_version_prompt_shown() {
    echo ""
    echo "=== Test: installed version < latest → update prompt shown with both versions ==="

    setup
    local fp
    _setup_versioned_hostmcp_mock fp "v1.0.0"

    local output
    output=$(MOCK_LATEST_VERSION="v2.0.0" bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "v1.0.0" && echo "$output" | grep -q "v2.0.0"; then
        pass "Both installed and latest versions shown in prompt"
    else
        fail "Expected both v1.0.0 and v2.0.0 in output, got: $output"
    fi

    safe_rm_rf "$fp"
    cleanup
}

test_update_check_decline_no_upgrade() {
    echo ""
    echo "=== Test: update declined → go install NOT called ==="

    setup
    local fp mb
    _setup_versioned_hostmcp_mock fp "v1.0.0"
    mb=$(mktemp -d)
    # Only `go install` (the actual upgrade action) touches the marker — `go env
    # GOPATH` is called unconditionally by setup_hostmcp_install itself (to compute
    # gopath_bin for the "already installed" check) regardless of the update
    # prompt's answer, so treating that as "go was called for the upgrade" would
    # be a false positive.
    # マーカーを作るのは `go install`（実際の更新操作）のときだけ — `go env GOPATH` は
    # 更新プロンプトの回答に関係なく setup_hostmcp_install 自体が
    # （「インストール済みか」判定用の gopath_bin 算出のため）常に呼ぶので、
    # それを「更新のために go が呼ばれた」と誤検知してしまう。
    cat > "$mb/go" << 'GOEOF'
#!/bin/bash
if [ "$1" = "install" ]; then
    echo "go should not have been called for a declined update" >&2
    touch "$GO_CALLED_MARKER"
fi
exit 0
GOEOF
    chmod +x "$mb/go"
    export PATH="$mb:$PATH"

    local marker
    marker=$(mktemp -u)
    GO_CALLED_MARKER="$marker" MOCK_LATEST_VERSION="v2.0.0" \
        LANG=C bash -c "export GO_CALLED_MARKER='$marker'; echo -e '2' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if [ -f "$marker" ]; then
        fail "go install should NOT be called when update is declined"
        rm -f "$marker"
    else
        pass "go install not called when update declined"
    fi

    safe_rm_rf "$fp" "$mb"
    cleanup
}

test_update_check_default_declines() {
    echo ""
    echo "=== Test: empty input at update prompt → defaults to No ==="

    setup
    local fp
    _setup_versioned_hostmcp_mock fp "v1.0.0"

    # No input at all: the update prompt hits EOF and falls through to the
    # case statement's default branch, which is "no upgrade" (see script).
    local output
    output=$(MOCK_LATEST_VERSION="v2.0.0" LANG=C bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "hostmcp updated"; then
        fail "Should not upgrade when input defaults (EOF → No)"
    else
        pass "No upgrade performed when input defaults to No"
    fi

    safe_rm_rf "$fp"
    cleanup
}

test_update_check_accept_go_install() {
    echo ""
    echo "=== Test: update accepted, go available → go install called ==="

    setup
    local fp mb
    _setup_versioned_hostmcp_mock fp "v1.0.0"
    mb=$(mktemp -d)
    # Must actually create a binary at $HOME/go/bin (the isolated fake HOME set
    # up by _setup_versioned_hostmcp_mock, embedded here at authoring time via
    # the unquoted heredoc) to simulate a real `go install`. A no-op `exit 0`
    # used to slip by unnoticed only because, before $HOME was isolated, this
    # fell back to the tester's REAL ~/go/bin — which already had a real
    # hostmcp binary — so _upgrade_hostmcp's post-install existence check
    # passed against that real file instead of anything this mock produced.
    # 実際の`go install`を模倣するため、（作成時にunquotedヒアドキュメントで
    # 埋め込む）隔離済みの偽HOME配下の $HOME/go/bin に実際にバイナリを作成する
    # 必要がある。以前は$HOMEが隔離されておらず、何もしない`exit 0`だけでも
    # 気づかれずに通っていた — フォールバック先がテスト実行者の「本物の」
    # ~/go/bin（既に本物のhostmcpバイナリが存在する）になっていたため、
    # _upgrade_hostmcpのインストール後存在チェックが、このモックが作った
    # ものではなくその本物のファイルに対して通っていただけだった。
    cat > "$mb/go" << GOEOF
#!/bin/bash
if [ "\$1" = "install" ]; then
    mkdir -p "$HOME/go/bin"
    touch "$HOME/go/bin/hostmcp"
    chmod +x "$HOME/go/bin/hostmcp"
    exit 0
fi
GOEOF
    chmod +x "$mb/go"
    export PATH="$mb:$PATH"

    local output
    output=$(MOCK_LATEST_VERSION="v2.0.0" LANG=C bash -c "echo -e '1' | bash '$SCRIPT' '$TEST_PROJECT'" 2>&1)

    if echo "$output" | grep -q "hostmcp updated"; then
        pass "Update-complete message shown after accepted go install upgrade"
    else
        fail "Expected update-complete message, got: $output"
    fi

    safe_rm_rf "$fp" "$mb"
    cleanup
}

test_update_check_accept_binary_redownload() {
    echo ""
    echo "=== Test: update accepted, no go → binary re-downloaded to existing install dir ==="

    setup
    local fp mb
    _setup_versioned_hostmcp_mock fp "v1.0.0"
    _isolate_hostmcp_absent mb
    # Fake curl: version-check URL resolution + binary download, no `go` in PATH
    cat > "$mb/curl" << CURLEOF
#!/bin/bash
out_file=""
prev=""
for arg in "\$@"; do
    [ "\$prev" = "-o" ] && out_file="\$arg"
    prev="\$arg"
done
if [ "\$out_file" = "/dev/null" ]; then
    # version-tag lookup (used only for the download filename hint)
    echo "https://github.com/YujiSuzuki/hostmcp/releases/tag/v2.0.0"
    exit 0
fi
if [ -n "\$out_file" ]; then
    printf '#!/bin/bash\necho v2.0.0\n' > "\$out_file"
fi
exit 0
CURLEOF
    chmod +x "$mb/curl"

    # _isolate_hostmcp_absent (see its definition above) excludes go/gofmt from
    # $mb regardless of where a real `go` binary actually lives on this host,
    # so the script reliably takes the binary-download branch, while standard
    # system commands (bash, sed, chmod, ...) remain available via symlink.
    # _isolate_hostmcp_absent（上記の定義参照）は、実際の go バイナリが
    # このホストのどこにあるかによらず $mb から go/gofmt を除外するため、
    # スクリプトは確実にバイナリダウンロード分岐を通る。一方 bash/sed/chmod
    # など標準コマンドはシンボリックリンク経由で利用可能なまま。
    local output
    output=$(MOCK_LATEST_VERSION="v2.0.0" LANG=C bash -c "
        export PATH='$mb:$fp/bin'
        echo -e '1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "hostmcp updated"; then
        pass "Update-complete message shown after accepted binary re-download upgrade"
    else
        fail "Expected update-complete message, got: $output"
    fi

    safe_rm_rf "$fp" "$mb"
    cleanup
}

test_update_check_fetch_failure_skips_silently() {
    echo ""
    echo "=== Test: latest-version fetch fails → no crash, no update prompt, init still runs ==="

    setup
    local fp mb
    _setup_versioned_hostmcp_mock fp "v1.0.0"

    # Force a deterministic failure rather than relying on ambient network
    # conditions (which could flakily "succeed" and defeat this test's intent).
    # 環境依存のネットワーク状態に頼らず、決定的に失敗させる
    # （たまたま実ネットワークが繋がって成功してしまうとテストの意図が崩れるため）。
    mb=$(mktemp -d)
    printf '#!/bin/bash\nexit 1\n' > "$mb/curl"
    chmod +x "$mb/curl"
    export PATH="$mb:$fp/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    # No MOCK_LATEST_VERSION set: fetch_latest_release should fail (curl
    # exits 1 above) and _check_hostmcp_update should return silently rather
    # than erroring out (set -e would otherwise abort the whole script).
    local output
    local exit_code=0
    output=$(LANG=C bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "Script should not exit non-zero just because the update check couldn't reach GitHub, got exit $exit_code: $output"
    elif echo "$output" | grep -q "hostmcp serve"; then
        pass "Script continues to init/next-steps despite update-check fetch failure"
    else
        fail "Expected script to continue normally, got: $output"
    fi

    safe_rm_rf "$fp" "$mb"
    cleanup
}

test_update_check_empty_installed_version_skips() {
    echo ""
    echo "=== Test: hostmcp version prints nothing → update check silently skipped ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    mkdir -p "$fp/bin" && touch "$fp/bin/hostmcp" && chmod +x "$fp/bin/hostmcp"

    # _setup_hostmcp_mocks' default fake hostmcp only handles `init`; `version`
    # falls through to a bare `exit 0` with no output, simulating a hostmcp
    # binary that doesn't support the version subcommand (or any parse failure).
    local output
    output=$(MOCK_LATEST_VERSION="v9.9.9" LANG=C bash "$SCRIPT" "$TEST_PROJECT" < /dev/null 2>&1)

    if echo "$output" | grep -q "update available\|up to date"; then
        fail "Update check should be skipped entirely when installed version can't be determined, got: $output"
    else
        pass "Update check silently skipped when hostmcp version is empty"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Run all tests
# 全テストを実行
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  install-hostmcp.sh Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    test_script_executable_and_valid
    test_help_option
    test_interactive_hostmcp_already_installed
    # test_interactive_hostmcp_install_accepted  # DISABLED: see test_interactive_hostmcp_install_accepted's comment above
    # test_interactive_hostmcp_install_declined  # DISABLED: see test_interactive_hostmcp_install_accepted's comment above
    test_interactive_hostmcp_no_go
    test_interactive_hostmcp_install_no_input_aborts
    test_interactive_hostmcp_go_install_windows_exe
    test_interactive_hostmcp_init_default_port
    test_interactive_hostmcp_init_custom_port
    test_interactive_hostmcp_init_port_leading_zero_no_crash
    test_interactive_hostmcp_init_port_leading_zero_decimal_value
    test_interactive_hostmcp_init_already_exists
    test_interactive_hostmcp_next_steps_shown
    # test_interactive_hostmcp_install_go_install_fails  # DISABLED: see test_interactive_hostmcp_install_accepted's comment above
    # test_interactive_hostmcp_install_binary_not_found_after_install  # DISABLED: see test_interactive_hostmcp_install_accepted's comment above
    test_interactive_hostmcp_init_invalid_port_string
    test_interactive_hostmcp_init_invalid_port_out_of_range
    test_interactive_hostmcp_port_retry_fallback
    test_interactive_hostmcp_gopath_empty
    test_interactive_hostmcp_gopath_command_fails
    test_interactive_hostmcp_next_steps_shows_absolute_path
    test_interactive_hostmcp_init_fails_skips_next_steps
    test_interactive_hostmcp_binary_download_declined
    test_interactive_hostmcp_binary_download_success
    test_interactive_hostmcp_binary_download_success_go_bin
    test_interactive_hostmcp_binary_download_dir_prompt_shown
    test_interactive_hostmcp_binary_download_warns_hash_r
    test_interactive_hostmcp_binary_download_warns_stale_other_location
    test_interactive_hostmcp_binary_download_curl_fails
    test_interactive_hostmcp_no_curl_no_wget
    test_interactive_hostmcp_version_shown_in_prompt
    test_interactive_hostmcp_version_fetch_fails_installs_anyway
    test_update_check_queries_stable_channel_only
    test_update_check_same_version_no_prompt
    test_update_check_new_version_prompt_shown
    test_update_check_decline_no_upgrade
    test_update_check_default_declines
    test_update_check_accept_go_install
    test_update_check_accept_binary_redownload
    test_update_check_fetch_failure_skips_silently
    test_update_check_empty_installed_version_skips

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

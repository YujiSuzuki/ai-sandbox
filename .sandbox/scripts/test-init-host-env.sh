#!/bin/bash
# test-init-host-env.sh
# Test script for init-host-env.sh
#
# init-host-env.sh のテストスクリプト
#
# Usage: ./test-init-host-env.sh
# 使用方法: ./test-init-host-env.sh
#
# Environment: AI Sandbox (requires /workspace)
# 実行環境: AI Sandbox（/workspace が必要）

set -e

# Verify running in AI Sandbox
# AI Sandbox 内での実行を確認
if [ ! -d "/workspace" ]; then
    echo "Error: This test is designed to run inside AI Sandbox"
    echo "エラー: このテストは AI Sandbox 内での実行を想定しています"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/init-host-env.sh"
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
        rm -rf "$TEST_PROJECT"
    fi
}

# Trap to ensure cleanup runs
# クリーンアップが必ず実行されるようトラップ設定
trap cleanup EXIT

# Test 1: Script is executable and has valid syntax
# テスト1: スクリプトが実行可能で構文エラーがないか
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

    # Check for syntax errors
    # 構文エラーをチェック
    if bash -n "$SCRIPT" 2>/dev/null; then
        pass "Script is executable and has valid syntax"
    else
        fail "Script has syntax errors"
    fi
}

# Test 2: Creates .env.sandbox from .example
# テスト2: .example から .env.sandbox を作成
test_creates_env_sandbox_from_example() {
    echo ""
    echo "=== Test: Creates .env.sandbox from .example ==="

    setup

    # Create .env.sandbox.example
    # .env.sandbox.example を作成
    echo "TEST_VAR=test_value" > "$TEST_PROJECT/.env.sandbox.example"

    # Run script in silent mode
    # サイレントモードで実行
    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        local content
        content=$(cat "$TEST_PROJECT/.env.sandbox")
        if [ "$content" = "TEST_VAR=test_value" ]; then
            pass "Creates .env.sandbox from .env.sandbox.example"
        else
            fail "Content mismatch in .env.sandbox"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    cleanup
}

# Test 3: Creates empty .env.sandbox when no .example
# テスト3: .example がない場合に空の .env.sandbox を作成
test_creates_empty_env_sandbox() {
    echo ""
    echo "=== Test: Creates empty .env.sandbox when no .example ==="

    setup

    # Don't create .env.sandbox.example
    # .env.sandbox.example を作成しない

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if [ ! -s "$TEST_PROJECT/.env.sandbox" ]; then
            pass "Creates empty .env.sandbox when no .example"
        else
            fail ".env.sandbox should be empty"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    cleanup
}

# Test 4: Creates cli_sandbox/.env from .example
# テスト4: .example から cli_sandbox/.env を作成
test_creates_cli_env_from_example() {
    echo ""
    echo "=== Test: Creates cli_sandbox/.env from .example ==="

    setup
    mkdir -p "$TEST_PROJECT/cli_sandbox"

    # Create .env.example
    echo "CLI_VAR=cli_value" > "$TEST_PROJECT/cli_sandbox/.env.example"

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/cli_sandbox/.env" ]; then
        local content
        content=$(cat "$TEST_PROJECT/cli_sandbox/.env")
        if [ "$content" = "CLI_VAR=cli_value" ]; then
            pass "Creates cli_sandbox/.env from .env.example"
        else
            fail "Content mismatch in cli_sandbox/.env"
        fi
    else
        fail "cli_sandbox/.env was not created"
    fi

    cleanup
}

# Test 5: Creates empty cli_sandbox/.env when no .example
# テスト5: .example がない場合に空の cli_sandbox/.env を作成
test_creates_empty_cli_env() {
    echo ""
    echo "=== Test: Creates empty cli_sandbox/.env when no .example ==="

    setup
    mkdir -p "$TEST_PROJECT/cli_sandbox"

    # Don't create .env.example

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/cli_sandbox/.env" ]; then
        if [ ! -s "$TEST_PROJECT/cli_sandbox/.env" ]; then
            pass "Creates empty cli_sandbox/.env when no .example"
        else
            fail "cli_sandbox/.env should be empty"
        fi
    else
        fail "cli_sandbox/.env was not created"
    fi

    cleanup
}

# Test 6: Skips when .env.sandbox already exists
# テスト6: .env.sandbox が既に存在する場合はスキップ
test_skips_existing_env_sandbox() {
    echo ""
    echo "=== Test: Skips when .env.sandbox already exists ==="

    setup

    # Create existing .env.sandbox with specific content
    # 特定の内容で既存の .env.sandbox を作成
    echo "EXISTING_VALUE=keep_this" > "$TEST_PROJECT/.env.sandbox"

    # Create different .env.sandbox.example
    # 異なる内容の .env.sandbox.example を作成
    echo "NEW_VALUE=should_not_replace" > "$TEST_PROJECT/.env.sandbox.example"

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    local content
    content=$(cat "$TEST_PROJECT/.env.sandbox")
    if [ "$content" = "EXISTING_VALUE=keep_this" ]; then
        pass "Skips existing .env.sandbox (preserves content)"
    else
        fail "Should not overwrite existing .env.sandbox"
    fi

    cleanup
}

# Test 7: Skips when cli_sandbox/.env already exists
# テスト7: cli_sandbox/.env が既に存在する場合はスキップ
test_skips_existing_cli_env() {
    echo ""
    echo "=== Test: Skips when cli_sandbox/.env already exists ==="

    setup
    mkdir -p "$TEST_PROJECT/cli_sandbox"

    # Create existing .env with specific content
    echo "EXISTING_CLI=keep_this" > "$TEST_PROJECT/cli_sandbox/.env"

    # Create different .env.example
    echo "NEW_CLI=should_not_replace" > "$TEST_PROJECT/cli_sandbox/.env.example"

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    local content
    content=$(cat "$TEST_PROJECT/cli_sandbox/.env")
    if [ "$content" = "EXISTING_CLI=keep_this" ]; then
        pass "Skips existing cli_sandbox/.env (preserves content)"
    else
        fail "Should not overwrite existing cli_sandbox/.env"
    fi

    cleanup
}

# Test 8: Skips cli_sandbox when directory doesn't exist
# テスト8: cli_sandbox ディレクトリがない場合はスキップ
test_skips_missing_cli_sandbox_dir() {
    echo ""
    echo "=== Test: Skips cli_sandbox when directory doesn't exist ==="

    setup

    # Don't create cli_sandbox directory

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    if [ ! -d "$TEST_PROJECT/cli_sandbox" ]; then
        pass "Does not create cli_sandbox directory"
    else
        fail "Should not create cli_sandbox directory"
    fi

    cleanup
}

# Test 9: Output shows initialization message
# テスト9: 出力に初期化メッセージが含まれる
test_output_shows_initialization() {
    echo ""
    echo "=== Test: Output shows initialization message ==="

    setup

    local output
    output=$(bash "$SCRIPT" --silent "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "Created\|作成"; then
        pass "Output shows initialization message"
    else
        fail "Output should show initialization message"
    fi

    cleanup
}

# Test 10: Uses current directory when no argument
# テスト10: 引数がない場合はカレントディレクトリを使用
test_uses_current_directory() {
    echo ""
    echo "=== Test: Uses current directory when no argument ==="

    setup
    cd "$TEST_PROJECT"

    # Run without project_root argument (silent mode to avoid interactive prompt)
    bash "$SCRIPT" --silent > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        pass "Uses current directory when no argument"
    else
        fail "Should use current directory when no argument"
    fi

    cd - > /dev/null
    cleanup
}

# Test 11: --help option shows usage
# テスト11: --help オプションで使用方法を表示
test_help_option() {
    echo ""
    echo "=== Test: --help option shows usage ==="

    local output
    output=$(bash "$SCRIPT" --help 2>&1)

    if echo "$output" | grep -q "silent" && echo "$output" | grep -q "サイレントモード"; then
        pass "--help shows usage information"
    else
        fail "--help should show usage with silent mode info"
    fi
}

# Test 12: Interactive mode with Japanese selection (new file)
# テスト12: 対話モード（デフォルト）で日本語選択（新規ファイル）
test_interactive_japanese_new_file() {
    echo ""
    echo "=== Test: Interactive mode with Japanese selection (new file) ==="

    setup

    # Create .env.sandbox.example with LANG setting
    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
EOF

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2), decline install (2)
    echo -e "2\n2\n2" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^LANG=ja_JP.UTF-8" "$TEST_PROJECT/.env.sandbox"; then
            pass "Interactive mode sets Japanese language on new file"
        else
            fail "LANG should be ja_JP.UTF-8"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    cleanup
}

# Test 13: Interactive mode with English selection (new file)
# テスト13: 対話モード（デフォルト）で英語選択（新規ファイル）
test_interactive_english_new_file() {
    echo ""
    echo "=== Test: Interactive mode with English selection (new file) ==="

    setup

    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=ja_JP.UTF-8
EOF

    # Run in default (interactive) mode, select English (1), decline install (2)
    echo -e "1\n2" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^LANG=C.UTF-8" "$TEST_PROJECT/.env.sandbox"; then
            pass "Interactive mode sets English language on new file"
        else
            fail "LANG should be C.UTF-8"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    cleanup
}

# Test 14: Interactive mode updates existing file when confirmed
# テスト14: 対話モード（デフォルト）で既存ファイルを確認後に更新
test_interactive_update_existing() {
    echo ""
    echo "=== Test: Interactive mode updates existing file when confirmed ==="

    setup

    # Create existing .env.sandbox with English
    echo "LANG=C.UTF-8" > "$TEST_PROJECT/.env.sandbox"

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2), decline install (2), confirm update (y)
    echo -e "2\n2\n2\ny" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if grep -q "^LANG=ja_JP.UTF-8" "$TEST_PROJECT/.env.sandbox"; then
        pass "Interactive mode updates language when confirmed"
    else
        fail "LANG should be updated to ja_JP.UTF-8"
    fi

    cleanup
}

# Test 15: Interactive mode preserves existing file when declined
# テスト15: 対話モード（デフォルト）で更新を拒否した場合は既存ファイルを保持
test_interactive_decline_update() {
    echo ""
    echo "=== Test: Interactive mode preserves existing file when declined ==="

    setup

    # Create existing .env.sandbox with English
    echo "LANG=C.UTF-8" > "$TEST_PROJECT/.env.sandbox"

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2), decline install (2), decline update (n)
    echo -e "2\n2\n2\nn" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if grep -q "^LANG=C.UTF-8" "$TEST_PROJECT/.env.sandbox"; then
        pass "Interactive mode preserves language when declined"
    else
        fail "LANG should remain C.UTF-8"
    fi

    cleanup
}

# Test 16: Japanese selection + accept TZ sets Asia/Tokyo
# テスト16: 日本語選択 + TZ 承認で Asia/Tokyo が設定される
test_interactive_japanese_with_tz() {
    echo ""
    echo "=== Test: Japanese selection + accept TZ sets Asia/Tokyo ==="

    setup

    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
# TZ=Asia/Tokyo
EOF

    # Select Japanese (2), accept TZ (1), decline install (2)
    echo -e "2\n1\n2" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^TZ=Asia/Tokyo" "$TEST_PROJECT/.env.sandbox"; then
            pass "Japanese + accept TZ sets TZ=Asia/Tokyo"
        else
            fail "TZ should be Asia/Tokyo, got: $(grep 'TZ' "$TEST_PROJECT/.env.sandbox" || echo '(not found)')"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    cleanup
}

# Test 17: Japanese selection + decline TZ keeps TZ commented
# テスト17: 日本語選択 + TZ 拒否でコメントアウトのまま
test_interactive_japanese_decline_tz() {
    echo ""
    echo "=== Test: Japanese selection + decline TZ keeps TZ commented ==="

    setup

    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
# TZ=Asia/Tokyo
EOF

    # Select Japanese (2), decline TZ (2), decline install (2)
    echo -e "2\n2\n2" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^# TZ=" "$TEST_PROJECT/.env.sandbox" && ! grep -q "^TZ=" "$TEST_PROJECT/.env.sandbox"; then
            pass "Japanese + decline TZ keeps TZ commented out"
        else
            fail "TZ should remain commented, got: $(grep 'TZ' "$TEST_PROJECT/.env.sandbox" || echo '(not found)')"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    cleanup
}

# Test 18: English selection does not prompt for TZ
# テスト18: 英語選択時は TZ の質問が出ない
test_interactive_english_no_tz_prompt() {
    echo ""
    echo "=== Test: English selection does not change TZ ==="

    setup

    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
# TZ=Asia/Tokyo
EOF

    # Select English (1), decline install (2) — no TZ prompt should appear
    echo -e "1\n2" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^# TZ=" "$TEST_PROJECT/.env.sandbox" && ! grep -q "^TZ=" "$TEST_PROJECT/.env.sandbox"; then
            pass "English selection keeps TZ commented (no TZ prompt)"
        else
            fail "TZ should remain commented for English selection"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    cleanup
}

# Test 19: Japanese + TZ on existing file updates TZ
# テスト19: 既存ファイルで日本語 + TZ 更新
test_interactive_tz_update_existing() {
    echo ""
    echo "=== Test: Japanese + TZ on existing file updates TZ ==="

    setup

    # Create existing .env.sandbox without TZ
    cat > "$TEST_PROJECT/.env.sandbox" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
EOF

    # Select Japanese (2), accept TZ (1), decline install (2), confirm update (y)
    echo -e "2\n1\n2\ny" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

    if grep -q "^TZ=Asia/Tokyo" "$TEST_PROJECT/.env.sandbox"; then
        pass "TZ=Asia/Tokyo added to existing file"
    else
        fail "TZ should be added, got: $(grep 'TZ' "$TEST_PROJECT/.env.sandbox" || echo '(not found)')"
    fi

    cleanup
}

# Test 20: Creates .sandbox/.host-os with OS and arch info
# テスト20: .sandbox/.host-os にOS・アーキテクチャ情報を書き出す
test_creates_host_os_file() {
    echo ""
    echo "=== Test: Creates .sandbox/.host-os with OS and arch info ==="

    setup
    mkdir -p "$TEST_PROJECT/.sandbox"

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    local host_os_file="$TEST_PROJECT/.sandbox/.host-os"
    if [ ! -f "$host_os_file" ]; then
        fail ".sandbox/.host-os was not created"
        cleanup
        return
    fi

    local line_count
    line_count=$(wc -l < "$host_os_file")
    if [ "$line_count" -ne 2 ]; then
        fail ".host-os should have exactly 2 lines, got $line_count"
        cleanup
        return
    fi

    local os_name arch_name
    os_name=$(sed -n '1p' "$host_os_file")
    arch_name=$(sed -n '2p' "$host_os_file")

    # OS name should be lowercase (e.g., linux, darwin)
    # OS名は小文字であること（例: linux, darwin）
    if echo "$os_name" | grep -qE '^[a-z]+$'; then
        pass ".host-os line 1: OS name is lowercase ($os_name)"
    else
        fail ".host-os line 1: OS name should be lowercase, got: $os_name"
    fi

    # Arch should be normalized (amd64 or arm64, not x86_64 or aarch64)
    # アーキテクチャは正規化されていること（x86_64→amd64, aarch64→arm64）
    if echo "$arch_name" | grep -qE '^(amd64|arm64|armv7l|i386|i686|s390x|ppc64le|riscv64)$'; then
        pass ".host-os line 2: arch is normalized ($arch_name)"
    else
        fail ".host-os line 2: unexpected arch value: $arch_name"
    fi

    cleanup
}

# Test 21: .sandbox/.host-os is overwritten on each run
# テスト21: .sandbox/.host-os は毎回上書きされる
test_host_os_file_overwritten() {
    echo ""
    echo "=== Test: .sandbox/.host-os is overwritten on each run ==="

    setup
    mkdir -p "$TEST_PROJECT/.sandbox"

    # Create stale .host-os
    # 古い .host-os を作成
    printf "oldos\noldarch\n" > "$TEST_PROJECT/.sandbox/.host-os"

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    local os_name
    os_name=$(sed -n '1p' "$TEST_PROJECT/.sandbox/.host-os")
    if [ "$os_name" != "oldos" ]; then
        pass ".host-os is overwritten on each run (was oldos, now $os_name)"
    else
        fail ".host-os should be overwritten, still contains old value"
    fi

    cleanup
}

# ─── hostmcp helper: create mock bin dir ───────────────────────────────────────
# Usage: _setup_hostmcp_mocks <fake_gopath_var> <mock_bin_var>
#   Sets named variables to temp dirs and prepends mock_bin to PATH.
#   fake_go is written to mock_bin/go; callers customise hostmcp and gopath/bin.
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
    rm -rf "$fp" "$mb"
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

    # Input: language=1(English), port=default(1)
    local output
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "hostmcp が見つかりません"; then
        fail "Install prompt should NOT appear when hostmcp is already installed"
    else
        pass "No install prompt when hostmcp already installed"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 23: hostmcp not installed, user accepts → go install called, binary confirmed
test_interactive_hostmcp_install_accepted() {
    echo ""
    echo "=== Test: hostmcp install accepted → go install executed ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    # Input: language=1, install=1(yes), port=default(1)
    local output
    output=$(echo -e "1\n1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "インストールが完了"; then
        pass "hostmcp install completed message shown"
    else
        fail "Expected install completion message, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 24: hostmcp not installed, user declines → init and next steps skipped
test_interactive_hostmcp_install_declined() {
    echo ""
    echo "=== Test: hostmcp install declined → init skipped ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    # Input: language=1, install=2(no)
    local output
    output=$(echo -e "1\n2" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "セットアップをスキップしました"; then
        pass "Skip message shown when install declined"
    else
        fail "Expected skip message, got: $output"
    fi

    if echo "$output" | grep -q "セットアップが完了しました"; then
        fail "Next-steps message should NOT appear when install declined"
    else
        pass "Next-steps message not shown when install declined"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 25: go not found → error shown, init skipped
test_interactive_hostmcp_no_go() {
    echo ""
    echo "=== Test: go command not found → error shown ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb
    rm -f "$mb/go"  # No go in mock bin

    # Run with PATH that excludes system go (use only /usr/bin:/bin + mock_bin)
    local output
    output=$(echo -e "1" | PATH="$mb:/usr/bin:/bin:/usr/sbin:/sbin" bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "go コマンドが見つかりません"; then
        pass "Error shown when go is not found"
    else
        fail "Expected go-not-found error, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
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

    # Input: language=1, port=default(1)
    echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

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

    # Input: language=1, port=custom(2), port_number=9999
    echo -e "1\n2\n9999" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1

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
    output=$(echo -e "1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "設定ファイルは既に存在します"; then
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
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "hostmcp serve"; then
        pass "Next steps (hostmcp serve) shown after init success"
    else
        fail "Expected next steps, got: $output"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 30: --silent mode → hostmcp setup entirely skipped
test_silent_mode_skips_hostmcp_setup() {
    echo ""
    echo "=== Test: --silent mode skips hostmcp setup ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.sandbox/config/hostmcp.yaml" ]; then
        fail "hostmcp.yaml should NOT be created in --silent mode"
    else
        pass "hostmcp.yaml not created in --silent mode"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 31: go install fails → error shown, init skipped
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
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "インストールに失敗"; then
        pass "Install failure error shown"
    else
        fail "Expected install failure message, got: $output"
    fi

    if echo "$output" | grep -q "セットアップが完了"; then
        fail "Next steps should NOT appear after install failure"
    else
        pass "Next steps not shown after install failure"
    fi

    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 32: go install succeeds but binary not found → failure
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
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "インストールに失敗"; then
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

    # Input: lang=1, port=custom(2), bad=abc, then valid=8080
    local output
    output=$(echo -e "1\n2\nabc\n8080" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "無効なポート番号"; then
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
    output=$(echo -e "1\n2\n99999\n8080" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "無効なポート番号"; then
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
    output=$(echo -e "1\n2\nabc\nxyz\n99999" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "デフォルトポート（18080）を使用します"; then
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
    output=$(HOME="$fake_home" bash -c "export PATH='$mb:$PATH'; echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'" 2>&1)

    if echo "$output" | grep -q "インストールが完了\|セットアップが完了"; then
        pass "Empty GOPATH: fallback to \$HOME/go/bin works"
    else
        fail "Expected success with HOME/go fallback, got: $output"
    fi

    rm -rf "$fake_home"
    _cleanup_mocks "$fp" "$mb"
    cleanup
}

# Test 37: go env GOPATH exits non-zero → error shown
test_interactive_hostmcp_gopath_command_fails() {
    echo ""
    echo "=== Test: go env GOPATH fails → error shown ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    cat > "$mb/go" << 'GOEOF'
#!/bin/bash
if [ "$1" = "env" ] && [ "$2" = "GOPATH" ]; then
    exit 1
fi
GOEOF
    chmod +x "$mb/go"

    local output
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "GOPATH が取得できません"; then
        pass "Error shown when go env GOPATH fails"
    else
        fail "Expected GOPATH error, got: $output"
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
    output=$(cd "$TEST_PROJECT" && echo -e "1\n1" | PATH="$mb:$PATH" bash "$SCRIPT" "." 2>&1)

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
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

    if echo "$output" | grep -q "設定ファイル生成に失敗"; then
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

# Run all tests
# 全テストを実行
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  init-host-env.sh Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    test_script_executable_and_valid
    test_creates_env_sandbox_from_example
    test_creates_empty_env_sandbox
    test_creates_cli_env_from_example
    test_creates_empty_cli_env
    test_skips_existing_env_sandbox
    test_skips_existing_cli_env
    test_skips_missing_cli_sandbox_dir
    test_output_shows_initialization
    test_uses_current_directory
    test_help_option
    test_interactive_japanese_new_file
    test_interactive_english_new_file
    test_interactive_update_existing
    test_interactive_decline_update
    test_interactive_japanese_with_tz
    test_interactive_japanese_decline_tz
    test_interactive_english_no_tz_prompt
    test_interactive_tz_update_existing
    test_creates_host_os_file
    test_host_os_file_overwritten
    test_interactive_hostmcp_already_installed
    test_interactive_hostmcp_install_accepted
    test_interactive_hostmcp_install_declined
    test_interactive_hostmcp_no_go
    test_interactive_hostmcp_init_default_port
    test_interactive_hostmcp_init_custom_port
    test_interactive_hostmcp_init_already_exists
    test_interactive_hostmcp_next_steps_shown
    test_silent_mode_skips_hostmcp_setup
    test_interactive_hostmcp_install_go_install_fails
    test_interactive_hostmcp_install_binary_not_found_after_install
    test_interactive_hostmcp_init_invalid_port_string
    test_interactive_hostmcp_init_invalid_port_out_of_range
    test_interactive_hostmcp_port_retry_fallback
    test_interactive_hostmcp_gopath_empty
    test_interactive_hostmcp_gopath_command_fails
    test_interactive_hostmcp_next_steps_shows_absolute_path
    test_interactive_hostmcp_init_fails_skips_next_steps

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

#!/bin/bash
# test-init-host-env.sh
# Test script for init-host-env.sh
#
# init-host-env.sh のテストスクリプト
#
# Usage: ./test-init-host-env.sh
# 使用方法: ./test-init-host-env.sh
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

# Test: SANDBOX_ENV alone (no /.dockerenv) must NOT block execution — this is
# a regression test: SANDBOX_ENV can be exported on the HOST shell too
# (cli_sandbox/_common.sh sets it before invoking this script, and a user
# could also export it manually outside any container), so treating it as an
# "inside container" signal would wrongly block that legitimate host-side
# call path.
# (The actual /.dockerenv-present "must block" branch is not covered here:
# simulating it would require creating Docker's marker file on the real host
# filesystem, which this test suite avoids as too invasive to automate.)
# テスト: SANDBOX_ENV だけが設定されていて /.dockerenv がない場合はブロックしない
# ことを確認する回帰テスト。SANDBOX_ENV はホストOS側のシェルでも設定されうる値
# のため（cli_sandbox/_common.sh がこのスクリプトを呼び出す前に設定する場合や、
# ユーザーが手動で export した場合も含む）、これを「コンテナ内」の判定に使うと、
# その正規のホスト側呼び出しまで誤ってブロックしてしまう。
# （実際に /.dockerenv が存在する「ブロックすべき」分岐はここではカバーしていない。
# 　再現には実ホストのファイルシステムに Docker のマーカーファイルを作る必要があり、
# 　自動テストとしては侵襲的すぎるため避けている。）
test_sandbox_env_alone_does_not_block() {
    echo ""
    echo "=== Test: SANDBOX_ENV set without /.dockerenv does not block execution ==="

    setup

    local output exit_code
    output=$(SANDBOX_ENV=cli_claude bash "$SCRIPT" --silent "$TEST_PROJECT" 2>&1) && exit_code=0 || exit_code=$?

    if [ "$exit_code" -eq 0 ] && ! echo "$output" | grep -q "cannot be run inside the AI Sandbox container"; then
        pass "SANDBOX_ENV alone does not block execution (matches cli_sandbox host-side call path)"
    else
        fail "Should not block on SANDBOX_ENV alone, got exit_code=$exit_code, output: $output"
    fi

    cleanup
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
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    # Create .env.sandbox.example with LANG setting
    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
EOF

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2), decline install (2)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n2\n2' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^LANG=ja_JP.UTF-8" "$TEST_PROJECT/.env.sandbox"; then
            pass "Interactive mode sets Japanese language on new file"
        else
            fail "LANG should be ja_JP.UTF-8"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test 13: Interactive mode with English selection (new file)
# テスト13: 対話モード（デフォルト）で英語選択（新規ファイル）
test_interactive_english_new_file() {
    echo ""
    echo "=== Test: Interactive mode with English selection (new file) ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=ja_JP.UTF-8
EOF

    # Run in default (interactive) mode, select English (1), decline install (2)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '1\n2' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^LANG=C.UTF-8" "$TEST_PROJECT/.env.sandbox"; then
            pass "Interactive mode sets English language on new file"
        else
            fail "LANG should be C.UTF-8"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test 14: Interactive mode updates existing file when confirmed
# テスト14: 対話モード（デフォルト）で既存ファイルを確認後に更新
test_interactive_update_existing() {
    echo ""
    echo "=== Test: Interactive mode updates existing file when confirmed ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    # Create existing .env.sandbox with English
    echo "LANG=C.UTF-8" > "$TEST_PROJECT/.env.sandbox"

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2), decline install (2), confirm update (y)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n2\n2\ny' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if grep -q "^LANG=ja_JP.UTF-8" "$TEST_PROJECT/.env.sandbox"; then
        pass "Interactive mode updates language when confirmed"
    else
        fail "LANG should be updated to ja_JP.UTF-8"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test 15: Interactive mode preserves existing file when declined
# テスト15: 対話モード（デフォルト）で更新を拒否した場合は既存ファイルを保持
test_interactive_decline_update() {
    echo ""
    echo "=== Test: Interactive mode preserves existing file when declined ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    # Create existing .env.sandbox with English
    echo "LANG=C.UTF-8" > "$TEST_PROJECT/.env.sandbox"

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2), decline install (2), decline update (n)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n2\n2\nn' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if grep -q "^LANG=C.UTF-8" "$TEST_PROJECT/.env.sandbox"; then
        pass "Interactive mode preserves language when declined"
    else
        fail "LANG should remain C.UTF-8"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test 16: Japanese selection + accept TZ sets Asia/Tokyo
# テスト16: 日本語選択 + TZ 承認で Asia/Tokyo が設定される
test_interactive_japanese_with_tz() {
    echo ""
    echo "=== Test: Japanese selection + accept TZ sets Asia/Tokyo ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
# TZ=Asia/Tokyo
EOF

    # Select Japanese (2), accept TZ (1), decline install (2)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n1\n2' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^TZ=Asia/Tokyo" "$TEST_PROJECT/.env.sandbox"; then
            pass "Japanese + accept TZ sets TZ=Asia/Tokyo"
        else
            fail "TZ should be Asia/Tokyo, got: $(grep 'TZ' "$TEST_PROJECT/.env.sandbox" || echo '(not found)')"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test 17: Japanese selection + decline TZ keeps TZ commented
# テスト17: 日本語選択 + TZ 拒否でコメントアウトのまま
test_interactive_japanese_decline_tz() {
    echo ""
    echo "=== Test: Japanese selection + decline TZ keeps TZ commented ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
# TZ=Asia/Tokyo
EOF

    # Select Japanese (2), decline TZ (2), decline install (2)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n2\n2' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^# TZ=" "$TEST_PROJECT/.env.sandbox" && ! grep -q "^TZ=" "$TEST_PROJECT/.env.sandbox"; then
            pass "Japanese + decline TZ keeps TZ commented out"
        else
            fail "TZ should remain commented, got: $(grep 'TZ' "$TEST_PROJECT/.env.sandbox" || echo '(not found)')"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test 18: English selection does not prompt for TZ
# テスト18: 英語選択時は TZ の質問が出ない
test_interactive_english_no_tz_prompt() {
    echo ""
    echo "=== Test: English selection does not change TZ ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    cat > "$TEST_PROJECT/.env.sandbox.example" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
# TZ=Asia/Tokyo
EOF

    # Select English (1), decline install (2) — no TZ prompt should appear
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '1\n2' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if [ -f "$TEST_PROJECT/.env.sandbox" ]; then
        if grep -q "^# TZ=" "$TEST_PROJECT/.env.sandbox" && ! grep -q "^TZ=" "$TEST_PROJECT/.env.sandbox"; then
            pass "English selection keeps TZ commented (no TZ prompt)"
        else
            fail "TZ should remain commented for English selection"
        fi
    else
        fail ".env.sandbox was not created"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test 19: Japanese + TZ on existing file updates TZ
# テスト19: 既存ファイルで日本語 + TZ 更新
test_interactive_tz_update_existing() {
    echo ""
    echo "=== Test: Japanese + TZ on existing file updates TZ ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    # Create existing .env.sandbox without TZ
    cat > "$TEST_PROJECT/.env.sandbox" << 'EOF'
NODE_ENV=development
LANG=C.UTF-8
EOF

    # Select Japanese (2), accept TZ (1), decline install (2), confirm update (y)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n1\n2\ny' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

    if grep -q "^TZ=Asia/Tokyo" "$TEST_PROJECT/.env.sandbox"; then
        pass "TZ=Asia/Tokyo added to existing file"
    else
        fail "TZ should be added, got: $(grep 'TZ' "$TEST_PROJECT/.env.sandbox" || echo '(not found)')"
    fi

    safe_rm_rf "$fake_home" "$mb"
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

# Test: MINGW/MSYS/CYGWIN uname is normalized to "windows" in .host-os,
# matching the normalization already used for the hostmcp binary filename in
# _download_hostmcp_binary (both now share _detect_os_name). Regression test
# for A2-2: the .host-os write previously lacked this normalization and would
# write the raw MINGW/MSYS/CYGWIN uname string instead.
# テスト: .host-os でも MINGW/MSYS/CYGWIN の uname が「windows」に正規化される
# ことを確認する回帰テスト（_download_hostmcp_binary と _detect_os_name を共有）。
# 修正前は .host-os の書き出し処理にこの正規化がなく、MINGW/MSYS/CYGWIN の生の
# uname文字列がそのまま書き込まれていた。
test_creates_host_os_file_windows_normalized() {
    echo ""
    echo "=== Test: .host-os normalizes MINGW/MSYS/CYGWIN uname to 'windows' ==="

    setup
    local mock_bin
    mock_bin=$(mktemp -d)
    cat > "$mock_bin/uname" << 'EOF'
#!/bin/bash
case "$1" in
    -s) echo "MINGW64_NT-10.0-19045" ;;
    -m) echo "x86_64" ;;
esac
EOF
    chmod +x "$mock_bin/uname"

    PATH="$mock_bin:$PATH" bash "$SCRIPT" --silent "$TEST_PROJECT" > /dev/null 2>&1

    local os_name
    os_name=$(sed -n '1p' "$TEST_PROJECT/.sandbox/.host-os" 2>/dev/null)

    if [ "$os_name" = "windows" ]; then
        pass ".host-os normalizes MINGW uname to 'windows'"
    else
        fail ".host-os should contain 'windows' for MINGW uname, got: $os_name"
    fi

    safe_rm_rf "$mock_bin"
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
#
# KNOWN LIMITATION: this helper always places a fake hostmcp at mock_bin/hostmcp
# (needed so the later `hostmcp init` call can resolve it after a simulated
# `go install`). That means `command -v hostmcp` succeeds from the very start,
# so tests built on this helper can never exercise the "hostmcp not found yet,
# user accepts install" branch — DKMCP_AVAILABLE is already true before the
# script's install-prompt check runs. Tests that need that branch are disabled
# in main() (see test_interactive_hostmcp_install_accepted and friends below).
# Fixing this requires reworking the fixture so the stub only appears after a
# simulated install, without breaking the ~11 other tests that rely on hostmcp
# being pre-available (already-installed / init / port-selection scenarios).
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
# DISABLED: _setup_hostmcp_mocks always makes hostmcp findable via mock_bin,
# so the "not found" branch this test depends on can never execute. See the
# KNOWN LIMITATION note on _setup_hostmcp_mocks above. Not called from main().
test_interactive_hostmcp_install_accepted() {
    echo ""
    echo "=== Test: hostmcp install accepted → go install executed ==="

    setup
    local fp mb
    _setup_hostmcp_mocks fp mb

    # Input: language=1, install=1(yes), port=default(1)
    local output
    output=$(echo -e "1\n1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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

    # Input: language=1, install=2(no)
    local output
    output=$(echo -e "1\n2" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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
    mb=$(mktemp -d)
    fake_home=$(mktemp -d)

    # Fake curl (decline install so download isn't attempted)
    printf '#!/bin/bash\nexit 0\n' > "$mb/curl"
    chmod +x "$mb/curl"

    # Input: lang=1(English), install=2(decline)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n2' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "download binary from GitHub Releases"; then
        pass "Binary download option shown when go is not found"
    else
        fail "Expected binary download option, got: $output"
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

    # Input: lang=1(English), install=1(accept), port=default(1)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: language=1, port=custom(2), port_number=08080
    local exit_code
    echo -e "1\n2\n08080" | bash "$SCRIPT" "$TEST_PROJECT" > /dev/null 2>&1 && exit_code=0 || exit_code=$?

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

    # Input: language=1, port=custom(2), port_number=01777
    local output
    output=$(echo -e "1\n2\n01777" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1) || true

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
    output=$(echo -e "1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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

    # Input: lang=1, port=custom(2), bad=abc, then valid=8080
    local output
    output=$(echo -e "1\n2\nabc\n8080" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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
    output=$(echo -e "1\n2\n99999\n8080" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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
    output=$(echo -e "1\n2\nabc\nxyz\n99999" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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
    output=$(HOME="$fake_home" bash -c "export PATH='$mb:$PATH'; echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'" 2>&1)

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
    output=$(echo -e "1\n1" | bash "$SCRIPT" "$TEST_PROJECT" 2>&1)

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
    local _home _mb
    _home=$(mktemp -d)
    _mb=$(mktemp -d)
    eval "$_home_var='$_home'"
    eval "$_mb_var='$_mb'"

    # Fake curl: handles both version fetch (-o /dev/null) and binary download (-o <path>)
    cat > "$_mb/curl" << 'CURLEOF'
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
    chmod +x "$_mb/curl"
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

    # Input: lang=1(English), install=2(decline)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n2' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1, install=1(yes), install-dir=default(1, now ~/.local/bin), port=default(1)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1, install=1(yes), install-dir=2(~/go/bin), port=default(1)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1\n2\n1' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1, install=1(yes), install-dir=default(1), port=default(1)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1, install=1(yes), install-dir=default(1), port=default(1)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1, install=1(yes), install-dir=2(~/go/bin), port=default(1)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1\n2\n1' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1, install=1(yes), install-dir=default(1)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1, install=1(yes), install-dir=default(1) — no curl/wget in PATH
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb'
        echo -e '1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1(English), install=2(decline) — just to see the prompt text
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n2' | bash '$SCRIPT' '$TEST_PROJECT'
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

    # Input: lang=1, install=1(yes), install-dir=default(1), port=default(1)
    local output
    output=$(HOME="$fake_home" bash -c "
        export PATH='$mb:/usr/bin:/bin:/usr/sbin:/sbin'
        echo -e '1\n1\n1\n1' | bash '$SCRIPT' '$TEST_PROJECT'
    " 2>&1)

    if echo "$output" | grep -q "installed to:"; then
        pass "Install succeeds even when version fetch fails"
    else
        fail "Expected install success despite version fetch failure, got: $output"
    fi

    _cleanup_binary_download_mocks "$fake_home" "$mb"
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
    test_sandbox_env_alone_does_not_block
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
    test_creates_host_os_file_windows_normalized
    test_host_os_file_overwritten
    test_interactive_hostmcp_already_installed
    # test_interactive_hostmcp_install_accepted  # DISABLED: see _setup_hostmcp_mocks KNOWN LIMITATION
    # test_interactive_hostmcp_install_declined  # DISABLED: see _setup_hostmcp_mocks KNOWN LIMITATION
    test_interactive_hostmcp_no_go
    test_interactive_hostmcp_go_install_windows_exe
    test_interactive_hostmcp_init_default_port
    test_interactive_hostmcp_init_custom_port
    test_interactive_hostmcp_init_port_leading_zero_no_crash
    test_interactive_hostmcp_init_port_leading_zero_decimal_value
    test_interactive_hostmcp_init_already_exists
    test_interactive_hostmcp_next_steps_shown
    test_silent_mode_skips_hostmcp_setup
    # test_interactive_hostmcp_install_go_install_fails  # DISABLED: see _setup_hostmcp_mocks KNOWN LIMITATION
    # test_interactive_hostmcp_install_binary_not_found_after_install  # DISABLED: see _setup_hostmcp_mocks KNOWN LIMITATION
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

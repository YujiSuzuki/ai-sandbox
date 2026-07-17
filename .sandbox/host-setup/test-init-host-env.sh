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

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n2' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

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

    # Run in default (interactive) mode, select English (1)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '1' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

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

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2), confirm update (y)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n2\ny' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

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

    # Run in default (interactive) mode, select Japanese (2), decline TZ (2), decline update (n)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n2\nn' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

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

    # Select Japanese (2), accept TZ (1)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n1' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

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

    # Select Japanese (2), decline TZ (2)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n2' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

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

    # Select English (1) — no TZ prompt should appear
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '1' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

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

    # Select Japanese (2), accept TZ (1), confirm update (y)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '2\n1\ny' | bash '$SCRIPT' '$TEST_PROJECT'" > /dev/null 2>&1

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
# matching the normalization also used for the hostmcp binary filename in
# install-hostmcp.sh's _download_hostmcp_binary (both scripts keep their own
# copy of _detect_os_name — see the comment on
# test_detect_os_name_stays_in_sync_with_install_hostmcp below for why they split).
# Regression test for A2-2: the .host-os write previously lacked this
# normalization and would write the raw MINGW/MSYS/CYGWIN uname string instead.
# テスト: .host-os でも MINGW/MSYS/CYGWIN の uname が「windows」に正規化される
# ことを確認する回帰テスト（install-hostmcp.sh の _download_hostmcp_binary と
# 同じ正規化を使用。_detect_os_name は両スクリプトがそれぞれ独自に持つ —
# 分割理由は下記の test_detect_os_name_stays_in_sync_with_install_hostmcp の
# コメント参照）。
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

# Code-review guard: init-host-env.sh and install-hostmcp.sh each keep their
# own copy of _detect_os_name (see the comment on
# test_creates_host_os_file_windows_normalized above for why they split).
# The two copies are not a single source of truth, so a future edit to only
# one of them (e.g. adding another `uname -s` case) can silently make them
# diverge. This test guards that constraint by failing loudly the moment the
# two copies produce different output for the same input.
# コードレビューガード: init-host-env.sh と install-hostmcp.sh は
# それぞれ独自に _detect_os_name のコピーを持つ（分割理由は上の
# test_creates_host_os_file_windows_normalized のコメント参照）。2つの
# コピーは単一の定義を共有していないため、将来どちらか片方だけ修正されると
# （例: `uname -s` の分岐を追加）、静かに乖離しうる。このテストは、
# 2つのコピーが同じ入力に対して異なる出力を返した瞬間に検知して失敗させる
# ことでその制約を守る。
test_detect_os_name_stays_in_sync_with_install_hostmcp() {
    echo ""
    echo "=== Test: _detect_os_name stays identical between init-host-env.sh and install-hostmcp.sh ==="

    local other_script="$SCRIPT_DIR/install-hostmcp.sh"
    if [ ! -f "$other_script" ]; then
        fail "install-hostmcp.sh not found at $other_script — cannot compare _detect_os_name"
        return
    fi

    local this_def other_def
    this_def=$(awk '/^_detect_os_name\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT")
    other_def=$(awk '/^_detect_os_name\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$other_script")

    if [ -z "$this_def" ]; then
        fail "_detect_os_name not found in init-host-env.sh"
    elif [ -z "$other_def" ]; then
        fail "_detect_os_name not found in install-hostmcp.sh"
    elif [ "$this_def" = "$other_def" ]; then
        pass "_detect_os_name is identical in both scripts"
    else
        fail "_detect_os_name has diverged between init-host-env.sh and install-hostmcp.sh — mirror the change into both files:
--- init-host-env.sh ---
$this_def
--- install-hostmcp.sh ---
$other_def"
    fi
}

# Test: interactive mode points to install-hostmcp.sh when no HostMCP config
# exists yet and the install prompt is left at its default ("N", no answer
# left in the input queue after language selection is consumed).
# テスト: HostMCP の設定ファイルが未生成で、かつ言語選択で入力を使い切って
# インストール可否プロンプトがデフォルト（「N」）のままの場合、対話モードでは
# install-hostmcp.sh への案内が表示されることを確認する。
test_interactive_shows_install_hostmcp_hint() {
    echo ""
    echo "=== Test: interactive mode shows install-hostmcp.sh hint when config is missing ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb

    # Input: language=1(English) — no TZ prompt in English mode; no answer
    # left for the install prompt, so it falls through to its "N" default.
    local output
    output=$(HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '1' | bash '$SCRIPT' '$TEST_PROJECT'" 2>&1)

    if echo "$output" | grep -q "install-hostmcp.sh"; then
        pass "install-hostmcp.sh hint shown when hostmcp.yaml is missing"
    else
        fail "Expected install-hostmcp.sh hint, got: $output"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test: the hint is suppressed once HostMCP is already configured, and never
# printed at all in --silent mode (INTERACTIVE=false skips this block
# entirely regardless of whether hostmcp.yaml exists).
# テスト: HostMCP の設定ファイルが既に存在する場合は案内が表示されず、
# --silent モードでは（INTERACTIVE=false のため）そもそもこの分岐自体が
# 実行されないことを確認する。
test_interactive_hint_suppressed_when_configured_or_silent() {
    echo ""
    echo "=== Test: install-hostmcp.sh hint suppressed when configured or silent ==="

    setup
    local fake_home mb
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb
    mkdir -p "$TEST_PROJECT/.sandbox/config"
    touch "$TEST_PROJECT/.sandbox/config/hostmcp.yaml"

    local output
    output=$(HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '1' | bash '$SCRIPT' '$TEST_PROJECT'" 2>&1)

    if echo "$output" | grep -q "install-hostmcp.sh"; then
        fail "Hint should NOT appear when hostmcp.yaml already exists, got: $output"
    else
        pass "Hint suppressed when hostmcp.yaml already exists"
    fi

    local silent_output
    silent_output=$(HOME="$fake_home" bash -c "export PATH='$mb'; bash '$SCRIPT' --silent '$TEST_PROJECT'" 2>&1)

    if echo "$silent_output" | grep -q "install-hostmcp.sh"; then
        fail "Hint should NOT appear in --silent mode, got: $silent_output"
    else
        pass "Hint suppressed in --silent mode"
    fi

    safe_rm_rf "$fake_home" "$mb"
    cleanup
}

# Test: confirming the end-of-script "install HostMCP now?" prompt hands off
# to install-hostmcp.sh (invoked, not inlined — see init-host-env.sh header).
# Uses a stub install-hostmcp.sh in a scratch copy of the script pair so this
# stays a fast, offline unit test instead of driving a real install.
# テスト: 対話モード末尾の「HostMCPを今すぐインストール・設定しますか？」に
# yで応答すると install-hostmcp.sh に処理を引き継ぐ（呼び出すだけでインライン化
# しない — init-host-env.sh のヘッダー参照）ことを確認する。スクリプト一式の
# 使い捨てコピーとスタブの install-hostmcp.sh を使い、実際のインストールを
# 走らせずに高速・オフラインな単体テストとして完結させる。
test_interactive_confirms_install_calls_install_hostmcp() {
    echo ""
    echo "=== Test: confirming install prompt invokes install-hostmcp.sh ==="

    setup
    local fake_home mb tmp_script_dir marker
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb
    tmp_script_dir=$(mktemp -d)
    marker="$tmp_script_dir/called.marker"

    cp "$SCRIPT" "$tmp_script_dir/init-host-env.sh"
    chmod +x "$tmp_script_dir/init-host-env.sh"

    cat > "$tmp_script_dir/install-hostmcp.sh" << EOF
#!/bin/bash
echo "STUB install-hostmcp.sh called with: \$*" > "$marker"
EOF
    chmod +x "$tmp_script_dir/install-hostmcp.sh"

    # Select English (1), then confirm the install prompt (y)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '1\ny' | bash '$tmp_script_dir/init-host-env.sh' '$TEST_PROJECT'" > /dev/null 2>&1

    if [ -f "$marker" ] && grep -q "$TEST_PROJECT" "$marker"; then
        pass "Confirming install prompt invokes install-hostmcp.sh with project root"
    else
        fail "install-hostmcp.sh stub was not invoked as expected"
    fi

    safe_rm_rf "$fake_home" "$mb" "$tmp_script_dir"
    cleanup
}

# Test: declining the same prompt (or leaving it at the default "N") must
# NOT invoke install-hostmcp.sh — only print the "run it later" hint.
# テスト: 同じプロンプトを拒否（またはデフォルトの「N」のまま）にした場合は
# install-hostmcp.sh を呼び出さず、「後で実行してください」の案内だけを
# 表示することを確認する。
test_interactive_declines_install_does_not_call_install_hostmcp() {
    echo ""
    echo "=== Test: declining install prompt does not invoke install-hostmcp.sh ==="

    setup
    local fake_home mb tmp_script_dir marker
    fake_home=$(mktemp -d)
    _isolate_hostmcp_absent mb
    tmp_script_dir=$(mktemp -d)
    marker="$tmp_script_dir/called.marker"

    cp "$SCRIPT" "$tmp_script_dir/init-host-env.sh"
    chmod +x "$tmp_script_dir/init-host-env.sh"

    cat > "$tmp_script_dir/install-hostmcp.sh" << EOF
#!/bin/bash
echo "STUB install-hostmcp.sh called with: \$*" > "$marker"
EOF
    chmod +x "$tmp_script_dir/install-hostmcp.sh"

    # Select English (1), decline the install prompt (n)
    HOME="$fake_home" bash -c "export PATH='$mb'; echo -e '1\nn' | bash '$tmp_script_dir/init-host-env.sh' '$TEST_PROJECT'" > /dev/null 2>&1

    if [ -f "$marker" ]; then
        fail "install-hostmcp.sh stub should not have been invoked when declined"
    else
        pass "Declining install prompt does not invoke install-hostmcp.sh"
    fi

    safe_rm_rf "$fake_home" "$mb" "$tmp_script_dir"
    cleanup
}

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
    test_interactive_shows_install_hostmcp_hint
    test_interactive_hint_suppressed_when_configured_or_silent
    test_interactive_confirms_install_calls_install_hostmcp
    test_interactive_declines_install_does_not_call_install_hostmcp
    test_detect_os_name_stays_in_sync_with_install_hostmcp
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

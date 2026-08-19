#!/bin/bash
# test-validate-secrets.sh
# Test script for validate-secrets.py
#
# validate-secrets.py のテストスクリプト
#
# Usage: ./test-validate-secrets.sh
# 使用方法: ./test-validate-secrets.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/validate-secrets.py"
TEST_COMPOSE_DIR=""
TEST_SECRET_DIR=""

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

    # Create temporary directories
    # 一時ディレクトリを作成
    TEST_COMPOSE_DIR=$(mktemp -d)
    # Must be under $TEST_COMPOSE_DIR because validate-secrets.py (run with
    # WORKSPACE="$TEST_COMPOSE_DIR" below) only checks paths under $WORKSPACE in tmpfs
    # validate-secrets.py（下記で WORKSPACE="$TEST_COMPOSE_DIR" として実行）は
    # tmpfs で $WORKSPACE 配下のパスのみチェックするため、$TEST_COMPOSE_DIR 配下に作成
    TEST_SECRET_DIR=$(mktemp -d "$TEST_COMPOSE_DIR/.test-secrets-XXXXXX")

    mkdir -p "$TEST_COMPOSE_DIR/.devcontainer"
    mkdir -p "$TEST_COMPOSE_DIR/.sandbox/config"

    # Copy required config to the test workspace. Unlike the bash original,
    # validate-secrets.py imports _python_common/_secret_tag from its own
    # script directory (Python's default sys.path[0] behavior), not from
    # $WORKSPACE, so those two no longer need to be copied in here.
    # 必要な設定をテストワークスペースにコピー。bash版と異なり、
    # validate-secrets.py は _python_common/_secret_tag を（Pythonの
    # デフォルトのsys.path[0]の挙動により）自分のスクリプトディレクトリから
    # importするため、$WORKSPACE配下にコピーする必要はもう無い。
    cp "$SCRIPT_DIR/../config/startup.conf" "$TEST_COMPOSE_DIR/.sandbox/config/" 2>/dev/null || true
    cp "$SCRIPT_DIR/../config/sync-ignore" "$TEST_COMPOSE_DIR/.sandbox/config/" 2>/dev/null || true
}

# Cleanup test environment
# テスト環境のクリーンアップ
cleanup() {
    info "Cleaning up test environment..."

    if [ -n "$TEST_COMPOSE_DIR" ] && [ -d "$TEST_COMPOSE_DIR" ]; then
        rm -rf "$TEST_COMPOSE_DIR"
    fi

    if [ -n "$TEST_SECRET_DIR" ] && [ -d "$TEST_SECRET_DIR" ]; then
        rm -rf "$TEST_SECRET_DIR"
    fi
}

# Trap to ensure cleanup runs
# クリーンアップが必ず実行されるようトラップ設定
trap cleanup EXIT

# Create docker-compose.yml with secret config
# 秘匿設定付きの docker-compose.yml を作成
create_compose_with_secrets() {
    mkdir -p "$TEST_SECRET_DIR/secrets"
    cat > "$TEST_COMPOSE_DIR/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    volumes:
      - /dev/null:$TEST_SECRET_DIR/.env:ro
    tmpfs:
      - $TEST_SECRET_DIR/secrets  # @secret
EOF
}

# Create docker-compose.yml without secret config
# 秘匿設定なしの docker-compose.yml を作成
create_compose_without_secrets() {
    cat > "$TEST_COMPOSE_DIR/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    volumes:
      - ..:/workspace:cached
EOF
}

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
    if python3 -m py_compile "$SCRIPT" 2>/dev/null; then
        pass "Script is executable and has valid syntax"
    else
        fail "Script has syntax errors"
    fi
}

# Test 2: Script succeeds when secrets are properly hidden (empty)
# テスト2: 秘匿情報が正しく隠蔽されている場合（空）に成功するか
test_hidden_secrets_empty() {
    echo ""
    echo "=== Test: Hidden secrets (empty) ==="

    setup
    create_compose_with_secrets

    # Create empty .env file (simulates /dev/null mount)
    # 空の .env ファイルを作成（/dev/null マウントをシミュレート）
    touch "$TEST_SECRET_DIR/.env"
    # secrets/ directory is already empty
    # secrets/ ディレクトリは既に空

    if WORKSPACE="$TEST_COMPOSE_DIR" "$SCRIPT" > /dev/null 2>&1; then
        pass "Script succeeds when secrets are hidden"
    else
        fail "Script should succeed when secrets are hidden"
    fi

    cleanup
}

# Test 3: Script fails when secret file has content
# テスト3: 秘匿ファイルに内容がある場合に失敗するか
test_exposed_secret_file() {
    echo ""
    echo "=== Test: Exposed secret file (has content) ==="

    setup
    create_compose_with_secrets

    # Create .env with content (simulates exposed secret)
    # 内容のある .env を作成（露出した秘匿情報をシミュレート）
    echo "SECRET_KEY=exposed" > "$TEST_SECRET_DIR/.env"

    if WORKSPACE="$TEST_COMPOSE_DIR" "$SCRIPT" > /dev/null 2>&1; then
        fail "Script should fail when secret file has content"
    else
        pass "Script detects exposed secret file"
    fi

    cleanup
}

# Test 4: Script fails when secret directory has files
# テスト4: 秘匿ディレクトリにファイルがある場合に失敗するか
test_exposed_secret_dir() {
    echo ""
    echo "=== Test: Exposed secret directory (has files) ==="

    setup
    create_compose_with_secrets

    # Create empty .env
    # 空の .env を作成
    touch "$TEST_SECRET_DIR/.env"
    # Add file to secrets directory
    # secrets ディレクトリにファイルを追加
    echo "secret" > "$TEST_SECRET_DIR/secrets/key.txt"

    if WORKSPACE="$TEST_COMPOSE_DIR" "$SCRIPT" > /dev/null 2>&1; then
        fail "Script should fail when secret directory has files"
    else
        pass "Script detects exposed secret directory"
    fi

    cleanup
}

# Test 5: Script handles missing docker-compose.yml
# テスト5: docker-compose.yml がない場合の処理
test_missing_compose_file() {
    echo ""
    echo "=== Test: Missing docker-compose.yml ==="

    setup
    # Don't create docker-compose.yml

    if WORKSPACE="$TEST_COMPOSE_DIR" "$SCRIPT" > /dev/null 2>&1; then
        fail "Script should fail when docker-compose.yml is missing"
    else
        pass "Script fails when docker-compose.yml is missing"
    fi

    cleanup
}

# Test 6: Script handles no secret configuration
# テスト6: 秘匿設定がない場合の処理
test_no_secret_config() {
    echo ""
    echo "=== Test: No secret configuration ==="

    setup
    create_compose_without_secrets

    if WORKSPACE="$TEST_COMPOSE_DIR" "$SCRIPT" > /dev/null 2>&1; then
        pass "Script succeeds when no secrets are configured"
    else
        fail "Script should succeed when no secrets are configured"
    fi

    cleanup
}

# Test 7: Script succeeds when secret file doesn't exist
# テスト7: 秘匿ファイルが存在しない場合に成功するか
test_nonexistent_secret_file() {
    echo ""
    echo "=== Test: Non-existent secret file ==="

    setup
    create_compose_with_secrets

    # Don't create .env file at all
    # .env ファイルを作成しない
    # secrets/ directory is already empty
    # secrets/ ディレクトリは既に空

    if WORKSPACE="$TEST_COMPOSE_DIR" "$SCRIPT" > /dev/null 2>&1; then
        pass "Script succeeds when secret file doesn't exist"
    else
        fail "Script should succeed when secret file doesn't exist"
    fi

    cleanup
}

# Test 8: An untagged tmpfs entry is not picked up as a secret dir to validate
# テスト8: タグ無しのtmpfsエントリは検証対象の秘匿ディレクトリとして
# 拾われないことを確認する
test_untagged_entry_not_validated() {
    echo ""
    echo "=== Test: Untagged tmpfs entry is not validated as a secret dir ==="

    setup
    mkdir -p "$TEST_SECRET_DIR/secrets"
    cat > "$TEST_COMPOSE_DIR/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    tmpfs:
      - $TEST_SECRET_DIR/secrets:ro
EOF
    # Directory has content, but since the entry has no "# @secret" tag it
    # must not be picked up as a secret dir to validate -- if it were, the
    # leaked file inside it would trigger a validation error.
    # ディレクトリに内容があっても、"# @secret" タグが無いため
    # 検証対象の秘匿ディレクトリとして拾われてはならない
    # （拾われた場合、中の漏洩ファイルが検証エラーになるはず）。
    echo "leaked" > "$TEST_SECRET_DIR/secrets/key.txt"

    if WORKSPACE="$TEST_COMPOSE_DIR" "$SCRIPT" > /dev/null 2>&1; then
        pass "Untagged entry is not treated as a secret dir (leaked file was not flagged)"
    else
        fail "Untagged entry should not be picked up as a secret dir"
    fi

    cleanup
}

# Test 9: tmpfs options other than ":ro" before the tag do not corrupt the
# extracted path
# テスト9: タグの前の ":ro" 以外のtmpfsオプションが抽出パスを破壊しないか
test_non_ro_tmpfs_options_are_stripped_correctly() {
    echo ""
    echo "=== Test: Non-:ro tmpfs options (e.g. rw,noexec,nosuid,size=1g) are stripped correctly ==="

    setup
    mkdir -p "$TEST_SECRET_DIR/secrets"
    cat > "$TEST_COMPOSE_DIR/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    tmpfs:
      - $TEST_SECRET_DIR/secrets:rw,noexec,nosuid,size=1g  # @secret
EOF
    # secrets/ directory is empty, so this should validate successfully --
    # if the path were corrupted (e.g. left with a trailing ":rw,noexec..."
    # suffix), [ -d "$path" ] would be false and the entry would be
    # silently treated as "doesn't exist -- OK" without ever checking the
    # real directory.
    # secrets/ は空なので検証は成功するはず -- もしパスが破損していれば
    # （例: 末尾に ":rw,noexec..." が残っていれば）[ -d "$path" ] は偽になり、
    # 実際のディレクトリを一度も確認しないまま「存在しない=OK」として
    # サイレントに扱われてしまう。
    echo "leaked" > "$TEST_SECRET_DIR/secrets/key.txt"

    if WORKSPACE="$TEST_COMPOSE_DIR" "$SCRIPT" > /dev/null 2>&1; then
        fail "Script should fail: the real (non-corrupted) path has an exposed file"
    else
        pass "Non-:ro tmpfs options handled correctly -- real directory was validated"
    fi

    cleanup
}

# Run all tests
# 全テストを実行
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  validate-secrets.py Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    test_script_executable_and_valid
    test_hidden_secrets_empty
    test_exposed_secret_file
    test_exposed_secret_dir
    test_missing_compose_file
    test_no_secret_config
    test_nonexistent_secret_file
    test_untagged_entry_not_validated
    test_non_ro_tmpfs_options_are_stripped_correctly

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

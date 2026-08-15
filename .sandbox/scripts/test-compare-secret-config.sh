#!/bin/bash
# test-compare-secret-config.sh
# Test script for compare-secret-config.sh
#
# compare-secret-config.sh のテストスクリプト
#
# Usage: ./test-compare-secret-config.sh
# 使用方法: ./test-compare-secret-config.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/compare-secret-config.sh"
TEST_WORKSPACE=""

# compare-secret-config.sh now refuses to run unless $SANDBOX_ENV is set or
# /.dockerenv exists. Default it here so this test suite still runs outside
# the container (plain checkout, CI without a devcontainer) -- the host-OS
# guard test below overrides it inline per-invocation.
# compare-secret-config.sh は $SANDBOX_ENV か /.dockerenv が無いと実行を
# 拒否するようになった。コンテナ外（素のチェックアウトやdevcontainer無しの
# CI）でもこのテストスイートが動くよう既定値を設定する。下のホストOSガード
# テストは呼び出しごとにインラインで上書きする。
export SANDBOX_ENV="${SANDBOX_ENV:-devcontainer}"

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

    # Create temporary workspace
    # 一時的なワークスペースを作成
    TEST_WORKSPACE=$(mktemp -d)

    # Create directory structure
    mkdir -p "$TEST_WORKSPACE/.devcontainer"
    mkdir -p "$TEST_WORKSPACE/cli_sandbox"
    mkdir -p "$TEST_WORKSPACE/.sandbox/scripts"
    mkdir -p "$TEST_WORKSPACE/.sandbox/config"

    # Copy required scripts and config to test workspace
    # 必要なスクリプトと設定をテストワークスペースにコピー
    cp "$SCRIPT_DIR/_startup_common.sh" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$SCRIPT_DIR/_secret-tag.sh" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$SCRIPT_DIR/../config/startup.conf" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true
    cp "$SCRIPT_DIR/../config/sync-ignore" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true
}

# Cleanup test environment
# テスト環境のクリーンアップ
cleanup() {
    info "Cleaning up test environment..."

    # Remove test workspace
    # テスト用ワークスペースを削除
    if [ -n "$TEST_WORKSPACE" ] && [ -d "$TEST_WORKSPACE" ]; then
        rm -rf "$TEST_WORKSPACE"
    fi
}

# Trap to ensure cleanup runs
# クリーンアップが必ず実行されるようトラップ設定
trap cleanup EXIT

# Create matching docker-compose files
# 一致する docker-compose ファイルを作成
create_matching_configs() {
    cat > "$TEST_WORKSPACE/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    build:
      context: ..
      dockerfile: .sandbox/Dockerfile
    volumes:
      - ..:/workspace:cached
      - /dev/null:$TEST_WORKSPACE/demo-apps/securenote-api/.env:ro
    tmpfs:
      - $TEST_WORKSPACE/demo-apps/securenote-api/secrets  # @secret
EOF

    cat > "$TEST_WORKSPACE/cli_sandbox/docker-compose.yml" << EOF
services:
  cli-sandbox:
    build:
      context: .
      dockerfile: .sandbox/Dockerfile
    volumes:
      - .:/workspace
      - /dev/null:$TEST_WORKSPACE/demo-apps/securenote-api/.env:ro
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=1g
      - $TEST_WORKSPACE/demo-apps/securenote-api/secrets  # @secret
EOF
}

# Create mismatched docker-compose files (volumes differ)
# 不一致の docker-compose ファイルを作成（volumes が異なる）
create_mismatched_volumes() {
    cat > "$TEST_WORKSPACE/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    volumes:
      - /dev/null:$TEST_WORKSPACE/demo-apps/securenote-api/.env:ro
      - /dev/null:$TEST_WORKSPACE/another-app/.env:ro
    tmpfs:
      - $TEST_WORKSPACE/demo-apps/securenote-api/secrets  # @secret
EOF

    cat > "$TEST_WORKSPACE/cli_sandbox/docker-compose.yml" << EOF
services:
  cli-sandbox:
    volumes:
      - /dev/null:$TEST_WORKSPACE/demo-apps/securenote-api/.env:ro
    tmpfs:
      - $TEST_WORKSPACE/demo-apps/securenote-api/secrets  # @secret
EOF
}

# Create mismatched docker-compose files (tmpfs differ)
# 不一致の docker-compose ファイルを作成（tmpfs が異なる）
create_mismatched_tmpfs() {
    cat > "$TEST_WORKSPACE/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    volumes:
      - /dev/null:$TEST_WORKSPACE/demo-apps/securenote-api/.env:ro
    tmpfs:
      - $TEST_WORKSPACE/demo-apps/securenote-api/secrets  # @secret
EOF

    cat > "$TEST_WORKSPACE/cli_sandbox/docker-compose.yml" << EOF
services:
  cli-sandbox:
    volumes:
      - /dev/null:$TEST_WORKSPACE/demo-apps/securenote-api/.env:ro
    tmpfs:
      - $TEST_WORKSPACE/demo-apps/securenote-api/secrets  # @secret
      - $TEST_WORKSPACE/another-app/secrets  # @secret
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
    if bash -n "$SCRIPT" 2>/dev/null; then
        pass "Script is executable and has valid syntax"
    else
        fail "Script has syntax errors"
    fi
}

# Test 2: Script runs without error when configs match
# テスト2: 設定が一致する場合、スクリプトがエラーなく実行される
test_matching_configs() {
    echo ""
    echo "=== Test: Matching configs return success ==="

    setup
    create_matching_configs

    if WORKSPACE="$TEST_WORKSPACE" "$SCRIPT" > /dev/null 2>&1; then
        pass "Script returns success when configs match"
    else
        fail "Script should return success when configs match"
    fi

    cleanup
}

# Test 3: Script detects mismatched volumes
# テスト3: volumes の不一致を検出する
test_mismatched_volumes() {
    echo ""
    echo "=== Test: Detect mismatched volumes ==="

    setup
    create_mismatched_volumes

    if WORKSPACE="$TEST_WORKSPACE" "$SCRIPT" > /dev/null 2>&1; then
        fail "Script should return error when volumes don't match"
    else
        pass "Script detects mismatched volumes"
    fi

    cleanup
}

# Test 4: Script detects mismatched tmpfs
# テスト4: tmpfs の不一致を検出する
test_mismatched_tmpfs() {
    echo ""
    echo "=== Test: Detect mismatched tmpfs ==="

    setup
    create_mismatched_tmpfs

    if WORKSPACE="$TEST_WORKSPACE" "$SCRIPT" > /dev/null 2>&1; then
        fail "Script should return error when tmpfs don't match"
    else
        pass "Script detects mismatched tmpfs"
    fi

    cleanup
}

# Test 5: Script fails when devcontainer config missing
# テスト5: devcontainer 設定ファイルがない場合に失敗する
test_missing_devcontainer_config() {
    echo ""
    echo "=== Test: Fail when devcontainer config missing ==="

    setup
    # Only create cli_sandbox config
    # cli_sandbox の設定のみ作成
    cat > "$TEST_WORKSPACE/cli_sandbox/docker-compose.yml" << EOF
services:
  cli-sandbox:
    volumes:
      - /dev/null:$TEST_WORKSPACE/demo-apps/securenote-api/.env:ro
EOF

    if WORKSPACE="$TEST_WORKSPACE" "$SCRIPT" > /dev/null 2>&1; then
        fail "Script should fail when devcontainer config is missing"
    else
        pass "Script fails when devcontainer config is missing"
    fi

    cleanup
}

# Test 6: Script fails when cli_sandbox config missing
# テスト6: cli_sandbox 設定ファイルがない場合に失敗する
test_missing_cli_config() {
    echo ""
    echo "=== Test: Fail when cli_sandbox config missing ==="

    setup
    # Only create devcontainer config
    # devcontainer の設定のみ作成
    cat > "$TEST_WORKSPACE/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    volumes:
      - /dev/null:$TEST_WORKSPACE/demo-apps/securenote-api/.env:ro
EOF

    if WORKSPACE="$TEST_WORKSPACE" "$SCRIPT" > /dev/null 2>&1; then
        fail "Script should fail when cli_sandbox config is missing"
    else
        pass "Script fails when cli_sandbox config is missing"
    fi

    cleanup
}

# Test: host-OS guard blocks execution when neither SANDBOX_ENV nor a
# docker-marker file is present, and allows it when either one is (the
# guard's OR logic). Runs against a copy of the script with the hardcoded
# "/.dockerenv" path swapped for a controllable one via sed, since the real
# path can't be safely faked away inside this container test run itself --
# see docs/ai-guide.md "Host OS Test Scripts" for the copy-and-patch pattern.
# テスト: SANDBOX_ENVもDockerマーカーファイルも無い場合にホストOSガードが
# 実行をブロックし、どちらか一方があれば通す（ガードのOR条件）ことを確認する。
# このコンテナ内のテスト実行中は実際の"/.dockerenv"を安全に消せないため、
# ハードコードされたパスをsedで差し替え可能にしたスクリプトのコピーに対して
# 実行する（docs/ai-guide.mdの「Host OS Test Scripts」節のコピー＆パッチ方式を参照）。
test_host_os_guard() {
    echo ""
    echo "=== Test: host-OS guard blocks/allows based on SANDBOX_ENV / docker-marker ==="

    setup
    create_matching_configs

    local patched_script="$TEST_WORKSPACE/compare-secret-config-patched.sh"
    local fake_marker="$TEST_WORKSPACE/no-such-dockerenv"
    sed "s#/\.dockerenv#$fake_marker#" "$SCRIPT" > "$patched_script"
    chmod +x "$patched_script"

    local output exit_code

    # Neither SANDBOX_ENV nor the docker marker present -> blocked
    output=$(env -u SANDBOX_ENV WORKSPACE="$TEST_WORKSPACE" "$patched_script" 2>&1) && exit_code=0 || exit_code=$?
    if [ "$exit_code" -ne 0 ] && echo "$output" | grep -q "cannot be run on the host OS\|ホストOSでは実行できません"; then
        pass "Blocks with host-OS error when neither SANDBOX_ENV nor docker marker is present"
    else
        fail "Should block with host-OS error, got exit=$exit_code output: $output"
    fi

    # SANDBOX_ENV set, docker marker still absent -> allowed through
    output=$(env -u SANDBOX_ENV WORKSPACE="$TEST_WORKSPACE" SANDBOX_ENV=devcontainer "$patched_script" 2>&1) && exit_code=0 || exit_code=$?
    if ! echo "$output" | grep -q "cannot be run on the host OS\|ホストOSでは実行できません"; then
        pass "Allows execution when SANDBOX_ENV is set, even without the docker marker"
    else
        fail "Should not block when SANDBOX_ENV is set, got: $output"
    fi

    # SANDBOX_ENV unset, docker marker present -> allowed through
    touch "$fake_marker"
    output=$(env -u SANDBOX_ENV WORKSPACE="$TEST_WORKSPACE" "$patched_script" 2>&1) && exit_code=0 || exit_code=$?
    if ! echo "$output" | grep -q "cannot be run on the host OS\|ホストOSでは実行できません"; then
        pass "Allows execution when the docker marker is present, even without SANDBOX_ENV"
    else
        fail "Should not block when docker marker is present, got: $output"
    fi

    cleanup
}

# Run all tests
# 全テストを実行
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  compare-secret-config.sh Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    test_script_executable_and_valid
    test_matching_configs
    test_mismatched_volumes
    test_mismatched_tmpfs
    test_missing_devcontainer_config
    test_missing_cli_config
    test_host_os_guard

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

#!/bin/bash
# test-triage-undeclared-secrets.sh
# Test script for triage-undeclared-secrets.py
#
# triage-undeclared-secrets.py のテストスクリプト
#
# Usage: ./test-triage-undeclared-secrets.sh
# 使用方法: ./test-triage-undeclared-secrets.sh

set -e

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for this test"
    echo "エラー: このテストには jq が必要です"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/triage-undeclared-secrets.py"
TEST_WORKSPACE=""

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

    TEST_WORKSPACE=$(mktemp -d /tmp/.test-triage-XXXXXX)

    mkdir -p "$TEST_WORKSPACE/.devcontainer"
    mkdir -p "$TEST_WORKSPACE/.claude"
    mkdir -p "$TEST_WORKSPACE/.sandbox/scripts"
    mkdir -p "$TEST_WORKSPACE/.sandbox/config"
    mkdir -p "$TEST_WORKSPACE/demo-app"

    cp "$SCRIPT_DIR/_python_common.py" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$SCRIPT_DIR/_secret_tag.py" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$SCRIPT_DIR/check-undeclared-secrets.py" "$TEST_WORKSPACE/.sandbox/scripts/"
    chmod +x "$TEST_WORKSPACE/.sandbox/scripts/check-undeclared-secrets.py"
    cp "$SCRIPT_DIR/../config/startup.conf" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true
    cp "$SCRIPT_DIR/../config/sync-ignore" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true
}

# Cleanup test environment
# テスト環境のクリーンアップ
cleanup() {
    info "Cleaning up test environment..."

    if [ -n "$TEST_WORKSPACE" ] && [ -d "$TEST_WORKSPACE" ]; then
        rm -rf "$TEST_WORKSPACE"
    fi
}

trap cleanup EXIT

# Create docker-compose.yml with a /dev/null anchor line and a tmpfs anchor
# line prefixed with $TEST_WORKSPACE (mirrors how WORKSPACE-prefixed tmpfs
# entries look in the real container, so add_dir_to_compose's anchor search
# has something to match).
# /dev/null アンカー行と、$TEST_WORKSPACE を前置した tmpfs アンカー行を持つ
# docker-compose.yml を作成する（実コンテナでの WORKSPACE 前置 tmpfs
# エントリを模しており、add_dir_to_compose のアンカー探索が機能する）。
create_compose_file() {
    local volume_mounts="$1"
    local tmpfs_mounts="${2:-}"
    cat > "$TEST_WORKSPACE/.devcontainer/docker-compose.yml" << EOF
services:
  ai-sandbox:
    volumes:
      - ..:/workspace:cached
      - /dev/null:/workspace/dummy/.placeholder:ro
$volume_mounts
    tmpfs:
      - $TEST_WORKSPACE/dummy/tmpfs:ro
$tmpfs_mounts
EOF
}

run_script() {
    # $1 = stdin answers (piped), remaining args = script args
    local answers="$1"
    shift
    echo "$answers" | WORKSPACE="$TEST_WORKSPACE" "$SCRIPT" "$@" 2>&1
}

# ========================================
# Test Cases / テストケース
# ========================================

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
    if python3 -m py_compile "$SCRIPT" 2>/dev/null; then
        pass "Script is executable and has valid syntax"
    else
        fail "Script has syntax errors"
    fi
}

# Test 2: No undeclared findings -> reports nothing to do, no backups
# テスト2: 未宣言ファイルなし -> 対処不要と報告、バックアップも生成されない
test_no_undeclared_findings() {
    echo ""
    echo "=== Test: No undeclared findings ==="

    setup
    create_compose_file "" ""

    local output
    output=$(run_script "")

    if echo "$output" | grep -q "No undeclared\|未宣言.*ありません\|対処が必要"; then
        pass "Reports nothing to do when no undeclared findings"
    else
        fail "Should report nothing to do"
        echo "Output: $output"
    fi

    if [ -d "$TEST_WORKSPACE/.sandbox/backups" ] && [ -n "$(ls -A "$TEST_WORKSPACE/.sandbox/backups" 2>/dev/null)" ]; then
        fail "Should not create backups when nothing is triaged"
    else
        pass "No backups created when nothing is triaged"
    fi

    cleanup
}

# Test 3: Hide a file via docker-compose.yml (answer "1")
# テスト3: ファイルを docker-compose.yml で隠蔽（回答 "1"）
test_hide_file_via_compose() {
    echo ""
    echo "=== Test: Hide file via docker-compose.yml ==="

    setup
    touch "$TEST_WORKSPACE/demo-app/.env"
    create_compose_file "" ""

    run_script "1" > /dev/null

    if grep -q "/dev/null:$TEST_WORKSPACE/demo-app/.env:ro" "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"; then
        pass "Hides file via docker-compose.yml on '1'"
    else
        fail "Should add /dev/null mount for the file"
        cat "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"
    fi

    if grep -qxF "demo-app/.env" "$TEST_WORKSPACE/.sandbox/config/sync-ignore" 2>/dev/null; then
        fail "sync-ignore should not be touched when hiding via compose"
    else
        pass "sync-ignore untouched when hiding via compose"
    fi

    if ls "$TEST_WORKSPACE/.sandbox/backups/"*.docker-compose.yml.* > /dev/null 2>&1; then
        pass "Creates a compose backup before editing"
    else
        fail "Should create a compose backup"
    fi

    cleanup
}

# Test 4: Hide a directory via docker-compose.yml tmpfs (answer "1")
# テスト4: ディレクトリを docker-compose.yml の tmpfs で隠蔽（回答 "1"）
test_hide_directory_via_compose() {
    echo ""
    echo "=== Test: Hide directory via docker-compose.yml tmpfs ==="

    setup
    mkdir -p "$TEST_WORKSPACE/secrets"
    touch "$TEST_WORKSPACE/secrets/dummy.txt"
    create_compose_file "" ""

    run_script "1" > /dev/null

    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/_secret-tag.sh"
    local escaped_path re
    escaped_path=$(printf '%s' "$TEST_WORKSPACE/secrets" | sed -E 's/[][\.^$(){}?+*|]/\\&/g')
    re=$(secret_tag_exact_regex "$escaped_path")

    if grep -qE "$re" "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"; then
        pass "Hides directory via tagged tmpfs entry on '1'"
    else
        fail "Should add a '# @secret'-tagged tmpfs entry for the directory"
        cat "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"
    fi

    cleanup
}

# Test 5: User judges it not a secret -> add to sync-ignore (answer "2")
# テスト5: 秘密ではないとユーザーが判断 -> sync-ignore に追加（回答 "2"）
test_ignore_via_sync_ignore() {
    echo ""
    echo "=== Test: User judges it not a secret -> add to sync-ignore ==="

    setup
    touch "$TEST_WORKSPACE/demo-app/.env"
    create_compose_file "" ""

    run_script "2" > /dev/null

    if grep -qxF "demo-app/.env" "$TEST_WORKSPACE/.sandbox/config/sync-ignore"; then
        pass "Appends exact relative path to sync-ignore on '2'"
    else
        fail "Should append demo-app/.env to sync-ignore"
        cat "$TEST_WORKSPACE/.sandbox/config/sync-ignore"
    fi

    if grep -q "/dev/null:$TEST_WORKSPACE/demo-app/.env" "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"; then
        fail "docker-compose.yml should not be touched when adding to sync-ignore"
    else
        pass "docker-compose.yml untouched when adding to sync-ignore"
    fi

    if ls "$TEST_WORKSPACE/.sandbox/backups/"*.sync-ignore.* > /dev/null 2>&1; then
        pass "Creates a sync-ignore backup before editing"
    else
        fail "Should create a sync-ignore backup"
    fi

    cleanup
}

# Test 6: Skip leaves everything unchanged (answer "3")
# テスト6: スキップすると何も変更されない（回答 "3"）
test_skip_leaves_unchanged() {
    echo ""
    echo "=== Test: Skip leaves everything unchanged ==="

    setup
    touch "$TEST_WORKSPACE/demo-app/.env"
    create_compose_file "" ""
    local compose_before sync_ignore_before
    compose_before=$(cat "$TEST_WORKSPACE/.devcontainer/docker-compose.yml")
    sync_ignore_before=$(cat "$TEST_WORKSPACE/.sandbox/config/sync-ignore" 2>/dev/null || echo "")

    run_script "3" > /dev/null

    local compose_after sync_ignore_after
    compose_after=$(cat "$TEST_WORKSPACE/.devcontainer/docker-compose.yml")
    sync_ignore_after=$(cat "$TEST_WORKSPACE/.sandbox/config/sync-ignore" 2>/dev/null || echo "")

    if [ "$compose_before" = "$compose_after" ] && [ "$sync_ignore_before" = "$sync_ignore_after" ]; then
        pass "Skip ('3') leaves compose and sync-ignore unchanged"
    else
        fail "Skip should not modify compose or sync-ignore"
    fi

    if [ -d "$TEST_WORKSPACE/.sandbox/backups" ] && [ -n "$(ls -A "$TEST_WORKSPACE/.sandbox/backups" 2>/dev/null)" ]; then
        fail "Skip should not create any backups"
    else
        pass "Skip creates no backups"
    fi

    cleanup
}

# Test 7: Mixed multi-item run -- one backup per target family, not per item
# テスト7: 複数件混在 -- バックアップはターゲットごとに1回のみ（件数分ではない）
test_mixed_multi_item_single_backup_per_target() {
    echo ""
    echo "=== Test: Mixed multi-item run creates one backup per target ==="

    setup
    touch "$TEST_WORKSPACE/demo-app/.env"
    mkdir -p "$TEST_WORKSPACE/demo-app/nested"
    touch "$TEST_WORKSPACE/demo-app/nested/.env.local"
    create_compose_file "" ""

    # Two undeclared files sorted alphabetically: demo-app/.env, demo-app/nested/.env.local
    # 1 = hide first, 2 = ignore second
    run_script "1
2" > /dev/null

    local compose_backup_count sync_ignore_backup_count
    compose_backup_count=$(ls "$TEST_WORKSPACE/.sandbox/backups/"*.docker-compose.yml.* 2>/dev/null | wc -l)
    sync_ignore_backup_count=$(ls "$TEST_WORKSPACE/.sandbox/backups/"*.sync-ignore.* 2>/dev/null | wc -l)

    if [ "$compose_backup_count" -eq 1 ]; then
        pass "Exactly one compose backup for the whole run"
    else
        fail "Expected exactly one compose backup, got $compose_backup_count"
    fi

    if [ "$sync_ignore_backup_count" -eq 1 ]; then
        pass "Exactly one sync-ignore backup for the whole run"
    else
        fail "Expected exactly one sync-ignore backup, got $sync_ignore_backup_count"
    fi

    cleanup
}

# Test 8: Already-declared and already-ignored files are not prompted
# テスト8: 既に宣言済み/無視済みのファイルはプロンプトされない
test_already_declared_or_ignored_not_prompted() {
    echo ""
    echo "=== Test: Already declared/ignored files are not prompted ==="

    setup
    touch "$TEST_WORKSPACE/demo-app/.env"
    touch "$TEST_WORKSPACE/demo-app/.env.example"
    mkdir -p "$TEST_WORKSPACE/demo-app/nested"
    touch "$TEST_WORKSPACE/demo-app/nested/.env.local"
    create_compose_file "      - /dev/null:$TEST_WORKSPACE/demo-app/.env:ro" ""

    local output
    output=$(run_script "3
3")

    if echo "$output" | grep -q "demo-app/.env " || echo "$output" | grep -qE "demo-app/\.env$"; then
        fail "Already-declared demo-app/.env should not be prompted"
    else
        pass "Already-declared file is not prompted"
    fi

    if echo "$output" | grep -q "demo-app/.env.example"; then
        fail "sync-ignore-matched demo-app/.env.example should not be prompted"
    else
        pass "sync-ignore-matched file is not prompted"
    fi

    if echo "$output" | grep -q "demo-app/nested/.env.local"; then
        pass "Genuinely undeclared file is still prompted"
    else
        fail "Genuinely undeclared file should be prompted"
        echo "Output: $output"
    fi

    cleanup
}

# Test 9: --dry-run shows a preview and makes no changes, even with stdin closed
# テスト9: --dry-run はプレビューを表示するだけで変更しない（stdinを閉じても動作）
test_dry_run_no_changes() {
    echo ""
    echo "=== Test: --dry-run makes no changes ==="

    setup
    touch "$TEST_WORKSPACE/demo-app/.env"
    create_compose_file "" ""
    local compose_before sync_ignore_before
    compose_before=$(cat "$TEST_WORKSPACE/.devcontainer/docker-compose.yml")
    sync_ignore_before=$(cat "$TEST_WORKSPACE/.sandbox/config/sync-ignore" 2>/dev/null || echo "")

    local output
    output=$(WORKSPACE="$TEST_WORKSPACE" "$SCRIPT" --dry-run < /dev/null 2>&1)

    local compose_after sync_ignore_after
    compose_after=$(cat "$TEST_WORKSPACE/.devcontainer/docker-compose.yml")
    sync_ignore_after=$(cat "$TEST_WORKSPACE/.sandbox/config/sync-ignore" 2>/dev/null || echo "")

    if [ "$compose_before" = "$compose_after" ] && [ "$sync_ignore_before" = "$sync_ignore_after" ]; then
        pass "--dry-run makes no changes"
    else
        fail "--dry-run should not modify any file"
    fi

    if echo "$output" | grep -q "demo-app/.env"; then
        pass "--dry-run shows the finding in its preview"
    else
        fail "--dry-run should mention the finding"
        echo "Output: $output"
    fi

    cleanup
}

# Test 10: Idempotency -- ignoring the same file across two separate runs
# only ever appends one line, and it stops being surfaced afterward
# テスト10: 冪等性 -- 同じファイルを2回別々の実行で無視しても行は1つのみ増え、
# 以降は検出結果に現れなくなる
test_idempotent_sync_ignore_across_runs() {
    echo ""
    echo "=== Test: Idempotent sync-ignore across separate runs ==="

    setup
    touch "$TEST_WORKSPACE/demo-app/.env"
    create_compose_file "" ""

    run_script "2" > /dev/null
    local second_run_output
    second_run_output=$(run_script "2")

    local match_count
    match_count=$(grep -cxF "demo-app/.env" "$TEST_WORKSPACE/.sandbox/config/sync-ignore")

    if [ "$match_count" -eq 1 ]; then
        pass "sync-ignore contains exactly one line for the file after two runs"
    else
        fail "Expected exactly one line, got $match_count"
    fi

    if echo "$second_run_output" | grep -q "No undeclared\|未宣言.*ありません\|対処が必要"; then
        pass "Second run no longer surfaces the now-ignored file"
    else
        fail "Second run should report nothing to do"
        echo "Output: $second_run_output"
    fi

    cleanup
}

# Test 11: Directory already tagged in one compose file, undeclared in the
# other -- hiding must not add a duplicate tag to the already-tagged file
# (regression test for the dirname-vs-exact-path gap in is_file_in_compose)
# テスト11: 一方のcomposeファイルでは既にタグ付き済みだがもう一方では未宣言の
# ディレクトリ -- 隠蔽操作で既にタグ付き済みのファイルへ重複タグを追加しては
# ならない（is_file_in_compose のdirname起点によるすり抜けに対する回帰テスト）
test_no_duplicate_tag_when_already_hidden_in_other_compose() {
    echo ""
    echo "=== Test: No duplicate tag when directory already hidden in the other compose file ==="

    setup
    mkdir -p "$TEST_WORKSPACE/secrets" "$TEST_WORKSPACE/cli_sandbox"
    touch "$TEST_WORKSPACE/secrets/dummy.txt"
    create_compose_file "" ""

    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/_secret-tag.sh"

    # Pre-tag the directory in the CLI Sandbox compose only -- the
    # DevContainer compose (created above) lacks it, so
    # check-undeclared-secrets.py (which only scans the DevContainer compose
    # in this test's default SANDBOX_ENV) reports it as undeclared.
    cat > "$TEST_WORKSPACE/cli_sandbox/docker-compose.yml" << EOF
services:
  ai-sandbox:
    volumes:
      - ..:/workspace:cached
    tmpfs:
      - $TEST_WORKSPACE/secrets  # @secret
EOF

    run_script "1" > /dev/null

    local escaped_path re
    escaped_path=$(printf '%s' "$TEST_WORKSPACE/secrets" | sed -E 's/[][\.^$(){}?+*|]/\\&/g')
    re=$(secret_tag_exact_regex "$escaped_path")

    local tag_count_cli
    tag_count_cli=$(grep -cE "$re" "$TEST_WORKSPACE/cli_sandbox/docker-compose.yml")
    if [ "$tag_count_cli" -eq 1 ]; then
        pass "CLI Sandbox compose still has exactly one tag (no duplicate added)"
    else
        fail "Expected exactly one tag in CLI Sandbox compose, got $tag_count_cli"
        cat "$TEST_WORKSPACE/cli_sandbox/docker-compose.yml"
    fi

    if grep -qE "$re" "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"; then
        pass "DevContainer compose gets the tag it was missing"
    else
        fail "DevContainer compose should get a tagged entry since it lacked one"
        cat "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"
    fi

    cleanup
}

# Run all tests
# 全テストを実行
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  triage-undeclared-secrets.py Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    test_script_executable_and_valid
    test_no_undeclared_findings
    test_hide_file_via_compose
    test_hide_directory_via_compose
    test_ignore_via_sync_ignore
    test_skip_leaves_unchanged
    test_mixed_multi_item_single_backup_per_target
    test_already_declared_or_ignored_not_prompted
    test_dry_run_no_changes
    test_idempotent_sync_ignore_across_runs
    test_no_duplicate_tag_when_already_hidden_in_other_compose

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

#!/bin/bash
# test-check-undeclared-secrets-diff.sh
# Test script for check-undeclared-secrets-diff.py
#
# check-undeclared-secrets-diff.py のテストスクリプト
#
# Usage: ./test-check-undeclared-secrets-diff.sh
# 使用方法: ./test-check-undeclared-secrets-diff.sh

set -e

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for this test"
    echo "エラー: このテストには jq が必要です"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-undeclared-secrets-diff.py"
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

STATE_FILE_REL=".sandbox/.state/check-undeclared-secrets.json"

# Setup test environment
# テスト環境のセットアップ
setup() {
    info "Setting up test environment..."

    TEST_WORKSPACE=$(mktemp -d /tmp/.test-undeclared-secrets-diff-XXXXXX)

    mkdir -p "$TEST_WORKSPACE/.devcontainer"
    mkdir -p "$TEST_WORKSPACE/.claude"
    mkdir -p "$TEST_WORKSPACE/.sandbox/scripts"
    mkdir -p "$TEST_WORKSPACE/.sandbox/config"

    cp "$SCRIPT_DIR/_startup_common.sh" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$SCRIPT_DIR/_secret-tag.sh" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$SCRIPT_DIR/check-undeclared-secrets.sh" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$SCRIPT_DIR/../config/startup.conf" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true
    cp "$SCRIPT_DIR/../config/sync-ignore" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true

    cat > "$TEST_WORKSPACE/.devcontainer/docker-compose.yml" << 'EOF'
services:
  ai-sandbox:
    volumes:
      - ..:/workspace:cached
EOF

    export WORKSPACE="$TEST_WORKSPACE"
}

# Cleanup test environment
# テスト環境のクリーンアップ
cleanup() {
    info "Cleaning up test environment..."

    if [ -n "$TEST_WORKSPACE" ] && [ -d "$TEST_WORKSPACE" ]; then
        rm -rf "$TEST_WORKSPACE"
    fi

    unset WORKSPACE
}

trap cleanup EXIT

run_script() {
    WORKSPACE="$TEST_WORKSPACE" "$SCRIPT" 2>&1
}

state_file_path() {
    echo "$TEST_WORKSPACE/$STATE_FILE_REL"
}

PENDING_FILE_REL=".sandbox/.state/check-undeclared-secrets.pending.json"

pending_file_path() {
    echo "$TEST_WORKSPACE/$PENDING_FILE_REL"
}

# Stand-in for setup-output-reminder.sh's promotion step (pending ->
# confirmed). Never calls the real hook -- this file only verifies
# check-undeclared-secrets-diff.py's own contract (always diff against the
# confirmed file); the hook's promotion trigger and merge behavior are
# verified separately in test-setup-output-reminder.sh.
# setup-output-reminder.shの昇格処理(pending -> confirmed)の代役。実フックは
# 呼ばない -- ここはcheck-undeclared-secrets-diff.py自体の契約(常に確定済み
# ファイルと比較する)を検証する場であり、フック側の昇格トリガーとマージ
# 挙動はtest-setup-output-reminder.shで別途検証する。
confirm_pending() {
    [ -f "$(pending_file_path)" ] && mv "$(pending_file_path)" "$(state_file_path)"
    return 0
}

# ========================================
# Test Cases / テストケース
# ========================================

# Test 1: First run (no prior state file) -> reports the currently-undeclared
# files (previous set treated as empty) and writes a baseline state file
# テスト1: 初回実行（状態ファイルなし） -> 前回集合を空として扱い、その時点の
# 未宣言ファイルを報告したうえで、ベースラインとして状態ファイルを作成する
test_first_run_reports_existing_and_writes_baseline() {
    info "Test 1: First run reports existing undeclared files and writes a baseline state file"
    info "テスト1: 初回実行は既存の未宣言ファイルを報告し、ベースライン状態ファイルを書き込む"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"

    output=$(run_script)

    if echo "$output" | grep -q "api/\.env"; then
        pass "First run flagged the pre-existing undeclared file"
    else
        fail "First run should flag pre-existing undeclared files, not stay silent"
        echo "Output: $output"
    fi

    if [ -f "$(pending_file_path)" ] && jq -e '.undeclared | index("api/.env")' "$(pending_file_path)" > /dev/null; then
        pass "Pending outbox file recorded api/.env"
    else
        fail "Pending outbox file should record api/.env"
        cat "$(pending_file_path)" 2>&1 || true
    fi

    if [ ! -f "$(state_file_path)" ]; then
        pass "Confirmed baseline is NOT written until delivery is confirmed"
    else
        fail "Confirmed baseline must stay unwritten until delivery is confirmed, or an undelivered finding could vanish forever"
        cat "$(state_file_path)" 2>&1 || true
    fi

    cleanup
}

# Test 2: Second run with the exact same undeclared set -> silent
# テスト2: 前回と全く同じ未宣言セット -> 無出力
test_unchanged_set_is_silent() {
    info "Test 2: Unchanged undeclared set is silent"
    info "テスト2: 未宣言セットが変化なしなら無出力"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"

    run_script > /dev/null
    confirm_pending

    output=$(run_script)

    if [ -z "$output" ]; then
        pass "Unchanged set produced no output on second run"
    else
        fail "Unchanged set should be silent"
        echo "Output: $output"
    fi

    cleanup
}

# Test 3: A new undeclared file appears alongside an already-known one -> notifies about the new one only
# テスト3: 既知のファイルに加えて新規未宣言ファイルが出現 -> 新規分のみ通知
test_new_file_added_notifies() {
    info "Test 3: A newly-added undeclared file triggers a notification"
    info "テスト3: 新規に追加された未宣言ファイルは通知される"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"
    run_script > /dev/null
    confirm_pending

    touch "$TEST_WORKSPACE/api/.env.local"
    output=$(run_script)

    if echo "$output" | grep -q "api/\.env\.local"; then
        pass "New undeclared file correctly flagged"
    else
        fail "New undeclared file should be flagged"
        echo "Output: $output"
    fi

    if echo "$output" | grep -q "api/\.env$"; then
        fail "Already-known file should NOT be re-flagged"
        echo "Output: $output"
    else
        pass "Already-known file correctly not re-flagged"
    fi

    cleanup
}

# Test 4: An undeclared file disappears (e.g. got declared/removed), none added -> silent
# テスト4: 未宣言ファイルが1件消えて新規追加なし -> 無出力
test_file_removed_is_silent() {
    info "Test 4: A removed undeclared file with no new additions is silent"
    info "テスト4: 未宣言ファイルの消失のみ（新規追加なし）は無出力"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"
    touch "$TEST_WORKSPACE/api/.env.local"
    run_script > /dev/null
    confirm_pending

    rm "$TEST_WORKSPACE/api/.env.local"
    output=$(run_script)

    if [ -z "$output" ]; then
        pass "Removed-only change is silent"
    else
        fail "Removed-only change should be silent"
        echo "Output: $output"
    fi

    cleanup
}

# Test 5: Same total count, but the file is swapped for a different name -> still notifies
# (this is the key case: count-based comparison would miss it, set-based comparison catches it)
# テスト5: 合計件数は同じだが、別名ファイルに入れ替わっている -> それでも通知される
# （件数だけの比較では見逃すが、集合ベースの比較では検出できる、という重要なケース）
test_file_swap_same_count_still_notifies() {
    info "Test 5: File swapped for a different name (same total count) still notifies"
    info "テスト5: 件数は同じでもファイルが入れ替わっていれば通知される"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"
    run_script > /dev/null
    confirm_pending

    rm "$TEST_WORKSPACE/api/.env"
    touch "$TEST_WORKSPACE/api/.env.production"
    output=$(run_script)

    if echo "$output" | grep -q "api/\.env\.production"; then
        pass "Swapped-in new file correctly flagged despite unchanged count"
    else
        fail "Swapped-in new file should be flagged even though count didn't change"
        echo "Output: $output"
    fi

    cleanup
}

# Test 7: A file covered only by .claude/settings.json (not docker-compose.yml)
# is reported as newly-undeclared, annotated with a settings.json-covered note
# テスト7: .claude/settings.jsonのみでカバーされている（docker-compose.ymlには
# 未宣言の）ファイルは、新規の未宣言として通知され、settings.json注記が付く
test_claude_settings_only_file_notifies_with_note() {
    info "Test 7: File covered only by .claude/settings.json notifies with a settings.json-covered note"
    info "テスト7: .claude/settings.jsonのみでカバーされたファイルはsettings.json注記付きで通知される"

    setup

    mkdir -p "$TEST_WORKSPACE/ios-app"
    touch "$TEST_WORKSPACE/ios-app/foo.mobileprovision"
    cat > "$TEST_WORKSPACE/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "deny": ["Read(**/foo.mobileprovision)"]
  }
}
EOF

    output=$(run_script)

    if echo "$output" | grep -q "ios-app/foo\.mobileprovision.*\(already covered by .claude/settings.json\|\.claude/settings\.json では既にカバー済み\)"; then
        pass "settings.json-only file notified with the covered note"
    else
        fail "settings.json-only file should be notified with the covered note"
        echo "Output: $output"
    fi

    cleanup
}

# Test 6: Script always exits 0
# テスト6: 常にexit 0
test_always_exits_zero() {
    info "Test 6: Script always exits 0"
    info "テスト6: 常にexit 0"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"

    set +e
    run_script > /dev/null 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ]; then
        pass "Exit code is 0"
    else
        fail "Exit code should be 0, got $exit_code"
    fi

    cleanup
}

# Test 8: An unconfirmed finding is re-reported on every subsequent run
# until something actually confirms it -- the baseline must never advance
# on detection alone, only once delivery is confirmed
# テスト8: 未確定の検知は、何かが実際に確定させるまで毎回再報告される
# -- baselineは検知だけでは絶対に進めず、配送が確定して初めて進む
test_unconfirmed_finding_resent_until_confirmed() {
    info "Test 8: Unconfirmed finding is resent on every subsequent run"
    info "テスト8: 未確定の検知は毎回再送される"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"

    output1=$(run_script)
    output2=$(run_script)

    if echo "$output1" | grep -q "api/\.env" && echo "$output2" | grep -q "api/\.env"; then
        pass "Unconfirmed finding was reported again on the second run (no confirm_pending in between)"
    else
        fail "Unconfirmed finding should keep being reported until confirmed"
        echo "Output1: $output1"
        echo "Output2: $output2"
    fi

    cleanup
}

# Test 9: A pending finding that gets remediated before ever being
# confirmed is cleared from the pending file on the next run
# テスト9: 一度も確定しないまま是正されたpending検知は、次回実行で
# pendingファイルから消える
test_pending_cleared_when_new_count_zero() {
    info "Test 9: Pending file is cleared once the finding is remediated"
    info "テスト9: 是正されればpendingファイルはクリアされる"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"
    run_script > /dev/null

    rm "$TEST_WORKSPACE/api/.env"
    run_script > /dev/null

    if [ ! -f "$(pending_file_path)" ]; then
        pass "Pending file cleared after the finding was remediated"
    else
        fail "Pending file should be cleared once nothing is outstanding"
        cat "$(pending_file_path)" 2>&1 || true
    fi

    cleanup
}

# Test 10: A still-unconfirmed finding, plus a newly-added one, both show
# up in the next run's output and in the pending file
# テスト10: 未確定の検知に加えて新たな検知が増えても、両方が次回の
# 出力・pendingファイルに含まれる
test_pending_overwritten_with_latest_full_scan_each_new_detection() {
    info "Test 10: Pending file mirrors the latest full scan when new findings keep appearing"
    info "テスト10: 新規検知が続く間、pendingファイルは常に最新のフルスキャンを反映する"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"
    run_script > /dev/null

    touch "$TEST_WORKSPACE/api/.env.local"
    output=$(run_script)

    if echo "$output" | grep -q "api/\.env\.local" && echo "$output" | grep -q "api/\.env$"; then
        pass "Both the still-unconfirmed and newly-added file are reported"
    else
        fail "Both files should be reported while nothing has been confirmed"
        echo "Output: $output"
    fi

    if jq -e '.undeclared | index("api/.env")' "$(pending_file_path)" > /dev/null 2>&1 && \
       jq -e '.undeclared | index("api/.env.local")' "$(pending_file_path)" > /dev/null 2>&1; then
        pass "Pending file contains both entries"
    else
        fail "Pending file should contain both entries"
        cat "$(pending_file_path)" 2>&1 || true
    fi

    cleanup
}

# ========================================
# Run all tests / 全テストの実行
# ========================================

echo ""
echo "=========================================="
echo "Testing check-undeclared-secrets-diff.py"
echo "check-undeclared-secrets-diff.py のテスト"
echo "=========================================="
echo ""

test_first_run_reports_existing_and_writes_baseline
test_unchanged_set_is_silent
test_new_file_added_notifies
test_file_removed_is_silent
test_file_swap_same_count_still_notifies
test_claude_settings_only_file_notifies_with_note
test_always_exits_zero
test_unconfirmed_finding_resent_until_confirmed
test_pending_cleared_when_new_count_zero
test_pending_overwritten_with_latest_full_scan_each_new_detection

echo ""
echo "=========================================="
echo "Test Results / テスト結果"
echo "=========================================="
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! / 全テスト成功！${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. / 一部のテストが失敗しました。${NC}"
    exit 1
fi

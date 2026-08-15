#!/bin/bash
# test-setup-output-reminder.sh
# Test script for hooks/setup-output-reminder.sh
#
# hooks/setup-output-reminder.sh のテストスクリプト
#
# Usage: ./test-setup-output-reminder.sh
# 使用方法: ./test-setup-output-reminder.sh

set -e

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for this test"
    echo "エラー: このテストには jq が必要です"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/setup-output-reminder.sh"
TEST_WORKSPACE=""
ALIVE_PID=""
OUT_BASE_REL=".sandbox/.state/setup-output/sandbox-mcp-pids"

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

# Setup / cleanup
# セットアップ・クリーンアップ
setup() {
    TEST_WORKSPACE=$(mktemp -d /tmp/.test-setup-output-reminder-XXXXXX)
    mkdir -p "$TEST_WORKSPACE/$OUT_BASE_REL"
    export WORKSPACE_ROOT="$TEST_WORKSPACE"
}

stop_alive_pid() {
    if [ -n "$ALIVE_PID" ]; then
        kill "$ALIVE_PID" 2>/dev/null || true
        wait "$ALIVE_PID" 2>/dev/null || true
        ALIVE_PID=""
    fi
}

cleanup() {
    stop_alive_pid
    if [ -n "$TEST_WORKSPACE" ] && [ -d "$TEST_WORKSPACE" ]; then
        rm -rf "$TEST_WORKSPACE"
    fi
    unset WORKSPACE_ROOT
}

trap cleanup EXIT

# Fixture helpers
# フィクスチャ用ヘルパー
start_alive_pid() {
    sleep 100 &
    ALIVE_PID=$!
}

make_dead_pid() {
    ( : ) &
    local p=$!
    wait "$p" 2>/dev/null || true
    echo "$p"
}

# Creates ".sandbox/sandbox-mcp-setup/<base>.sh" with the given header tags
# (one per argument, without the leading "# "), matching the comment-tag
# convention has_persistent_tag()/read_header_tag_value() parse.
# ".sandbox/sandbox-mcp-setup/<base>.sh" を指定タグ(引数ごとに1つ、先頭の
# "# "は除く)で作成する。has_persistent_tag()/read_header_tag_value()が
# 解釈するコメントタグ規約に合わせている。
make_setup_script_header() {
    local base="$1"
    shift
    local dir="$TEST_WORKSPACE/.sandbox/sandbox-mcp-setup"
    mkdir -p "$dir"
    {
        echo "#!/bin/bash"
        for tag in "$@"; do
            echo "# $tag"
        done
    } > "$dir/${base}.sh"
}

# ========================================
# Test Cases / テストケース
# ========================================

# Test 1: No setup-output directory at all -> {}
# テスト1: setup-outputディレクトリ自体が存在しない -> {}
test_no_dir() {
    info "Test 1: No setup-output directory -> {}"
    info "テスト1: setup-outputディレクトリが存在しない場合 -> {}"

    setup
    rm -rf "${TEST_WORKSPACE:?}/$OUT_BASE_REL"

    local result
    result=$("$HOOK")

    if [ "$result" = "{}" ]; then
        pass "Empty {} returned when dir missing"
    else
        fail "Expected {}, got: $result"
    fi

    cleanup
}

# Test 2: Directory exists but has no subdirectories -> {}
# テスト2: ディレクトリはあるが中身が空 -> {}
test_empty_dir() {
    info "Test 2: Empty setup-output directory -> {}"
    info "テスト2: setup-outputディレクトリが空の場合 -> {}"

    setup

    local result
    result=$("$HOOK")

    if [ "$result" = "{}" ]; then
        pass "Empty {} returned when dir has no subdirs"
    else
        fail "Expected {}, got: $result"
    fi

    cleanup
}

# Test 3: Alive PID dir with two txt files -> content inlined into additionalContext
# テスト3: 生存PIDディレクトリのtxtファイル内容がadditionalContextにそのまま含まれる
test_alive_pid_content_inlined() {
    info "Test 3: Alive PID dir content is inlined into additionalContext"
    info "テスト3: 生存PIDディレクトリの内容がadditionalContextに埋め込まれる"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    echo "hello from file A" > "$dir/05-a.txt"
    echo "hello from file B" > "$dir/40-b.txt"

    local result
    result=$("$HOOK")

    if echo "$result" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' > /dev/null 2>&1; then
        pass "hookEventName is UserPromptSubmit"
    else
        fail "hookEventName missing/incorrect: $result"
    fi

    local ctx
    ctx=$(echo "$result" | jq -r '.hookSpecificOutput.additionalContext')
    if [[ "$ctx" == *"hello from file A"* ]] && [[ "$ctx" == *"hello from file B"* ]]; then
        pass "Both file contents inlined into additionalContext"
    else
        fail "File contents not found in additionalContext: $ctx"
    fi

    stop_alive_pid
    cleanup
}

# Test 4: Only a dead PID directory is present -> {}
# テスト4: 死亡PIDディレクトリのみ存在する場合 -> {}
test_dead_pid_only() {
    info "Test 4: Only dead PID directory present -> {}"
    info "テスト4: 死亡PIDディレクトリのみの場合 -> {}"

    setup
    local dead_pid
    dead_pid=$(make_dead_pid)
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$dead_pid"
    mkdir -p "$dir"
    echo "should not appear" > "$dir/05-a.txt"

    local result
    result=$("$HOOK")

    if [ "$result" = "{}" ]; then
        pass "Dead PID directory ignored"
    else
        fail "Expected {}, got: $result"
    fi

    cleanup
}

# Test 5: Two alive PID dirs -> the one with newest mtime is chosen
# テスト5: 生存PIDディレクトリが2つある場合、mtimeが新しい方が選ばれる
test_newest_mtime_chosen() {
    info "Test 5: Newest mtime among alive PID dirs is chosen"
    info "テスト5: 生存PIDディレクトリのうちmtimeが新しい方が選ばれる"

    setup

    sleep 100 &
    local pid_old=$!
    local dir_old="$TEST_WORKSPACE/$OUT_BASE_REL/$pid_old"
    mkdir -p "$dir_old"
    echo "OLD CONTENT" > "$dir_old/05-a.txt"

    sleep 1

    sleep 100 &
    local pid_new=$!
    local dir_new="$TEST_WORKSPACE/$OUT_BASE_REL/$pid_new"
    mkdir -p "$dir_new"
    echo "NEW CONTENT" > "$dir_new/05-a.txt"

    local result ctx
    result=$("$HOOK")
    ctx=$(echo "$result" | jq -r '.hookSpecificOutput.additionalContext')

    kill "$pid_old" "$pid_new" 2>/dev/null || true
    wait "$pid_old" "$pid_new" 2>/dev/null || true

    if [[ "$ctx" == *"NEW CONTENT"* ]] && [[ "$ctx" != *"OLD CONTENT"* ]]; then
        pass "Newest directory content selected"
    else
        fail "Expected only NEW CONTENT, got: $ctx"
    fi

    cleanup
}

# Test 6: Second invocation for the same PID dir returns {} (idempotent marker)
# テスト6: 同一PIDディレクトリへの2回目の呼び出しは{}(冪等マーカー)
test_idempotent_marker() {
    info "Test 6: Second invocation for same PID dir returns {}"
    info "テスト6: 同一ディレクトリへの2回目の呼び出しは{}"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    echo "only once" > "$dir/05-a.txt"

    local first second
    first=$("$HOOK")
    second=$("$HOOK")

    if [[ "$first" == *"only once"* ]] && [ "$second" = "{}" ]; then
        pass "Content emitted once, then suppressed on second call"
    else
        fail "First: $first / Second: $second"
    fi

    stop_alive_pid
    cleanup
}

# Test 7: Special characters (quotes/newlines/backslashes) still produce valid JSON
# テスト7: 引用符・改行・バックスラッシュを含んでも正しいJSONになる
test_json_escaping() {
    info "Test 7: Special characters in file content produce valid JSON"
    info "テスト7: ファイル内容に特殊文字を含んでも正しいJSONになる"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    printf 'line with "quotes" and \\ backslash\nsecond line\n' > "$dir/05-a.txt"

    local result
    result=$("$HOOK")

    if echo "$result" | jq empty > /dev/null 2>&1; then
        pass "Output is valid JSON despite special characters"
    else
        fail "Output is not valid JSON: $result"
    fi

    stop_alive_pid
    cleanup
}

# Test 8: jq unavailable -> {} (fail-safe)
# テスト8: jqが無い場合 -> {}(フェイルセーフ)
test_no_jq() {
    info "Test 8: jq unavailable -> {}"
    info "テスト8: jqが無い場合 -> {}"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    echo "content" > "$dir/05-a.txt"

    # Remove only the directories that provide a jq binary from PATH,
    # keeping every other directory intact.
    # jqバイナリを提供するディレクトリだけをPATHから除外し、
    # それ以外のディレクトリはそのまま残す。
    local filtered_path="" d
    IFS=':' read -ra path_dirs <<< "$PATH"
    for d in "${path_dirs[@]}"; do
        if [ ! -x "$d/jq" ]; then
            filtered_path="$filtered_path:$d"
        fi
    done
    filtered_path="${filtered_path#:}"

    local result
    result=$(PATH="$filtered_path" "$HOOK")

    if [ "$result" = "{}" ]; then
        pass "Empty {} returned when jq is unavailable"
    else
        fail "Expected {}, got: $result"
    fi

    stop_alive_pid
    cleanup
}

# Test 9: A persistent-tagged file repeats every turn with an incrementing
# counter, and is excluded from the one-shot MANDATORY dump
# テスト9: persistentタグ付きファイルはカウンタ付きで毎回再掲され、
# 一括MANDATORYダンプの対象からは除外される
test_persistent_tag_repeats_each_turn() {
    info "Test 9: Persistent-tagged notice repeats each turn with an incrementing counter"
    info "テスト9: persistentタグ付き通知は毎回カウンタ付きで再掲される"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    make_setup_script_header "25-example" "@notify: persistent"
    echo "persistent body text" > "$dir/25-example.txt"

    local first second ctx1 ctx2
    first=$("$HOOK")
    second=$("$HOOK")
    ctx1=$(echo "$first" | jq -r '.hookSpecificOutput.additionalContext')
    ctx2=$(echo "$second" | jq -r '.hookSpecificOutput.additionalContext')

    if [[ "$ctx1" == *"persistent body text"* ]] && [[ "$ctx1" == *"(1/5)"* ]] && \
       [[ "$ctx2" == *"persistent body text"* ]] && [[ "$ctx2" == *"(2/5)"* ]]; then
        pass "Persistent notice repeats each turn with an incrementing counter"
    else
        fail "Expected incrementing persistent notice. First: $ctx1 / Second: $ctx2"
    fi

    if [[ "$ctx1" != *"MANDATORY"* ]]; then
        pass "Persistent-tagged file is excluded from the one-shot MANDATORY dump"
    else
        fail "Persistent-tagged file should not appear in the MANDATORY dump: $ctx1"
    fi

    stop_alive_pid
    cleanup
}

# Test 10: Touching "<base>.resolved" suppresses further repeats
# テスト10: "<base>.resolved" をtouchすると再掲が止まる
test_persistent_tag_resolved_suppresses() {
    info "Test 10: .resolved marker suppresses further repeats"
    info "テスト10: .resolvedマーカーで再掲が止まる"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    make_setup_script_header "25-example" "@notify: persistent"
    echo "persistent body text" > "$dir/25-example.txt"

    "$HOOK" > /dev/null
    touch "$dir/25-example.resolved"
    local result ctx
    result=$("$HOOK")
    ctx=$(echo "$result" | jq -r '.hookSpecificOutput.additionalContext // empty')

    if [[ "$ctx" != *"persistent body text"* ]]; then
        pass "Resolved marker suppresses further repeats"
    else
        fail "Should not repeat after .resolved is touched: $ctx"
    fi

    stop_alive_pid
    cleanup
}

# Test 11: Repeats stop once PERSISTENT_NOTIFY_CAP is reached
# テスト11: PERSISTENT_NOTIFY_CAPに達すると再掲が止まる
test_persistent_tag_cap_enforced() {
    info "Test 11: Repeat cap stops further notices"
    info "テスト11: 上限回数に達すると再掲が止まる"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    make_setup_script_header "25-example" "@notify: persistent"
    echo "persistent body text" > "$dir/25-example.txt"

    PERSISTENT_NOTIFY_CAP=2 "$HOOK" > /dev/null
    PERSISTENT_NOTIFY_CAP=2 "$HOOK" > /dev/null
    local result ctx
    result=$(PERSISTENT_NOTIFY_CAP=2 "$HOOK")
    ctx=$(echo "$result" | jq -r '.hookSpecificOutput.additionalContext // empty')

    if [[ "$ctx" != *"persistent body text"* ]]; then
        pass "Cap enforced: notice no longer repeats after PERSISTENT_NOTIFY_CAP is reached"
    else
        fail "Should stop repeating once cap is reached: $ctx"
    fi

    stop_alive_pid
    cleanup
}

# Test 12: A mandatory (untagged) file and a persistent-tagged file
# coexisting in the same PID dir are handled separately
# テスト12: mandatory(タグなし)ファイルとpersistentタグ付きファイルが
# 同一PIDディレクトリに混在する場合、別々に扱われる
test_persistent_tag_separated_from_mandatory_dump() {
    info "Test 12: Mandatory and persistent files in the same PID dir are handled separately"
    info "テスト12: 同一PIDディレクトリ内のmandatoryとpersistentは別々に扱われる"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    echo "mandatory body text" > "$dir/05-mandatory.txt"
    make_setup_script_header "25-persistent" "@notify: persistent"
    echo "persistent body text" > "$dir/25-persistent.txt"

    local first second ctx1 ctx2
    first=$("$HOOK")
    second=$("$HOOK")
    ctx1=$(echo "$first" | jq -r '.hookSpecificOutput.additionalContext')
    ctx2=$(echo "$second" | jq -r '.hookSpecificOutput.additionalContext // empty')

    if [[ "$ctx1" == *"MANDATORY"* ]] && [[ "$ctx1" == *"mandatory body text"* ]] && [[ "$ctx1" == *"persistent body text"* ]]; then
        pass "First call includes both the MANDATORY dump and the PERSISTENT notice"
    else
        fail "First call should include both blocks: $ctx1"
    fi

    if [[ "$ctx2" != *"MANDATORY"* ]] && [[ "$ctx2" != *"mandatory body text"* ]] && [[ "$ctx2" == *"persistent body text"* ]]; then
        pass "Second call only repeats the PERSISTENT notice; mandatory dump is suppressed"
    else
        fail "Second call should only repeat the persistent notice: $ctx2"
    fi

    stop_alive_pid
    cleanup
}

# Test 13: Merely being embedded does NOT promote the pending file -- only
# touching .resolved does. This is the direct check that an AI which reads
# the notice but forgets to actually relay it to the human (and so never
# touches .resolved) cannot cause the finding to be silently confirmed.
# テスト13: embedされただけではpendingファイルは昇格しない -- 昇格するのは
# .resolvedがtouchされた時だけ。これは、通知を読んだAIが実際に人間へ伝える
# のを忘れた場合(.resolvedをtouchしない場合)に、検知がサイレントに確定
# されてしまわないことの直接的な確認。
test_confirm_pending_requires_resolved_not_just_embed() {
    info "Test 13: Promotion requires .resolved, not merely being embedded"
    info "テスト13: 昇格には.resolvedが必要(embedされただけでは昇格しない)"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    make_setup_script_header "25-example" "@notify: persistent" "@confirm-target: .sandbox/.state/foo.json"
    echo "persistent body text" > "$dir/25-example.txt"
    echo '{"undeclared":["x"]}' > "$dir/25-example.pending.json"
    local target_path="$TEST_WORKSPACE/.sandbox/.state/foo.json"

    local result1 ctx1
    result1=$("$HOOK")
    ctx1=$(echo "$result1" | jq -r '.hookSpecificOutput.additionalContext')

    if [[ "$ctx1" == *"persistent body text"* ]]; then
        pass "Persistent notice is embedded"
    else
        fail "Persistent notice should be embedded: $ctx1"
    fi

    if [ -f "$dir/25-example.pending.json" ] && [ ! -f "$target_path" ]; then
        pass "Pending file NOT promoted merely because it was embedded"
    else
        fail "Pending file should remain unpromoted until .resolved is touched"
    fi

    touch "$dir/25-example.resolved"
    "$HOOK" > /dev/null

    if [ -f "$target_path" ] && jq -e '.undeclared == ["x"]' "$target_path" > /dev/null 2>&1; then
        pass "Pending content promoted once .resolved is touched"
    else
        fail "Pending content should be promoted after .resolved is touched"
        cat "$target_path" 2>&1 || echo "(target file missing)"
    fi

    if [ ! -f "$dir/25-example.pending.json" ]; then
        pass "Pending file removed after promotion"
    else
        fail "Pending file should be removed after promotion"
    fi

    stop_alive_pid
    cleanup
}

# Test 14: Without @confirm-target, an existing pending file is left alone
# even after .resolved is touched
# テスト14: @confirm-targetがなければ、.resolvedがtouchされても
# pendingファイルはそのまま残る
test_confirm_pending_not_promoted_when_tags_absent() {
    info "Test 14: Pending file untouched when @confirm-target is absent"
    info "テスト14: @confirm-targetがなければpendingファイルは変更されない"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    make_setup_script_header "25-example" "@notify: persistent"
    echo "persistent body text" > "$dir/25-example.txt"
    echo '{"undeclared":["x"]}' > "$dir/25-example.pending.json"

    "$HOOK" > /dev/null
    touch "$dir/25-example.resolved"
    "$HOOK" > /dev/null

    if [ -f "$dir/25-example.pending.json" ]; then
        pass "Pending file untouched when @confirm-target tag is absent"
    else
        fail "Pending file should be left untouched without the tag"
    fi

    if [ ! -f "$TEST_WORKSPACE/.sandbox/.state/foo.json" ]; then
        pass "No target file created without the tag"
    else
        fail "No target file should be created without the tag"
    fi

    stop_alive_pid
    cleanup
}

# Test 15: A @confirm-target tag with no pending file present does not error
# even after .resolved is touched
# テスト15: @confirm-targetタグがあっても、.resolvedがtouchされても
# pendingファイルが無ければエラーにならない
test_confirm_pending_missing_file_no_error() {
    info "Test 15: No error when the pending file doesn't exist"
    info "テスト15: pendingファイルが無くてもエラーにならない"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    make_setup_script_header "25-example" "@notify: persistent" "@confirm-target: .sandbox/.state/foo.json"
    echo "persistent body text" > "$dir/25-example.txt"
    touch "$dir/25-example.resolved"

    local result exit_code
    result=$("$HOOK")
    exit_code=$?

    if [ "$exit_code" -eq 0 ] && echo "$result" | jq empty > /dev/null 2>&1; then
        pass "Hook exits cleanly with valid JSON when the pending file is missing"
    else
        fail "Hook should not error when the pending file is missing, exit=$exit_code, result=$result"
    fi

    stop_alive_pid
    cleanup
}

# Test 16: Calling the hook again after resolution does not re-attempt or
# error a second promotion (the pending file is already gone)
# テスト16: 解決後に再度呼び出しても2回目の昇格は再試行されずエラーにも
# ならない(既にpendingファイルは無くなっているため)
test_confirm_pending_only_promotes_once() {
    info "Test 16: Repeated calls after resolution are idempotent -- no re-promotion, no error"
    info "テスト16: 解決後の再呼び出しは冪等(再昇格なし・エラーなし)"

    setup
    start_alive_pid
    local dir="$TEST_WORKSPACE/$OUT_BASE_REL/$ALIVE_PID"
    mkdir -p "$dir"
    make_setup_script_header "25-example" "@notify: persistent" "@confirm-target: .sandbox/.state/foo.json"
    echo "persistent body text" > "$dir/25-example.txt"
    echo '{"undeclared":["x"]}' > "$dir/25-example.pending.json"

    "$HOOK" > /dev/null
    touch "$dir/25-example.resolved"
    "$HOOK" > /dev/null
    local target_path first_content result
    target_path="$TEST_WORKSPACE/.sandbox/.state/foo.json"
    first_content="$(cat "$target_path")"

    result=$("$HOOK")

    if [ "$(cat "$target_path")" = "$first_content" ]; then
        pass "Target content unchanged after a further call (idempotent)"
    else
        fail "Target content should not change on further calls"
    fi

    if echo "$result" | jq empty > /dev/null 2>&1; then
        pass "Further calls still return valid JSON without error"
    else
        fail "Further calls should not error: $result"
    fi

    stop_alive_pid
    cleanup
}

# Test 17: Promotion only ever reads the PID directory it is itself
# operating on -- one session's promotion can never fold in a different
# session's own pending content.
# テスト17: 昇格処理は常に自分自身が処理しているPIDディレクトリしか
# 読まない -- あるセッションの昇格が、別セッション自身のpending内容を
# 巻き込むことはない。
test_confirm_pending_isolated_per_pid() {
    info "Test 17: Promotion is isolated per PID -- no cross-session contamination"
    info "テスト17: 昇格処理はPIDごとに独立している(セッション間の混入なし)"

    setup

    # "Session 1" detects only A, and resolves
    sleep 100 &
    local pid1=$!
    local dir1="$TEST_WORKSPACE/$OUT_BASE_REL/$pid1"
    mkdir -p "$dir1"
    make_setup_script_header "25-example" "@notify: persistent" "@confirm-target: .sandbox/.state/foo.json"
    echo "persistent body text (session 1)" > "$dir1/25-example.txt"
    echo '{"undeclared":["A"]}' > "$dir1/25-example.pending.json"

    "$HOOK" > /dev/null
    touch "$dir1/25-example.resolved"
    "$HOOK" > /dev/null
    kill "$pid1" 2>/dev/null || true
    wait "$pid1" 2>/dev/null || true

    local target_path after_session1
    target_path="$TEST_WORKSPACE/.sandbox/.state/foo.json"
    after_session1="$(jq -c '.undeclared' "$target_path" 2>/dev/null || echo 'MISSING')"

    # "Session 2" independently detected a different candidate set (A and B)
    # before session 1 resolved
    sleep 100 &
    local pid2=$!
    local dir2="$TEST_WORKSPACE/$OUT_BASE_REL/$pid2"
    mkdir -p "$dir2"
    echo "persistent body text (session 2)" > "$dir2/25-example.txt"
    echo '{"undeclared":["A","B"]}' > "$dir2/25-example.pending.json"

    "$HOOK" > /dev/null
    touch "$dir2/25-example.resolved"
    "$HOOK" > /dev/null
    kill "$pid2" 2>/dev/null || true
    wait "$pid2" 2>/dev/null || true

    local after_session2
    after_session2="$(jq -c '.undeclared' "$target_path" 2>/dev/null || echo 'MISSING')"

    if [ "$after_session1" = '["A"]' ]; then
        pass "Session 1's promotion reflects only its own pending content ({A})"
    else
        fail "Expected [\"A\"] after session 1, got: $after_session1"
    fi

    if [ "$after_session2" = '["A","B"]' ]; then
        pass "Session 2's promotion reflects its own pending content ({A,B})"
    else
        fail "Expected [\"A\",\"B\"] after session 2, got: $after_session2"
    fi

    cleanup
}

# Test 18: A stale pending snapshot promoted after a different session has
# already advanced the confirmed baseline further must not roll that
# baseline back -- promotion merges into the confirmed set rather than
# overwriting it wholesale.
# テスト18: 別セッションが既に確定baselineをさらに進めた後で、古い
# pendingスナップショットが昇格されても、そのbaselineを巻き戻して
# はならない -- 昇格は丸ごと上書きではなく、確定済み集合へマージする。
test_confirm_pending_promotion_merges_without_rolling_back() {
    info "Test 18: Promotion merges into the confirmed baseline instead of overwriting it"
    info "テスト18: 昇格は確定済みbaselineを上書きせずマージする"

    setup

    make_setup_script_header "25-example" "@notify: persistent" "@confirm-target: .sandbox/.state/foo.json"
    local target_path="$TEST_WORKSPACE/.sandbox/.state/foo.json"
    mkdir -p "$(dirname "$target_path")"
    echo '{"undeclared":["X"]}' > "$target_path"

    # Session A connected early and only knows about X and Y (not yet
    # aware of Z, which appears later)
    sleep 100 &
    local pid_a=$!
    local dir_a="$TEST_WORKSPACE/$OUT_BASE_REL/$pid_a"
    mkdir -p "$dir_a"
    echo "persistent body text (session A)" > "$dir_a/25-example.txt"
    echo '{"undeclared":["X","Y"]}' > "$dir_a/25-example.pending.json"
    "$HOOK" > /dev/null
    touch "$dir_a/25-example.resolved"
    "$HOOK" > /dev/null
    kill "$pid_a" 2>/dev/null || true
    wait "$pid_a" 2>/dev/null || true

    # Session C connected later, after Z appeared, and resolves before the
    # (slower) session B below
    sleep 100 &
    local pid_c=$!
    local dir_c="$TEST_WORKSPACE/$OUT_BASE_REL/$pid_c"
    mkdir -p "$dir_c"
    echo "persistent body text (session C)" > "$dir_c/25-example.txt"
    echo '{"undeclared":["X","Y","Z"]}' > "$dir_c/25-example.pending.json"
    "$HOOK" > /dev/null
    touch "$dir_c/25-example.resolved"
    "$HOOK" > /dev/null
    kill "$pid_c" 2>/dev/null || true
    wait "$pid_c" 2>/dev/null || true

    local after_c
    after_c="$(jq -c '.undeclared | sort' "$target_path" 2>/dev/null || echo 'MISSING')"
    if [ "$after_c" = '["X","Y","Z"]' ]; then
        pass "Z is confirmed after session C promotes"
    else
        fail "Expected [\"X\",\"Y\",\"Z\"] after session C, got: $after_c"
    fi

    # Session B connected at the same time as A (same stale snapshot,
    # unaware of Z), but only resolves now, after C already confirmed Z
    sleep 100 &
    local pid_b=$!
    local dir_b="$TEST_WORKSPACE/$OUT_BASE_REL/$pid_b"
    mkdir -p "$dir_b"
    echo "persistent body text (session B)" > "$dir_b/25-example.txt"
    echo '{"undeclared":["X","Y"]}' > "$dir_b/25-example.pending.json"
    "$HOOK" > /dev/null
    touch "$dir_b/25-example.resolved"
    "$HOOK" > /dev/null
    kill "$pid_b" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    local after_b
    after_b="$(jq -c '.undeclared | sort' "$target_path" 2>/dev/null || echo 'MISSING')"
    if [ "$after_b" = '["X","Y","Z"]' ]; then
        pass "Session B's stale promotion does not roll back Z that session C already confirmed"
    else
        fail "Expected [\"X\",\"Y\",\"Z\"] to survive session B's stale promotion, got: $after_b"
    fi

    cleanup
}

# ========================================
# Run all tests / 全テストの実行
# ========================================

echo ""
echo "=========================================="
echo "Testing hooks/setup-output-reminder.sh"
echo "hooks/setup-output-reminder.sh のテスト"
echo "=========================================="
echo ""

test_no_dir
test_empty_dir
test_alive_pid_content_inlined
test_dead_pid_only
test_newest_mtime_chosen
test_idempotent_marker
test_json_escaping
test_no_jq
test_persistent_tag_repeats_each_turn
test_persistent_tag_resolved_suppresses
test_persistent_tag_cap_enforced
test_persistent_tag_separated_from_mandatory_dump
test_confirm_pending_requires_resolved_not_just_embed
test_confirm_pending_not_promoted_when_tags_absent
test_confirm_pending_missing_file_no_error
test_confirm_pending_only_promotes_once
test_confirm_pending_isolated_per_pid
test_confirm_pending_promotion_merges_without_rolling_back

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

#!/bin/bash
# test-secret-tag.sh
# Test script for _secret-tag.sh (shared "# @secret" tmpfs-tag helpers)
#
# _secret-tag.sh のテストスクリプト（共通 "# @secret" tmpfs タグヘルパー）
#
# Usage: ./test-secret-tag.sh
# 使用方法: ./test-secret-tag.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/_secret-tag.sh"

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

# Load the library under test
# テスト対象のライブラリを読み込み
if [ ! -f "$LIB" ]; then
    fail "Library not found: $LIB"
    echo ""
    echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
    exit 1
fi
# shellcheck source=/dev/null
source "$LIB"

WORKSPACE_PATH="/workspace"
WORKSPACE_RE=$(printf '%s' "$WORKSPACE_PATH" | sed -E 's/[][\.^$(){}?+*|]/\\&/g')
EXACT_PATH="/workspace/foo/secrets"
EXACT_RE=$(printf '%s' "$EXACT_PATH" | sed -E 's/[][\.^$(){}?+*|]/\\&/g')

# === secret_tag_exact_regex ===
# === secret_tag_exact_regex のテスト ===

# Test 1: exact_regex matches a bare tagged line
# テスト1: exact_regex がタグ付きの素の行にマッチするか
test_exact_regex_matches_bare_tagged_line() {
    echo ""
    echo "=== Test: exact_regex matches a bare tagged line ==="
    local line="      - ${EXACT_PATH}  # @secret"
    local re
    re=$(secret_tag_exact_regex "$EXACT_RE")
    if [[ "$line" =~ $re ]]; then
        pass "Bare tagged line matches"
    else
        fail "Bare tagged line should match exact regex"
    fi
}

# Test 2: exact_regex tolerates a stray :ro before the tag
# テスト2: exact_regex がタグ前の余分な :ro を許容するか
test_exact_regex_matches_ro_before_tag() {
    echo ""
    echo "=== Test: exact_regex tolerates a stray :ro before the tag ==="
    local line="      - ${EXACT_PATH}:ro  # @secret"
    local re
    re=$(secret_tag_exact_regex "$EXACT_RE")
    if [[ "$line" =~ $re ]]; then
        pass "Stray :ro before tag is tolerated"
    else
        fail "Stray :ro before tag should be tolerated"
    fi
}

# Test 3: exact_regex accepts non-:ro tmpfs options before the tag
# テスト3: exact_regex がタグ前の :ro 以外の tmpfs オプションを受け付けるか
test_exact_regex_matches_other_tmpfs_options() {
    echo ""
    echo "=== Test: exact_regex accepts non-:ro tmpfs options before the tag ==="
    local line="      - ${EXACT_PATH}:rw,noexec,nosuid,size=1g  # @secret"
    local re
    re=$(secret_tag_exact_regex "$EXACT_RE")
    if [[ "$line" =~ $re ]]; then
        pass "rw,noexec,nosuid,size=1g options are accepted"
    else
        fail "Non-:ro tmpfs options before the tag should be accepted"
    fi
}

# Test 4: exact_regex accepts a percentage-based tmpfs size option before the tag
# テスト4: exact_regex がタグ前のパーセント指定の size オプションを受け付けるか
test_exact_regex_matches_percent_size_option() {
    echo ""
    echo "=== Test: exact_regex accepts a percentage-based size option before the tag ==="
    local line="      - ${EXACT_PATH}:size=50%  # @secret"
    local re
    re=$(secret_tag_exact_regex "$EXACT_RE")
    if [[ "$line" =~ $re ]]; then
        pass "size=50% option is accepted"
    else
        fail "Percentage-based size option before the tag should be accepted"
    fi
}

# Test 5: exact_regex rejects a line with no tag
# テスト5: exact_regex がタグなしの行を拒否するか
test_exact_regex_rejects_untagged_line() {
    echo ""
    echo "=== Test: exact_regex rejects a line with no tag ==="
    local line="      - ${EXACT_PATH}:ro"
    local re
    re=$(secret_tag_exact_regex "$EXACT_RE")
    if [[ "$line" =~ $re ]]; then
        fail "Untagged line should NOT match (this is the core behavior change)"
    else
        pass "Untagged line correctly does not match"
    fi
}

# Test 6: exact_regex does not match a different (longer) path
# テスト6: exact_regex が別の（より長い）パスにマッチしないか
test_exact_regex_rejects_different_path() {
    echo ""
    echo "=== Test: exact_regex does not match a different (longer) path ==="
    local line="      - ${EXACT_PATH}-other  # @secret"
    local re
    re=$(secret_tag_exact_regex "$EXACT_RE")
    if [[ "$line" =~ $re ]]; then
        fail "A longer, unrelated path should NOT match the exact regex"
    else
        pass "Different path correctly does not match"
    fi
}

# === secret_tag_prefix_regex + secret_tag_extract_path ===
# === secret_tag_prefix_regex + secret_tag_extract_path のテスト ===

# Test 7: prefix_regex matches under $WORKSPACE and extracts the clean path
# テスト7: prefix_regex が $WORKSPACE 配下でマッチし、クリーンなパスを抽出できるか
test_prefix_regex_matches_and_extracts_clean_path() {
    echo ""
    echo "=== Test: prefix_regex matches under \$WORKSPACE and extracts the clean path ==="
    local line="      - ${EXACT_PATH}  # @secret"
    local re
    re=$(secret_tag_prefix_regex "$WORKSPACE_RE")
    if [[ "$line" =~ $re ]]; then
        local extracted
        extracted=$(secret_tag_extract_path "$line")
        if [ "$extracted" = "$EXACT_PATH" ]; then
            pass "Extracted path matches: $extracted"
        else
            fail "Expected '$EXACT_PATH', got '$extracted'"
        fi
    else
        fail "Prefix regex should match a tagged line under \$WORKSPACE"
    fi
}

# Test 8: extraction strips non-:ro tmpfs options too
# テスト8: 抽出処理が :ro 以外の tmpfs オプションも除去できるか
test_prefix_regex_extracts_path_with_other_tmpfs_options() {
    echo ""
    echo "=== Test: extraction strips non-:ro tmpfs options too ==="
    local line="      - ${EXACT_PATH}:rw,noexec,nosuid,size=1g  # @secret"
    local re
    re=$(secret_tag_prefix_regex "$WORKSPACE_RE")
    if [[ "$line" =~ $re ]]; then
        local extracted
        extracted=$(secret_tag_extract_path "$line")
        if [ "$extracted" = "$EXACT_PATH" ]; then
            pass "Options stripped correctly: $extracted"
        else
            fail "Expected clean path '$EXACT_PATH', got corrupted '$extracted'"
        fi
    else
        fail "Prefix regex should match a tagged line with rw,noexec,... options"
    fi
}

# Test 9: extraction strips a percentage-based tmpfs size option too
# テスト9: 抽出処理がパーセント指定の size オプションも除去できるか
test_prefix_regex_extracts_path_with_percent_size_option() {
    echo ""
    echo "=== Test: extraction strips a percentage-based size option too ==="
    local line="      - ${EXACT_PATH}:size=50%  # @secret"
    local re
    re=$(secret_tag_prefix_regex "$WORKSPACE_RE")
    if [[ "$line" =~ $re ]]; then
        local extracted
        extracted=$(secret_tag_extract_path "$line")
        if [ "$extracted" = "$EXACT_PATH" ]; then
            pass "Percent option stripped correctly: $extracted"
        else
            fail "Expected clean path '$EXACT_PATH', got corrupted '$extracted'"
        fi
    else
        fail "Prefix regex should match a tagged line with a size=50% option"
    fi
}

# Test 10: prefix_regex rejects an untagged legacy-style line
# テスト10: prefix_regex がタグなしの旧方式の行を拒否するか
test_prefix_regex_rejects_untagged_line() {
    echo ""
    echo "=== Test: prefix_regex rejects an untagged legacy-style line ==="
    local line="      - ${EXACT_PATH}:ro"
    local re
    re=$(secret_tag_prefix_regex "$WORKSPACE_RE")
    if [[ "$line" =~ $re ]]; then
        fail "Untagged line should NOT match prefix regex"
    else
        pass "Untagged line correctly does not match prefix regex"
    fi
}

# === cross-check: exact and prefix regex must agree on the same line ===
# === クロスチェック: exact と prefix の両正規表現が同じ行で一致するか ===

# Test 11: exact_regex and prefix_regex agree on a tagged line with tmpfs options
# テスト11: tmpfs オプション付きのタグ行で exact_regex と prefix_regex の判定が一致するか
test_exact_and_prefix_agree_on_tagged_line_with_options() {
    echo ""
    echo "=== Test: exact_regex and prefix_regex agree on a tagged line with tmpfs options ==="
    local line="      - ${EXACT_PATH}:rw,noexec,nosuid,size=1g  # @secret"
    local exact_re prefix_re
    exact_re=$(secret_tag_exact_regex "$EXACT_RE")
    prefix_re=$(secret_tag_prefix_regex "$WORKSPACE_RE")
    local exact_match=false prefix_match=false
    [[ "$line" =~ $exact_re ]] && exact_match=true
    [[ "$line" =~ $prefix_re ]] && prefix_match=true
    if [ "$exact_match" = "$prefix_match" ]; then
        pass "Both regexes agree (both: $exact_match)"
    else
        fail "Disagreement: exact=$exact_match prefix=$prefix_match"
    fi
}

# Run all tests
# 全テストを実行
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  _secret-tag.sh Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    test_exact_regex_matches_bare_tagged_line
    test_exact_regex_matches_ro_before_tag
    test_exact_regex_matches_other_tmpfs_options
    test_exact_regex_matches_percent_size_option
    test_exact_regex_rejects_untagged_line
    test_exact_regex_rejects_different_path
    test_prefix_regex_matches_and_extracts_clean_path
    test_prefix_regex_extracts_path_with_other_tmpfs_options
    test_prefix_regex_extracts_path_with_percent_size_option
    test_prefix_regex_rejects_untagged_line
    test_exact_and_prefix_agree_on_tagged_line_with_options

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

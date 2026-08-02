#!/bin/bash
# test-check-undeclared-secrets.sh
# Test script for check-undeclared-secrets.sh
#
# check-undeclared-secrets.sh のテストスクリプト
#
# Usage: ./test-check-undeclared-secrets.sh
# 使用方法: ./test-check-undeclared-secrets.sh

set -e

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for this test"
    echo "エラー: このテストには jq が必要です"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-undeclared-secrets.sh"
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

    TEST_WORKSPACE=$(mktemp -d /tmp/.test-undeclared-secrets-XXXXXX)

    mkdir -p "$TEST_WORKSPACE/.devcontainer"
    mkdir -p "$TEST_WORKSPACE/.claude"
    mkdir -p "$TEST_WORKSPACE/.sandbox/scripts"
    mkdir -p "$TEST_WORKSPACE/.sandbox/config"

    cp "$SCRIPT_DIR/_startup_common.sh" "$TEST_WORKSPACE/.sandbox/scripts/"
    cp "$SCRIPT_DIR/../config/startup.conf" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true
    cp "$SCRIPT_DIR/../config/sync-ignore" "$TEST_WORKSPACE/.sandbox/config/" 2>/dev/null || true

    # Minimal empty compose file so is_path_hidden_by_compose has something to grep
    # is_path_hidden_by_compose がgrepできるよう最小限のcomposeファイルを用意
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

# ========================================
# Test Cases / テストケース
# ========================================

# Test 1: No secret-like files -> reports none found
# テスト1: 秘密っぽいファイルがない -> 「見つからなかった」と報告
test_no_candidates() {
    info "Test 1: No secret-like files found"
    info "テスト1: 秘密っぽいファイルがない"

    setup

    output=$(run_script)

    if echo "$output" | grep -q "No suspicious files found\|疑わしいファイルは見つかりませんでした"; then
        pass "Correctly reported no candidates"
    else
        fail "Should report no candidates"
        echo "Output: $output"
    fi

    cleanup
}

# Test 2: Secret-like file already declared in docker-compose.yml -> not flagged
# テスト2: docker-compose.ymlで既に宣言済みのファイル -> 未宣言扱いされない
test_declared_in_compose_not_flagged() {
    info "Test 2: File declared in docker-compose.yml is not flagged"
    info "テスト2: docker-compose.ymlで宣言済みのファイルは未宣言扱いされない"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"
    echo "      - /dev/null:$TEST_WORKSPACE/api/.env:ro" >> "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"

    output=$(run_script)

    if echo "$output" | grep -q "api/.env"; then
        fail "File declared in docker-compose.yml should not be flagged"
        echo "Output: $output"
    else
        pass "File declared in docker-compose.yml correctly not flagged"
    fi

    cleanup
}

# Test 3: Secret-like file declared nowhere -> flagged as undeclared
# テスト3: どこにも宣言されていないファイル -> 未宣言として警告
test_undeclared_file_flagged() {
    info "Test 3: Undeclared secret-like file is flagged"
    info "テスト3: 未宣言の秘密っぽいファイルが警告される"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"

    output=$(run_script)

    if echo "$output" | grep -q "api/.env"; then
        pass "Undeclared file correctly flagged"
    else
        fail "Undeclared file should be flagged"
        echo "Output: $output"
    fi

    cleanup
}

# Test 4: Secret-like file covered only by .claude/settings.json permissions.deny -> not flagged
# テスト4: .claude/settings.json の permissions.deny のみでカバーされているファイル -> 未宣言扱いされない
test_declared_in_claude_settings_not_flagged() {
    info "Test 4: File covered by .claude/settings.json permissions.deny is not flagged"
    info "テスト4: .claude/settings.jsonのpermissions.denyでカバーされているファイルは未宣言扱いされない"

    setup

    mkdir -p "$TEST_WORKSPACE/ios-app/SecureNote"
    touch "$TEST_WORKSPACE/ios-app/SecureNote/GoogleService-Info.plist"
    cat > "$TEST_WORKSPACE/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "deny": ["Read(**/GoogleService-Info.plist)"]
  }
}
EOF

    output=$(run_script)

    if echo "$output" | grep -q "GoogleService-Info.plist"; then
        fail "File covered by permissions.deny should not be flagged"
        echo "Output: $output"
    else
        pass "File covered by permissions.deny correctly not flagged"
    fi

    cleanup
}

# Test 5: File matching sync-ignore pattern (*.example) -> ignored, not flagged as undeclared
# テスト5: sync-ignoreパターン(*.example)にマッチするファイル -> 無視され未宣言扱いされない
test_sync_ignore_pattern_ignored() {
    info "Test 5: File matching sync-ignore pattern is ignored"
    info "テスト5: sync-ignoreパターンにマッチするファイルは無視される"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env.example"

    output=$(run_script)

    # The ignored file is still listed under "Ignored files" for
    # transparency, so check the undeclared section is empty instead of
    # checking for absence of the filename anywhere in the output.
    # 無視されたファイルも透明性のため「無視されたファイル」欄には表示される
    # ので、ファイル名の有無ではなく未宣言セクションが空であることを確認する。
    if echo "$output" | grep -q "No suspicious files found\|疑わしいファイルは見つかりませんでした"; then
        pass "Example file correctly excluded from undeclared list"
    else
        fail "Example file should be ignored, not flagged as undeclared"
        echo "Output: $output"
    fi

    if echo "$output" | grep -q "Ignored files\|無視されたファイル"; then
        pass "Ignored-files section shown"
    else
        fail "Ignored-files section should be shown"
        echo "Output: $output"
    fi

    cleanup
}

# Test: ".env.local" variant (not just plain ".env") is also flagged
# テスト: ".env"だけでなく".env.local"のような亜種も警告される
test_env_variant_flagged() {
    info "Test: .env.local variant is flagged"
    info "テスト: .env.localのような亜種も警告される"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env.local"

    output=$(run_script)

    if echo "$output" | grep -q "api/\.env\.local"; then
        pass ".env.local variant correctly flagged"
    else
        fail ".env.local variant should be flagged"
        echo "Output: $output"
    fi

    cleanup
}

# Test: a directory-scoped "prefix/**" deny pattern must not blanket-match
# every filename workspace-wide (regression test for the **/* glob bug: in
# `[[ ]]`, unquoted `*` matches "/" too, so an unquoted `**/* ` check matches
# ANY pattern containing a slash, not just ones that start with "**/")
# テスト: ディレクトリ限定の"prefix/**"denyパターンが、ワークスペース全体の
# 任意ファイル名にマッチしてはいけない（**/* globバグの回帰テスト:
# `[[ ]]`では引用符なしの`*`が"/"にもマッチするため、引用符なしの`**/* `
# チェックは"**/"で始まるパターンに限らず、スラッシュを含む任意のパターンに
# マッチしてしまう）
test_directory_scoped_double_star_not_over_broadened() {
    info "Test: directory-scoped prefix/** pattern doesn't over-broaden to workspace-wide"
    info "テスト: ディレクトリ限定のprefix/**パターンがワークスペース全体に広がらない"

    setup

    mkdir -p "$TEST_WORKSPACE/securenote-api/secrets" "$TEST_WORKSPACE/other-app/secrets"
    touch "$TEST_WORKSPACE/securenote-api/secrets/jwt.key"
    touch "$TEST_WORKSPACE/other-app/secrets/jwt.key"
    cat > "$TEST_WORKSPACE/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "deny": ["Read(securenote-api/secrets/**)"]
  }
}
EOF

    output=$(run_script)

    if echo "$output" | grep -q "securenote-api/secrets/jwt\.key"; then
        fail "File covered by its own directory-scoped deny pattern should not be flagged"
        echo "Output: $output"
    else
        pass "File covered by its own directory-scoped deny pattern correctly not flagged"
    fi

    if echo "$output" | grep -q "other-app/secrets/jwt\.key"; then
        pass "Unrelated file in a different directory correctly still flagged as undeclared"
    else
        fail "Unrelated file in a different directory should still be flagged (deny pattern must not blanket-match by filename alone)"
        echo "Output: $output"
    fi

    cleanup
}

# Test: an ordinary multi-segment deny pattern (no "**") must not be
# broadened into a filename-only, workspace-wide match either
# テスト: 通常のマルチセグメントdenyパターン（"**"なし）も
# ファイル名だけのワークスペース全体マッチに広がってはいけない
test_multi_segment_pattern_not_over_broadened() {
    info "Test: multi-segment pattern without ** doesn't over-broaden to workspace-wide"
    info "テスト: **を含まないマルチセグメントパターンがワークスペース全体に広がらない"

    setup

    mkdir -p "$TEST_WORKSPACE/securenote-api" "$TEST_WORKSPACE/web-app"
    touch "$TEST_WORKSPACE/securenote-api/.env.production"
    touch "$TEST_WORKSPACE/web-app/.env.production"
    cat > "$TEST_WORKSPACE/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "deny": ["Read(securenote-api/.env.*)"]
  }
}
EOF

    output=$(run_script)

    if echo "$output" | grep -q "web-app/\.env\.production"; then
        pass "Unrelated file with a matching filename in a different directory correctly still flagged as undeclared"
    else
        fail "Unrelated file with a matching filename in a different directory should still be flagged (deny pattern must not blanket-match by filename alone)"
        echo "Output: $output"
    fi

    cleanup
}

# Test: a multi-segment leading "**/dir/pattern" deny pattern must still
# scope to that directory, not collapse to a workspace-wide filename match
# (regression test for the "##**/" greedy-glob-strip bug: unquoted "*" in a
# `${var##pattern}` bash parameter expansion matches "/" too, so stripping
# "**/" via `${pattern##**/}` eats through every "/" up to the LAST one,
# turning "**/ios-app/*.mobileprovision" into just "*.mobileprovision")
# テスト: 複数セグメントの先頭"**/dir/pattern"denyパターンは、そのディレクトリに
# スコープされたままでなければならず、ワークスペース全体のファイル名マッチに
# 潰れてはいけない（"##**/"の貪欲globストリップバグの回帰テスト: bashの
# `${var##pattern}`パラメータ展開では引用符なしの`*`が"/"にもマッチするため、
# `${pattern##**/}`での"**/"の剥ぎ取りは最後の"/"まで食い尽くしてしまい、
# "**/ios-app/*.mobileprovision"が単なる"*.mobileprovision"になってしまう）
test_multi_segment_leading_double_star_not_over_broadened() {
    info "Test: multi-segment leading **/dir/pattern doesn't over-broaden to workspace-wide"
    info "テスト: 複数セグメントの先頭**/dir/patternがワークスペース全体に広がらない"

    setup

    mkdir -p "$TEST_WORKSPACE/ios-app" "$TEST_WORKSPACE/other-app"
    touch "$TEST_WORKSPACE/ios-app/foo.mobileprovision"
    touch "$TEST_WORKSPACE/other-app/foo.mobileprovision"
    cat > "$TEST_WORKSPACE/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "deny": ["Read(**/ios-app/*.mobileprovision)"]
  }
}
EOF

    output=$(run_script)

    if echo "$output" | grep -q "ios-app/foo\.mobileprovision"; then
        fail "File covered by its own scoped **/dir/pattern deny pattern should not be flagged"
        echo "Output: $output"
    else
        pass "File covered by its own scoped **/dir/pattern deny pattern correctly not flagged"
    fi

    if echo "$output" | grep -q "other-app/foo\.mobileprovision"; then
        pass "Unrelated file in a different directory correctly still flagged as undeclared"
    else
        fail "Unrelated file in a different directory should still be flagged (**/dir/pattern must not blanket-match by filename alone)"
        echo "Output: $output"
    fi

    cleanup
}

# Test 6: secrets/ directory covered by tmpfs mount -> not flagged
# テスト6: tmpfsマウントでカバーされているsecrets/ディレクトリ -> 未宣言扱いされない
test_tmpfs_dir_not_flagged() {
    info "Test 6: secrets/ directory covered by tmpfs is not flagged"
    info "テスト6: tmpfsマウントでカバーされているsecrets/ディレクトリは未宣言扱いされない"

    setup

    mkdir -p "$TEST_WORKSPACE/api/secrets"
    touch "$TEST_WORKSPACE/api/secrets/jwt.key"
    {
        echo "    tmpfs:"
        echo "      - $TEST_WORKSPACE/api/secrets:ro"
    } >> "$TEST_WORKSPACE/.devcontainer/docker-compose.yml"

    output=$(run_script)

    if echo "$output" | grep -q "api/secrets$"; then
        fail "tmpfs-covered secrets/ dir should not be flagged"
        echo "Output: $output"
    else
        pass "tmpfs-covered secrets/ dir correctly not flagged"
    fi

    cleanup
}

# Test: a trailing-slash directory deny pattern (e.g. "Read(dirname/)") must
# cover files underneath that directory, not just an exact match on the
# directory path itself (regression test for a bug where only the directory
# entry was recognized as declared, leaving every file inside it flagged as
# undeclared on every run).
# テスト: 末尾スラッシュ付きディレクトリdenyパターン（例: "Read(dirname/)"）は
# ディレクトリ自身の完全一致だけでなく、配下のファイルもカバーしなければ
# ならない（ディレクトリ自体のみ宣言済み扱いされ、配下の全ファイルが毎回
# 未宣言として警告され続けていたバグの回帰テスト）。
test_trailing_slash_dir_pattern_covers_files_underneath() {
    info "Test: trailing-slash dir pattern covers files underneath it"
    info "テスト: 末尾スラッシュ付きディレクトリパターンは配下のファイルもカバーする"

    setup

    mkdir -p "$TEST_WORKSPACE/someapp/secrets"
    touch "$TEST_WORKSPACE/someapp/secrets/id_rsa.pem"
    cat > "$TEST_WORKSPACE/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "deny": ["Read(someapp/secrets/)"]
  }
}
EOF

    output=$(run_script)

    if echo "$output" | grep -q "someapp/secrets/id_rsa\.pem"; then
        fail "File under a directory covered by a trailing-slash deny pattern should not be flagged"
        echo "Output: $output"
    else
        pass "File under a directory covered by a trailing-slash deny pattern correctly not flagged"
    fi

    cleanup
}

# Test: the "**/dirname/" recursive directory deny pattern variant must also
# cover files underneath a matching directory at any depth, not just files
# whose own basename happens to equal the directory name.
# テスト: "**/dirname/"形式の再帰ディレクトリdenyパターンも、任意の深さで
# マッチしたディレクトリ配下のファイルをカバーしなければならない
# （ファイル名自体がディレクトリ名と一致する場合だけではいけない）。
test_recursive_dir_pattern_covers_files_underneath() {
    info "Test: recursive **/dirname/ pattern covers files underneath it"
    info "テスト: **/dirname/パターンは配下のファイルもカバーする"

    setup

    mkdir -p "$TEST_WORKSPACE/api/secrets" "$TEST_WORKSPACE/other-api/secrets"
    touch "$TEST_WORKSPACE/api/secrets/jwt.key"
    cat > "$TEST_WORKSPACE/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "deny": ["Read(**/secrets/)"]
  }
}
EOF

    output=$(run_script)

    if echo "$output" | grep -q "api/secrets/jwt\.key"; then
        fail "File under a directory matched by a recursive **/dirname/ deny pattern should not be flagged"
        echo "Output: $output"
    else
        pass "File under a directory matched by a recursive **/dirname/ deny pattern correctly not flagged"
    fi

    cleanup
}

# Test 7: Script always exits 0, even with undeclared secrets found (advisory only)
# テスト7: 未宣言のシークレットが見つかっても常にexit 0（助言のみ）
test_always_exits_zero() {
    info "Test 7: Script exits 0 even when undeclared secrets are found"
    info "テスト7: 未宣言のシークレットが見つかっても exit 0"

    setup

    mkdir -p "$TEST_WORKSPACE/api"
    touch "$TEST_WORKSPACE/api/.env"

    set +e
    run_script > /dev/null 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ]; then
        pass "Exit code is 0 (advisory only)"
    else
        fail "Exit code should be 0, got $exit_code"
    fi

    cleanup
}

# ========================================
# Run all tests / 全テストの実行
# ========================================

echo ""
echo "=========================================="
echo "Testing check-undeclared-secrets.sh"
echo "check-undeclared-secrets.sh のテスト"
echo "=========================================="
echo ""

test_no_candidates
test_declared_in_compose_not_flagged
test_undeclared_file_flagged
test_declared_in_claude_settings_not_flagged
test_directory_scoped_double_star_not_over_broadened
test_multi_segment_pattern_not_over_broadened
test_multi_segment_leading_double_star_not_over_broadened
test_trailing_slash_dir_pattern_covers_files_underneath
test_recursive_dir_pattern_covers_files_underneath
test_sync_ignore_pattern_ignored
test_env_variant_flagged
test_tmpfs_dir_not_flagged
test_always_exits_zero

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

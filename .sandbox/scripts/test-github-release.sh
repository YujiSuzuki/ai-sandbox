#!/bin/bash
# test-github-release.sh
# Test github-release.py: version validation, --repo, draft generation, and publish (tag + push)
#
# github-release.py のテスト: バージョン検証、--repo、ドラフト生成、リリース実行（タグ作成・push）
#
# Usage: .sandbox/scripts/test-github-release.sh
#
# Category: test
# Env: container

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/github-release.py"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIRS=()

pass() { echo -e "${GREEN}✅ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}❌ FAIL${NC}: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Create a temp git repo with its own bare "origin" remote (real local push
# target, so tag-push tests exercise the actual `git push` path without
# touching the network / a real GitHub repo).
# 独自のbare "origin" リモートを持つ一時gitリポジトリを作成する（ネットワーク・
# 実際のGitHubリポジトリに触れずに、実際の `git push` の経路をテストできるよう
# 実際にpushできるローカルの対象を用意する）。
make_temp_repo() {
    local tmp bare
    tmp=$(mktemp -d)
    bare=$(mktemp -d)
    TEMP_DIRS+=("$tmp" "$bare")

    git init -q --bare "$bare"

    git -C "$tmp" init -q
    git -C "$tmp" config user.email "test@test.com"
    git -C "$tmp" config user.name "Test"
    git -C "$tmp" remote add origin "$bare"
    echo "hello" > "$tmp/hello.txt"
    git -C "$tmp" add hello.txt
    git -C "$tmp" commit -q -m "Add hello.txt"
    git -C "$tmp" branch -m main
    git -C "$tmp" push -q origin main

    echo "$tmp"
}

cleanup() {
    for d in "${TEMP_DIRS[@]:-}"; do
        [[ -d "$d" ]] && rm -rf "$d" || true
    done
}
trap cleanup EXIT

echo ""
echo "Testing github-release.py"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── Test 1: rejects a non-semver version / Test 1: semver形式でないバージョンを拒否 ───
echo "Test 1: rejects a non-semver version argument"
REPO=$(make_temp_repo)
OUTPUT=$("$SCRIPT" v1 --repo "$REPO" 2>&1 || true)
if echo "$OUTPUT" | grep -qi "semver"; then
    pass "non-semver version rejected with a semver-format error"
else
    fail "non-semver version did not produce the expected error"
    echo "  Output: $OUTPUT"
fi

# ─── Test 2: requires a version argument / Test 2: バージョン引数が必須 ───────────
echo "Test 2: missing version argument exits with error"
REPO=$(make_temp_repo)
OUTPUT=$("$SCRIPT" --repo "$REPO" 2>&1 || true)
if echo "$OUTPUT" | grep -qi "version"; then
    pass "missing version argument exits with a version-related error"
else
    fail "missing version argument did not produce the expected error"
    echo "  Output: $OUTPUT"
fi

# ─── Test 3: --repo with non-existent path exits with error / Test 3: 存在しない --repo はエラー ───
echo "Test 3: non-existent --repo path exits with error"
OUTPUT=$("$SCRIPT" v0.1.0 --repo /nonexistent/path/xyz 2>&1 || true)
if echo "$OUTPUT" | grep -qi "not found\|no such\|directory"; then
    pass "non-existent --repo exits with error message"
else
    fail "non-existent --repo did not produce expected error"
    echo "  Output: $OUTPUT"
fi

# ─── Test 4: draft mode generates a categorized draft in the target repo / Test 4: draftモードで対象リポジトリにドラフト生成 ───
echo "Test 4: draft mode writes ReleaseNotes-draft.md into the target repo"
REPO=$(make_temp_repo)
OUTPUT=$("$SCRIPT" v0.1.0 --repo "$REPO" 2>&1 || true)
if [[ -f "$REPO/ReleaseNotes-draft.md" ]] && grep -q "Add hello.txt" "$REPO/ReleaseNotes-draft.md"; then
    pass "ReleaseNotes-draft.md written with the commit entry"
else
    fail "ReleaseNotes-draft.md missing or missing expected commit entry"
    echo "  Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "### Features"; then
    pass "draft categorizes an Add* commit under Features"
else
    fail "draft did not categorize the Add* commit as a Feature"
fi

# ─── Test 5: publish mode creates and pushes a tag / Test 5: publishモードでタグを作成・push ───
echo "Test 5: publish mode (--notes-file) creates and pushes the tag"
REPO=$(make_temp_repo)
"$SCRIPT" v0.1.0 --repo "$REPO" > /dev/null 2>&1 || true
sed -i.bak 's/<describe change>/Test release/g' "$REPO/ReleaseNotes-draft.md" && rm -f "$REPO/ReleaseNotes-draft.md.bak"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "Add release notes"
echo "y" | "$SCRIPT" v0.1.0 --repo "$REPO" --notes-file "$REPO/ReleaseNotes-draft.md" > /dev/null 2>&1 || true
if git -C "$REPO" tag | grep -qx "v0.1.0"; then
    pass "publish mode created the local tag"
else
    fail "publish mode did not create the local tag v0.1.0"
fi

# ─── Test 6: publish mode refuses to recreate an existing tag / Test 6: 既存タグの再作成を拒否 ───
echo "Test 6: publish mode refuses a version whose tag already exists"
OUTPUT=$(echo "y" | "$SCRIPT" v0.1.0 --repo "$REPO" --notes-file "$REPO/ReleaseNotes-draft.md" 2>&1 || true)
if echo "$OUTPUT" | grep -qi "already exists\|すでに存在します"; then
    pass "existing tag rejected with an already-exists error"
else
    fail "existing tag was not rejected as expected"
    echo "  Output: $OUTPUT"
fi

# ─── Test 7: publish mode with non-existent --notes-file exits with error / Test 7: 存在しない --notes-file はエラー ───
echo "Test 7: non-existent --notes-file exits with error"
REPO=$(make_temp_repo)
OUTPUT=$("$SCRIPT" v0.2.0 --repo "$REPO" --notes-file "$REPO/nonexistent-notes.md" 2>&1 || true)
if echo "$OUTPUT" | grep -qi "not found\|見つかりません"; then
    pass "non-existent --notes-file exits with error message"
else
    fail "non-existent --notes-file did not produce expected error"
    echo "  Output: $OUTPUT"
fi

# ─── Summary / まとめ ───────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Results: ${GREEN}${TESTS_PASSED} passed${NC}, ${RED}${TESTS_FAILED} failed${NC}"
echo ""

[[ "$TESTS_FAILED" -eq 0 ]]

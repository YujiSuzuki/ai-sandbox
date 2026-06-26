#!/bin/bash
# test-commit-msg-repo.sh
# Test --repo option for commit-msg.sh
#
# commit-msg.sh の --repo オプションのテスト
#
# Usage: .sandbox/scripts/test-commit-msg-repo.sh
#
# Category: test
# Env: container

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/commit-msg.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_REPOS=()

pass() { echo -e "${GREEN}✅ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}❌ FAIL${NC}: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Create a temporary git repo with staged changes
# ステージ済み変更を持つ一時 git リポジトリを作成
make_temp_repo() {
    local tmp
    tmp=$(mktemp -d)
    TEMP_REPOS+=("$tmp")
    git -C "$tmp" init -q
    git -C "$tmp" config user.email "test@test.com"
    git -C "$tmp" config user.name "Test"
    # Initial commit so HEAD exists
    git -C "$tmp" commit -q --allow-empty -m "init"
    # Stage a new file
    echo "hello" > "$tmp/hello.txt"
    git -C "$tmp" add hello.txt
    echo "$tmp"
}

cleanup() {
    for d in "${TEMP_REPOS[@]:-}"; do
        [[ -d "$d" ]] && rm -rf "$d" || true
    done
}
trap cleanup EXIT

echo ""
echo "Testing commit-msg.sh --repo option"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── Test 1: --repo picks up staged changes from target repo ───────────────
echo "Test 1: --repo detects staged changes in target repo"
REPO=$(make_temp_repo)
OUTPUT=$("$SCRIPT" --repo "$REPO" 2>&1 || true)
if echo "$OUTPUT" | grep -q "hello.txt"; then
    pass "--repo picks up staged files from target repo"
else
    fail "--repo did not detect hello.txt in target repo"
    echo "  Output: $OUTPUT"
fi

# ─── Test 2: draft file is written inside the target repo ──────────────────
echo "Test 2: draft file is written into the target repo directory"
REPO=$(make_temp_repo)
"$SCRIPT" --repo "$REPO" > /dev/null 2>&1 || true
if [[ -f "$REPO/CommitMsg-draft.md" ]]; then
    pass "CommitMsg-draft.md written into target repo"
else
    fail "CommitMsg-draft.md not found in target repo ($REPO)"
fi

# ─── Test 3: --repo with non-existent path exits with error ────────────────
echo "Test 3: non-existent --repo path exits with error"
OUTPUT=$("$SCRIPT" --repo /nonexistent/path/xyz 2>&1 || true)
if echo "$OUTPUT" | grep -qi "not found\|no such\|directory"; then
    pass "non-existent --repo exits with error message"
else
    fail "non-existent --repo did not produce expected error"
    echo "  Output: $OUTPUT"
fi

# ─── Test 4: without --repo, uses current directory's repo ────────────────
echo "Test 4: without --repo, operates on CWD's git repo"
REPO=$(make_temp_repo)
# Run from inside the temp repo (no --repo flag)
OUTPUT=$(cd "$REPO" && "$SCRIPT" 2>&1 || true)
if echo "$OUTPUT" | grep -q "hello.txt"; then
    pass "without --repo, staged files from CWD repo are detected"
else
    fail "without --repo, staged files from CWD repo were not detected"
    echo "  Output: $OUTPUT"
fi

# ─── Test 5: --repo with --msg-file commits to target repo ────────────────
echo "Test 5: --repo with --msg-file commits to target repo"
REPO=$(make_temp_repo)
# Generate draft first
"$SCRIPT" --repo "$REPO" > /dev/null 2>&1 || true
# Replace placeholders so commit-msg.sh accepts the draft
sed -i 's/<変更内容を記述>/test change/g; s/<変更の詳細を記述>/details/g; s/<describe change>/test change/g' "$REPO/CommitMsg-draft.md"
# Commit using the draft (pipe "y" for confirmation)
echo "y" | "$SCRIPT" --repo "$REPO" --msg-file "$REPO/CommitMsg-draft.md" > /dev/null 2>&1 || true
COMMIT_COUNT=$(git -C "$REPO" log --oneline | wc -l | tr -d ' ')
if [[ "$COMMIT_COUNT" -ge 2 ]]; then
    pass "--repo with --msg-file created a commit in target repo"
else
    fail "--repo with --msg-file did not create a commit (log count: $COMMIT_COUNT)"
fi

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Results: ${GREEN}${TESTS_PASSED} passed${NC}, ${RED}${TESTS_FAILED} failed${NC}"
echo ""

[[ "$TESTS_FAILED" -eq 0 ]]

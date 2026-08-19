#!/bin/bash
# test-secret-tag-py.sh
# Test script for _secret_tag.py (Python port of _secret-tag.sh's shared
# "# @secret" tmpfs-tag helpers). Mirrors test-secret-tag.sh's 11 cases
# one-for-one so the two libraries stay behaviorally identical.
#
# _secret_tag.py（_secret-tag.sh の共通 "# @secret" tmpfs タグヘルパーの
# Python移植版）のテストスクリプト。両ライブラリの挙動が一致し続けるよう、
# test-secret-tag.sh の11ケースを1対1で踏襲している。
#
# Usage: ./test-secret-tag-py.sh
# 使用方法: ./test-secret-tag-py.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/_secret_tag.py"

if [ ! -f "$LIB" ]; then
    echo "❌ Library not found: $LIB"
    exit 1
fi

# The actual assertions run inside Python (testing Python regex behavior
# through bash [[ =~ ]] would test the wrong regex engine), but this stays a
# test-*.sh file so run-all-tests.sh's glob discovers and runs it like every
# other test here.
# 実際のアサーションはPython側で行う（Pythonの正規表現の挙動をbashの
# [[ =~ ]] で検証しても別のregexエンジンを検証することになってしまう）。
# ただしファイル自体は test-*.sh のままにしてあり、run-all-tests.sh のglobが
# 他のテストと同様に発見・実行できるようにしている。
PYTHONPATH="$SCRIPT_DIR" python3 - <<'PYEOF'
import re
import sys

from _secret_tag import secret_tag_exact_regex, secret_tag_prefix_regex, secret_tag_extract_path

RED = "\033[0;31m"
GREEN = "\033[0;32m"
NC = "\033[0m"

passed = 0
failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"{GREEN}✅ {msg}{NC}")


def bad(msg):
    global failed
    failed += 1
    print(f"{RED}❌ {msg}{NC}")


WORKSPACE_PATH = "/workspace"
WORKSPACE_RE = re.escape(WORKSPACE_PATH)
EXACT_PATH = "/workspace/foo/secrets"
EXACT_RE = re.escape(EXACT_PATH)

print()
print("=" * 62)
print("  _secret_tag.py Test Suite")
print("=" * 62)

# Test 1: exact_regex matches a bare tagged line
print()
print("=== Test: exact_regex matches a bare tagged line ===")
line = f"      - {EXACT_PATH}  # @secret"
if re.search(secret_tag_exact_regex(EXACT_RE), line):
    ok("Bare tagged line matches")
else:
    bad("Bare tagged line should match exact regex")

# Test 2: exact_regex tolerates a stray :ro before the tag
print()
print("=== Test: exact_regex tolerates a stray :ro before the tag ===")
line = f"      - {EXACT_PATH}:ro  # @secret"
if re.search(secret_tag_exact_regex(EXACT_RE), line):
    ok("Stray :ro before tag is tolerated")
else:
    bad("Stray :ro before tag should be tolerated")

# Test 3: exact_regex accepts non-:ro tmpfs options before the tag
print()
print("=== Test: exact_regex accepts non-:ro tmpfs options before the tag ===")
line = f"      - {EXACT_PATH}:rw,noexec,nosuid,size=1g  # @secret"
if re.search(secret_tag_exact_regex(EXACT_RE), line):
    ok("rw,noexec,nosuid,size=1g options are accepted")
else:
    bad("Non-:ro tmpfs options before the tag should be accepted")

# Test 4: exact_regex accepts a percentage-based tmpfs size option before the tag
print()
print("=== Test: exact_regex accepts a percentage-based size option before the tag ===")
line = f"      - {EXACT_PATH}:size=50%  # @secret"
if re.search(secret_tag_exact_regex(EXACT_RE), line):
    ok("size=50% option is accepted")
else:
    bad("Percentage-based size option before the tag should be accepted")

# Test 5: exact_regex rejects a line with no tag
print()
print("=== Test: exact_regex rejects a line with no tag ===")
line = f"      - {EXACT_PATH}:ro"
if re.search(secret_tag_exact_regex(EXACT_RE), line):
    bad("Untagged line should NOT match (this is the core behavior change)")
else:
    ok("Untagged line correctly does not match")

# Test 6: exact_regex does not match a different (longer) path
print()
print("=== Test: exact_regex does not match a different (longer) path ===")
line = f"      - {EXACT_PATH}-other  # @secret"
if re.search(secret_tag_exact_regex(EXACT_RE), line):
    bad("A longer, unrelated path should NOT match the exact regex")
else:
    ok("Different path correctly does not match")

# Test 7: prefix_regex matches under $WORKSPACE and extracts the clean path
print()
print("=== Test: prefix_regex matches under $WORKSPACE and extracts the clean path ===")
line = f"      - {EXACT_PATH}  # @secret"
if re.search(secret_tag_prefix_regex(WORKSPACE_RE), line):
    extracted = secret_tag_extract_path(line)
    if extracted == EXACT_PATH:
        ok(f"Extracted path matches: {extracted}")
    else:
        bad(f"Expected '{EXACT_PATH}', got '{extracted}'")
else:
    bad("Prefix regex should match a tagged line under $WORKSPACE")

# Test 8: extraction strips non-:ro tmpfs options too
print()
print("=== Test: extraction strips non-:ro tmpfs options too ===")
line = f"      - {EXACT_PATH}:rw,noexec,nosuid,size=1g  # @secret"
if re.search(secret_tag_prefix_regex(WORKSPACE_RE), line):
    extracted = secret_tag_extract_path(line)
    if extracted == EXACT_PATH:
        ok(f"Options stripped correctly: {extracted}")
    else:
        bad(f"Expected clean path '{EXACT_PATH}', got corrupted '{extracted}'")
else:
    bad("Prefix regex should match a tagged line with rw,noexec,... options")

# Test 9: extraction strips a percentage-based tmpfs size option too
print()
print("=== Test: extraction strips a percentage-based size option too ===")
line = f"      - {EXACT_PATH}:size=50%  # @secret"
if re.search(secret_tag_prefix_regex(WORKSPACE_RE), line):
    extracted = secret_tag_extract_path(line)
    if extracted == EXACT_PATH:
        ok(f"Percent option stripped correctly: {extracted}")
    else:
        bad(f"Expected clean path '{EXACT_PATH}', got corrupted '{extracted}'")
else:
    bad("Prefix regex should match a tagged line with a size=50% option")

# Test 10: prefix_regex rejects an untagged legacy-style line
print()
print("=== Test: prefix_regex rejects an untagged legacy-style line ===")
line = f"      - {EXACT_PATH}:ro"
if re.search(secret_tag_prefix_regex(WORKSPACE_RE), line):
    bad("Untagged line should NOT match prefix regex")
else:
    ok("Untagged line correctly does not match prefix regex")

# Test 11: exact_regex and prefix_regex agree on a tagged line with tmpfs options
print()
print("=== Test: exact_regex and prefix_regex agree on a tagged line with tmpfs options ===")
line = f"      - {EXACT_PATH}:rw,noexec,nosuid,size=1g  # @secret"
exact_match = bool(re.search(secret_tag_exact_regex(EXACT_RE), line))
prefix_match = bool(re.search(secret_tag_prefix_regex(WORKSPACE_RE), line))
if exact_match == prefix_match:
    ok(f"Both regexes agree (both: {exact_match})")
else:
    bad(f"Disagreement: exact={exact_match} prefix={prefix_match}")

print()
print("=" * 62)
print(f"  Results: {passed} passed, {failed} failed")
print("=" * 62)
print()

sys.exit(1 if failed else 0)
PYEOF

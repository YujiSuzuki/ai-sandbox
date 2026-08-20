#!/bin/bash
# test-check-upstream-updates.sh
# Test update check functionality
# 更新チェック機能のテスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-/workspace}"
SCRIPT="$SCRIPT_DIR/check-upstream-updates.py"

# Resolved once, up front, and always used to invoke Python scripts below
# instead of relying on the `#!/usr/bin/env python3` shebang: a couple of
# tests deliberately restrict PATH to simulate "not installed" states, and a
# restricted PATH can hide python3 itself (unlike bash, whose `#!/bin/bash`
# shebang is a fixed absolute path, not a PATH lookup).
# 事前に一度だけ解決し、以下ではPythonスクリプトの実行に常にこれを使う
# （`#!/usr/bin/env python3` シェバングには頼らない）: 以下のテストの一部は
# 意図的にPATHを制限して「未インストール」状態を再現するが、制限された
# PATHはpython3自体を隠してしまう場合がある（bashの`#!/bin/bash`は
# 固定の絶対パスであり、PATH参照ではないため、この問題が起きない）。
PYTHON3="$(command -v python3)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

# Test helpers
pass() { echo -e "${GREEN}PASS${NC}: $1"; ((TESTS_PASSED++)) || true; }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((TESTS_FAILED++)) || true; }
info() { echo -e "${YELLOW}INFO${NC}: $1"; }

# Temp directory for tests
TEST_TMP_DIR=""

setup() {
    TEST_TMP_DIR=$(mktemp -d)
    # Only the config directory is needed: the Python script resolves
    # _python_common.py via its own directory (sys.path[0]), not via
    # $WORKSPACE, so no library file needs copying/symlinking here (unlike
    # the bash original, which had to symlink _startup_common.sh into a
    # fake $WORKSPACE/.sandbox/scripts/ for `source` to find it).
    # config ディレクトリのみで足りる: Pythonスクリプトは _python_common.py を
    # 自身のディレクトリ（sys.path[0]）経由でimportするため、$WORKSPACE
    # 経由ではない。よってライブラリファイルのコピー/シンボリックリンクは
    # 不要（bash版はsourceで見つけられるよう、_startup_common.shを偽の
    # $WORKSPACE/.sandbox/scripts/ にシンボリックリンクする必要があった）。
    mkdir -p "$TEST_TMP_DIR/.sandbox/config"
}

teardown() {
    [ -n "$TEST_TMP_DIR" ] && rm -rf "$TEST_TMP_DIR"
}

# ============================================================
# Test: Configuration file exists and is valid
# ============================================================
test_config_file() {
    echo ""
    echo "=== Testing template-source.conf ==="

    local config_file="$WORKSPACE/.sandbox/config/template-source.conf"

    if [ -f "$config_file" ]; then
        pass "template-source.conf exists"
    else
        fail "template-source.conf does not exist"
        return
    fi

    # Check required variables
    if grep -q "^TEMPLATE_REPO=" "$config_file"; then
        pass "template-source.conf contains TEMPLATE_REPO"
    else
        fail "template-source.conf should contain TEMPLATE_REPO"
    fi

    if grep -q "^CHECK_UPDATES=" "$config_file"; then
        pass "template-source.conf contains CHECK_UPDATES"
    else
        fail "template-source.conf should contain CHECK_UPDATES"
    fi

    if grep -q "^CHECK_CHANNEL=" "$config_file"; then
        pass "template-source.conf contains CHECK_CHANNEL"
    else
        fail "template-source.conf should contain CHECK_CHANNEL"
    fi

    if grep -q "^CHECK_INTERVAL_HOURS=" "$config_file"; then
        pass "template-source.conf contains CHECK_INTERVAL_HOURS"
    else
        fail "template-source.conf should contain CHECK_INTERVAL_HOURS"
    fi

    # Check default values
    # shellcheck source=/dev/null
    source "$config_file"

    if [ "$TEMPLATE_REPO" = "YujiSuzuki/ai-sandbox" ]; then
        pass "TEMPLATE_REPO has correct default value"
    else
        fail "TEMPLATE_REPO should be 'YujiSuzuki/ai-sandbox', got '$TEMPLATE_REPO'"
    fi

    if [ "$CHECK_UPDATES" = "true" ]; then
        pass "CHECK_UPDATES is enabled by default"
    else
        fail "CHECK_UPDATES should be 'true', got '$CHECK_UPDATES'"
    fi

    if [ "$CHECK_CHANNEL" = "all" ]; then
        pass "CHECK_CHANNEL is 'all' by default"
    else
        fail "CHECK_CHANNEL should be 'all', got '$CHECK_CHANNEL'"
    fi

    if [ "$CHECK_INTERVAL_HOURS" = "24" ]; then
        pass "CHECK_INTERVAL_HOURS is 24 hours by default"
    else
        fail "CHECK_INTERVAL_HOURS should be '24', got '$CHECK_INTERVAL_HOURS'"
    fi
}

# Note: state file read/write, interval-check logic, build_api_url, and
# extract_tag_from_json live in the shared _python_common.py
# (read_state_timestamp, get_last_notified_version, is_first_run,
# should_check, update_state, build_api_url, extract_tag_from_json) and are
# covered there by test-python-common-startup.sh -- re-testing them here
# would just duplicate that coverage, since check-upstream-updates.py
# doesn't implement any of it itself.
# 注: 状態ファイルの読み書き、間隔チェックロジック、build_api_url、
# extract_tag_from_json は共有の _python_common.py（read_state_timestamp、
# get_last_notified_version、is_first_run、should_check、update_state、
# build_api_url、extract_tag_from_json）に存在し、test-python-common-startup.sh
# でカバーされている -- check-upstream-updates.py はそれらを自前で
# 実装していないため、ここで再テストすると重複するだけになる。

# ============================================================
# Test: Debug mode outputs diagnostic info to stderr
# ============================================================
test_debug_mode() {
    echo ""
    echo "=== Testing debug mode ==="

    local stderr_output

    # テスト用の設定ファイルを作成（CHECK_UPDATES=false で即終了させる）
    local mock_config="$TEST_TMP_DIR/.sandbox/config/template-source.conf"
    cat > "$mock_config" <<'EOF'
TEMPLATE_REPO="YujiSuzuki/ai-sandbox"
CHECK_CHANNEL="all"
CHECK_UPDATES="false"
CHECK_INTERVAL_HOURS="0"
EOF

    # Test 1: --debug flag produces debug output on stderr
    stderr_output=$( (WORKSPACE="$TEST_TMP_DIR" "$PYTHON3" "$SCRIPT" --debug) 2>&1 1>/dev/null ) || true
    if echo "$stderr_output" | grep -q "^\[debug\]"; then
        pass "--debug flag produces [debug] output on stderr"
    else
        fail "--debug flag should produce [debug] output on stderr, got: '$stderr_output'"
    fi

    # Test 2: DEBUG_UPDATE_CHECK=1 environment variable also works
    stderr_output=$( (WORKSPACE="$TEST_TMP_DIR" DEBUG_UPDATE_CHECK=1 "$PYTHON3" "$SCRIPT") 2>&1 1>/dev/null ) || true
    if echo "$stderr_output" | grep -q "^\[debug\]"; then
        pass "DEBUG_UPDATE_CHECK=1 produces [debug] output on stderr"
    else
        fail "DEBUG_UPDATE_CHECK=1 should produce [debug] output on stderr, got: '$stderr_output'"
    fi

    # Test 3: Without debug, no [debug] output
    stderr_output=$( (WORKSPACE="$TEST_TMP_DIR" "$PYTHON3" "$SCRIPT") 2>&1 1>/dev/null ) || true
    if echo "$stderr_output" | grep -q "^\[debug\]"; then
        fail "Without debug flag, should not produce [debug] output"
    else
        pass "Without debug flag, no [debug] output on stderr"
    fi

    # Test 4: Debug shows config values when loaded
    stderr_output=$( (WORKSPACE="$TEST_TMP_DIR" DEBUG_UPDATE_CHECK=1 "$PYTHON3" "$SCRIPT") 2>&1 1>/dev/null ) || true
    if echo "$stderr_output" | grep -q "Config loaded:"; then
        pass "Debug output includes config values"
    else
        fail "Debug output should include 'Config loaded:', got: '$stderr_output'"
    fi

    # Test 5: Debug shows reason for exit (CHECK_UPDATES=false in mock config)
    if echo "$stderr_output" | grep -q "disabled, exit"; then
        pass "Debug output shows disabled reason"
    else
        fail "Debug output should show disabled reason, got: '$stderr_output'"
    fi

    # Test 6: Debug output goes to stderr, not stdout (stdout should be empty)
    local stdout_output
    stdout_output=$( (WORKSPACE="$TEST_TMP_DIR" DEBUG_UPDATE_CHECK=1 "$PYTHON3" "$SCRIPT") 2>/dev/null ) || true
    if [ -z "$stdout_output" ]; then
        pass "Debug output goes to stderr only, stdout is clean"
    else
        fail "Debug output should not appear on stdout, got: '$stdout_output'"
    fi
}

# ============================================================
# Test: First run records version without notification
# ============================================================
test_first_run_no_notification() {
    echo ""
    echo "=== Testing first run behavior ==="

    # テスト用の設定ファイル（CHECK_UPDATES=true, INTERVAL=0 で毎回チェック）
    local mock_config="$TEST_TMP_DIR/.sandbox/config/template-source.conf"
    cat > "$mock_config" <<'EOF'
TEMPLATE_REPO="YujiSuzuki/ai-sandbox"
CHECK_CHANNEL="all"
CHECK_UPDATES="true"
CHECK_INTERVAL_HOURS="0"
EOF

    # STATE_FILE を明示的に削除して初回状態にする
    local mock_state="$TEST_TMP_DIR/state"
    rm -f "$mock_state"

    # Test 1: 初回実行 → stdout に通知が出ない（記録のみ）
    local stdout_output
    stdout_output=$( (WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" MOCK_LATEST_VERSION="v0.0.1-test" "$PYTHON3" "$SCRIPT") 2>/dev/null ) || true
    if [ -z "$stdout_output" ]; then
        pass "First run produces no notification on stdout"
    else
        fail "First run should produce no notification, got: '$stdout_output'"
    fi

    # Test 2: 初回実行後、状態ファイルが作成されている
    if [ -f "$mock_state" ]; then
        pass "State file created after first run"
    else
        fail "State file should be created after first run"
    fi

    # Test 3: 状態ファイルにバージョンが記録されている
    local recorded_version
    recorded_version=$(cut -d: -f2- "$mock_state" 2>/dev/null || echo "")
    if [ -n "$recorded_version" ]; then
        pass "State file contains recorded version: $recorded_version"
    else
        fail "State file should contain a version"
    fi

    # Test 4: Debug で "First run" が出る
    rm -f "$mock_state"
    local stderr_output
    stderr_output=$( (WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" DEBUG_UPDATE_CHECK=1 MOCK_LATEST_VERSION="v0.0.1-test" "$PYTHON3" "$SCRIPT") 2>&1 1>/dev/null ) || true
    if echo "$stderr_output" | grep -q "First run"; then
        pass "Debug output shows 'First run' on first execution"
    else
        fail "Debug output should show 'First run', got: '$stderr_output'"
    fi
}

# ============================================================
# Test: Same version does not re-notify
# ============================================================
test_same_version_no_renotify() {
    echo ""
    echo "=== Testing same version dedup ==="

    # Test config file / テスト用の設定ファイル
    local mock_config="$TEST_TMP_DIR/.sandbox/config/template-source.conf"
    cat > "$mock_config" <<'EOF'
TEMPLATE_REPO="YujiSuzuki/ai-sandbox"
CHECK_CHANNEL="all"
CHECK_UPDATES="true"
CHECK_INTERVAL_HOURS="0"
EOF

    # First run (records the version) / 初回実行（バージョン記録）
    local mock_state="$TEST_TMP_DIR/state"
    rm -f "$mock_state"
    (WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" MOCK_LATEST_VERSION="v0.0.1-test" "$PYTHON3" "$SCRIPT") >/dev/null 2>&1 || true

    # Second run (same version -> no notification) / 2回目実行（同バージョン → 通知なし）
    local stdout_output
    stdout_output=$( (WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" MOCK_LATEST_VERSION="v0.0.1-test" "$PYTHON3" "$SCRIPT") 2>/dev/null ) || true
    if [ -z "$stdout_output" ]; then
        pass "Second run with same version produces no notification"
    else
        fail "Second run should produce no notification, got: '$stdout_output'"
    fi

    # Debug で "Same version" が出ることを確認
    local stderr_output
    stderr_output=$( (WORKSPACE="$TEST_TMP_DIR" STATE_FILE="$mock_state" DEBUG_UPDATE_CHECK=1 MOCK_LATEST_VERSION="v0.0.1-test" "$PYTHON3" "$SCRIPT") 2>&1 1>/dev/null ) || true
    if echo "$stderr_output" | grep -q "Same version"; then
        pass "Debug output shows 'Same version' on second run"
    else
        fail "Debug output should show 'Same version', got: '$stderr_output'"
    fi
}

# ============================================================
# Test: show_update_notification outputs correctly per verbosity
# 各詳細度レベルで通知が正しく表示されるか
#
# Loaded directly via importlib (rather than driven black-box through state
# files) for the same precision the bash original had sourcing the script:
# exact line/separator counts and the "no previous version" case, which is
# awkward to reach through the full state-file-driven flow.
# ブラックボックスで状態ファイル経由に組み立てるのではなく、importlibで直接
# ロードする。bash版がスクリプトをsourceしていたのと同じ精度（行数・
# セパレータ数の厳密な検証、状態ファイル駆動のフローからは組み立てにくい
# 「直前バージョンなし」ケース）を保つため。
# ============================================================
test_show_update_notification() {
    echo ""
    echo "=== Testing show_update_notification ==="

    local result
    result=$("$PYTHON3" - "$SCRIPT" <<'PYEOF'
import importlib.util
import io
import sys
from contextlib import redirect_stdout
from pathlib import Path

script_path = sys.argv[1]
sys.path.insert(0, str(Path(script_path).resolve().parent))
spec = importlib.util.spec_from_file_location("check_upstream_updates", script_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

msgs = mod.get_messages(lang_ja=False)
failures = []


def capture(previous, latest, url, verbosity):
    buf = io.StringIO()
    with redirect_stdout(buf):
        mod.show_update_notification(previous, latest, url, verbosity, msgs)
    return buf.getvalue()


# Test 1/2: Quiet mode — single line with version transition, no decoration
out = capture("v0.1.0", "v0.2.0", "https://example.com/releases", "quiet")
if "v0.1.0 → v0.2.0" not in out:
    failures.append(f"quiet mode missing version transition: {out!r}")
if len(out.splitlines()) != 1:
    failures.append(f"quiet mode should be 1 line, got {len(out.splitlines())}: {out!r}")

# Test 3/4/5a-e: Summary mode
out = capture("v0.1.0", "v0.2.0", "https://example.com/releases", "summary")
if not ("v0.1.0" in out and "v0.2.0" in out and "https://example.com/releases" in out):
    failures.append(f"summary mode missing version/url: {out!r}")
if "━━━━" not in out:
    failures.append("summary mode should include separator lines")
if not (msgs["CURRENT"] in out and msgs["LATEST"] in out):
    failures.append("summary mode should show current/latest labels")
non_empty_lines = [line for line in out.splitlines() if line.strip()]
if len(non_empty_lines) < 6:
    failures.append(f"summary mode should have >= 6 non-empty lines, got {len(non_empty_lines)}: {out!r}")
if msgs["RELEASE_NOTES"] not in out:
    failures.append("summary mode should show release notes label")
if out.count("━━━━") < 3:
    failures.append(f"summary mode should have >= 3 separator lines, got {out.count('━━━━')}")
if f"{msgs['HOW_TO_UPDATE']}:" in out:
    failures.append("summary mode should NOT show how-to-update section")

# Test 5/6: Verbose mode
out = capture("v0.1.0", "v0.2.0", "https://example.com/releases", "verbose")
if msgs["HOW_TO_UPDATE"] not in out:
    failures.append(f"verbose mode missing how-to-update section: {out!r}")
if not ("v0.1.0" in out and "v0.2.0" in out):
    failures.append("verbose mode should show both versions")

# Test 7: No previous version — shows latest only, no arrow
out = capture("", "v0.3.0", "https://example.com/releases", "quiet")
if "v0.3.0" not in out or "→" in out:
    failures.append(f"no-previous-version case should show 'v0.3.0' without an arrow: {out!r}")

if failures:
    for f in failures:
        print(f"FAIL::{f}")
else:
    print("ALL_OK")
PYEOF
    )

    if echo "$result" | grep -q "^ALL_OK$"; then
        pass "show_update_notification: quiet/summary/verbose/no-previous-version all correct"
    else
        while IFS= read -r line; do
            case "$line" in
                FAIL::*) fail "${line#FAIL::}" ;;
            esac
        done <<< "$result"
    fi
}

# ============================================================
# Test: Script is executable
# ============================================================
test_script_executable() {
    echo ""
    echo "=== Testing script is executable ==="

    if [ -f "$SCRIPT" ]; then
        pass "check-upstream-updates.py exists"
    else
        fail "check-upstream-updates.py does not exist"
        return
    fi

    if [ -x "$SCRIPT" ]; then
        pass "check-upstream-updates.py is executable"
    else
        fail "check-upstream-updates.py should be executable"
    fi

    # Check shebang
    if head -1 "$SCRIPT" | grep -q "^#!/usr/bin/env python3"; then
        pass "check-upstream-updates.py has correct shebang"
    else
        fail "check-upstream-updates.py should have #!/usr/bin/env python3 shebang"
    fi
}

# ============================================================
# Test: Script runs without error (with CHECK_UPDATES=false)
# ============================================================
test_script_runs() {
    echo ""
    echo "=== Testing script execution ==="

    local exit_code

    # Test 1: Run with CHECK_UPDATES=false via mock config
    local mock_config="$TEST_TMP_DIR/.sandbox/config/template-source.conf"
    cat > "$mock_config" <<'EOF'
TEMPLATE_REPO="YujiSuzuki/ai-sandbox"
CHECK_CHANNEL="all"
CHECK_UPDATES="false"
CHECK_INTERVAL_HOURS="0"
EOF

    (WORKSPACE="$TEST_TMP_DIR" "$PYTHON3" "$SCRIPT" >/dev/null 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        pass "check-upstream-updates.py exits cleanly with CHECK_UPDATES=false"
    else
        fail "check-upstream-updates.py should exit cleanly, got exit code $exit_code"
    fi

    # Test 2: Run with empty TEMPLATE_REPO
    cat > "$mock_config" <<'EOF'
TEMPLATE_REPO=""
CHECK_CHANNEL="all"
CHECK_UPDATES="true"
CHECK_INTERVAL_HOURS="0"
EOF

    (WORKSPACE="$TEST_TMP_DIR" "$PYTHON3" "$SCRIPT" >/dev/null 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        pass "check-upstream-updates.py exits cleanly with empty TEMPLATE_REPO"
    else
        fail "check-upstream-updates.py should exit cleanly with empty TEMPLATE_REPO, got exit code $exit_code"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "Update Check Tests"
    echo "========================================"

    setup

    test_config_file
    test_debug_mode
    test_first_run_no_notification
    test_same_version_no_renotify
    test_show_update_notification
    test_script_executable
    test_script_runs

    teardown

    echo ""
    echo "========================================"
    echo "Test Results"
    echo "========================================"
    echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
    echo ""

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"

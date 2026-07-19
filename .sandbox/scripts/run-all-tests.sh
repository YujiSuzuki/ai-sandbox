#!/bin/bash
# run-all-tests.sh
# Run all test scripts in .sandbox/scripts/
#
# Usage: ./.sandbox/scripts/run-all-tests.sh
#
# Environment: AI Sandbox, or CI (set WORKSPACE to override the default /workspace)
# ---
# .sandbox/scripts/ 内の全テストスクリプトを実行
# 使用方法: ./.sandbox/scripts/run-all-tests.sh
# 実行環境: AI Sandbox、または CI（デフォルトの /workspace を上書きするには WORKSPACE を設定）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
# 出力用の色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color / 色なし

# Language detection based on locale
# ロケールに基づく言語検出
if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    MSG_TITLE="全テスト実行"
    MSG_RESULTS="全体結果: %d/%d スクリプト成功"
    MSG_FAILED_HEADER="失敗したスクリプト:"
    MSG_ALL_PASSED="すべてのテストスクリプトが成功しました！"
    MSG_SKIPPED="スキップ（ホストOS専用、.sandbox/host-setup/と同様このコンテナ内一括実行の対象外）:"
else
    MSG_TITLE="All Tests Runner"
    MSG_RESULTS="Overall Results: %d/%d scripts passed"
    MSG_FAILED_HEADER="Failed scripts:"
    MSG_ALL_PASSED="All test scripts passed!"
    MSG_SKIPPED="Skipped (host-OS-only, excluded from this in-container sweep like .sandbox/host-setup/):"
fi

# Scripts that must run on the host OS, not inside AI Sandbox -- same
# category as .sandbox/host-setup/test-*.sh.
# ホストOS上でのみ実行できるスクリプト -- .sandbox/host-setup/test-*.sh と
# 同じ扱い。
HOST_ONLY_SCRIPTS=("test-confirm-continue.sh")
SKIPPED_SCRIPTS=()

TOTAL=0
PASSED=0
FAILED=0
FAILED_SCRIPTS=()

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}  ${MSG_TITLE}${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for test_script in "$SCRIPT_DIR"/test-*.sh; do
    [ -f "$test_script" ] || continue

    script_name="$(basename "$test_script")"

    # Skip host-OS-only scripts rather than let them fail: they refuse to
    # run inside AI Sandbox by design, so counting that refusal as a
    # failure would make this sweep permanently red when run in-container.
    # ホストOS専用スクリプトは失敗扱いにせずスキップする: 設計上
    # AI Sandbox内では実行を拒否するため、それを失敗としてカウントすると
    # コンテナ内で実行する限り常に赤くなってしまう。
    is_host_only=false
    for host_only in "${HOST_ONLY_SCRIPTS[@]}"; do
        [ "$script_name" = "$host_only" ] && is_host_only=true && break
    done
    if [ "$is_host_only" = true ]; then
        SKIPPED_SCRIPTS+=("$script_name")
        continue
    fi

    TOTAL=$((TOTAL + 1))

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo -e "${BOLD}  ▶ $script_name${NC}"
    echo "══════════════════════════════════════════════════════════════"

    # Special handling for test-advanced-features.sh
    # Run with --basic -y to execute DevContainer-compatible tests (sections 1-4)
    # test-advanced-features.sh は特別扱い
    # --basic -y で DevContainer 互換テスト（セクション1-4）を実行
    if [ "$script_name" = "test-advanced-features.sh" ]; then
        if bash "$test_script" --basic -y; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
            FAILED_SCRIPTS+=("$script_name")
        fi
    else
        if bash "$test_script"; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
            FAILED_SCRIPTS+=("$script_name")
        fi
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# shellcheck disable=SC2059
printf -v results_msg "$MSG_RESULTS" "$PASSED" "$TOTAL"
echo -e "${BOLD}  ${results_msg}${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "${#SKIPPED_SCRIPTS[@]}" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}  ${MSG_SKIPPED}${NC}"
    for s in "${SKIPPED_SCRIPTS[@]}"; do
        echo -e "${YELLOW}    - $s${NC}"
    done
fi

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo -e "${RED}  ${MSG_FAILED_HEADER}${NC}"
    for s in "${FAILED_SCRIPTS[@]}"; do
        echo -e "${RED}    ✗ $s${NC}"
    done
    echo ""
    exit 1
else
    echo ""
    echo -e "${GREEN}  ${MSG_ALL_PASSED}${NC}"
    echo ""
fi

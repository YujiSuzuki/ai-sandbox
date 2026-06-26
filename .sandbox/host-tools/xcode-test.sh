#!/bin/bash
# xcode-test.sh
# Xcode テストをホスト OS（macOS）上で実行する。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# xcresult は常に .sandbox/tmp/<Scheme>-all.xcresult に保存し、
# テスト完了後に xcresulttool で XCTest + Swift Testing の全結果を表示する。
#
# Usage:
#   ./xcode-test.sh [options]
#
# Options:
#   --only <TestClass>       特定のテストクラスのみ実行（例: --only MyFeatureTests）
#   --project <path>         .xcodeproj のパス（未指定時は WORKSPACE_DIR 内を自動検出）
#   --scheme <scheme>        Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --test-target <name>     UT ターゲット名（デフォルト: <scheme>Tests）
#   --no-skip-ui-tests       UI テストもあわせて実行（デフォルト: UI テストはスキップ）
#   --destination <dest>     xcodebuild destination（デフォルト: iOS Simulator, 最新 iPhone）
#   --workspace <path>       ワークスペースルートパス（.project で自動取得できない場合）
#   --help, -h               このヘルプを表示
#
# Examples:
#   ./xcode-test.sh
#   ./xcode-test.sh --only MyFeatureTests
#   ./xcode-test.sh --only "MyFeatureTests/test_something"
#   ./xcode-test.sh --only "MyAppTests/MyFeatureTests"  # TargetName/ClassName 形式でも可
#
# Note: タイムアウトは hostmcp.yaml の host_access.host_tools.timeout で設定する（デフォルト 600 秒）。
#   AI（MCP 経由）が run_host_tool を呼び出す際は per-call でのタイムアウト変更不可。
#
# ⚠️ --only に指定するのはファイル名ではなく Swift の struct 名（@Suite に対応する型名）。
#   ファイル名と struct 名が異なる場合、--only でテストが 0 件になる（エラーにはならない）。
#
#   例: FeatureTests.swift の中に HandleFeatureTests struct がある場合
#     ❌ --only FeatureTests       → 0 件（ファイル名と一致する struct が存在しない）
#     ✅ --only HandleFeatureTests → 正常に実行
#
#   推奨: ファイル名と同名の外枠 struct を作り、内部 struct を入れ子にする（.sandbox/host-tools/README.md 参照）
#
# コマンドラインからの使用例
# hostmcp client --timeout 600 --url http://host.docker.internal:8888 host-tools run xcode-test.sh
#   オプションを渡す時
# hostmcp client --timeout 600 --url http://host.docker.internal:8888 host-tools run xcode-test.sh -- --only MyFeatureTests

set -euo pipefail

# ────────────────────────────────────────────
# カラー出力
# ────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "${BLUE}=== $* ===${NC}"; }

# ────────────────────────────────────────────
# デフォルト値
# ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# .project (HostMCP sync で自動生成される JSON) からワークスペースパスを取得
PROJECT_META="${SCRIPT_DIR}/.project"
WORKSPACE_DIR=""
if [ -f "$PROJECT_META" ]; then
    WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null)
fi

XCODEPROJ=""
SCHEME=""
TEST_TARGET=""
ONLY_TESTING_RAW=""
DESTINATION=""
SKIP_UI_TESTS=true

# ────────────────────────────────────────────
# 引数パース
# ────────────────────────────────────────────
show_help() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            [[ $# -lt 2 ]] && { error "--only requires an argument"; exit 1; }
            ONLY_TESTING_RAW="$2"; shift 2 ;;
        --project)
            [[ $# -lt 2 ]] && { error "--project requires an argument"; exit 1; }
            XCODEPROJ="$2"; shift 2 ;;
        --scheme)
            [[ $# -lt 2 ]] && { error "--scheme requires an argument"; exit 1; }
            SCHEME="$2"; shift 2 ;;
        --test-target)
            [[ $# -lt 2 ]] && { error "--test-target requires an argument"; exit 1; }
            TEST_TARGET="$2"; shift 2 ;;
        --no-skip-ui-tests)
            SKIP_UI_TESTS=false; shift ;;
        --destination)
            [[ $# -lt 2 ]] && { error "--destination requires an argument"; exit 1; }
            DESTINATION="$2"; shift 2 ;;
        --workspace)
            [[ $# -lt 2 ]] && { error "--workspace requires an argument"; exit 1; }
            WORKSPACE_DIR="$2"; shift 2 ;;
        --help|-h)
            show_help ;;
        *)
            error "Unknown option: $1"; exit 1 ;;
    esac
done

# ワークスペースパスの確定
if [ -z "$WORKSPACE_DIR" ]; then
    error "ワークスペースパスを特定できません。"
    error ".project ファイルが存在するか確認するか、--workspace <path> で指定してください。"
    exit 1
fi

# .xcodeproj の解決（未指定時は自動検出）
if [ -z "$XCODEPROJ" ]; then
    XCODEPROJ_LIST=$(find "$WORKSPACE_DIR" -maxdepth 2 -name "*.xcodeproj" -type d 2>/dev/null)
    XCODEPROJ_COUNT=$(echo "$XCODEPROJ_LIST" | grep -c . 2>/dev/null || true)
    if [ "$XCODEPROJ_COUNT" -eq 0 ]; then
        error ".xcodeproj が見つかりません（WORKSPACE_DIR 2階層以内を検索）: ${WORKSPACE_DIR}"
        error "--project で明示指定してください。"
        exit 1
    elif [ "$XCODEPROJ_COUNT" -gt 1 ]; then
        error "複数の .xcodeproj が見つかりました。--project で明示指定してください:"
        echo "$XCODEPROJ_LIST" >&2
        exit 1
    fi
    XCODEPROJ=$(echo "$XCODEPROJ_LIST" | head -1)
fi

# SCHEME の自動導出（.xcodeproj のベース名から）
if [ -z "$SCHEME" ]; then
    SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
fi

# TEST_TARGET の自動導出（<Scheme>Tests）
if [ -z "$TEST_TARGET" ]; then
    TEST_TARGET="${SCHEME}Tests"
fi

# --only の解決（"/" なしの場合は TEST_TARGET を自動補完）
ONLY_TESTING=""
if [ -n "$ONLY_TESTING_RAW" ]; then
    if [[ "$ONLY_TESTING_RAW" != */* ]]; then
        ONLY_TESTING="${TEST_TARGET}/${ONLY_TESTING_RAW}"
    else
        ONLY_TESTING="$ONLY_TESTING_RAW"
    fi
fi

TMP_DIR="${WORKSPACE_DIR}/.sandbox/tmp"
RESULT_BUNDLE="${TMP_DIR}/${SCHEME}-all.xcresult"
LOG_FILE="${TMP_DIR}/xcode-test-last.log"
TIMESTAMP_FILE="${TMP_DIR}/xcode-test.timestamp"

# ────────────────────────────────────────────
# 事前チェック
# ────────────────────────────────────────────
if ! command -v xcodebuild &>/dev/null; then
    error "xcodebuild が見つかりません。Xcode がインストールされているか確認してください。"
    exit 1
fi

if [ ! -d "$XCODEPROJ" ]; then
    error "Xcode プロジェクトが見つかりません: ${XCODEPROJ}"
    exit 1
fi

XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -1 || true)
info "使用 Xcode: ${XCODE_VERSION}"

# destination が未指定の場合、利用可能な最新 iOS の iPhone シミュレーターを自動選択
if [ -z "$DESTINATION" ]; then
    SIM_ID=$(xcrun simctl list devices available -j 2>/dev/null | jq -r '
        .devices
        | to_entries
        | map(select(.key | test("com.apple.CoreSimulator.SimRuntime.iOS")))
        | sort_by(.key) | reverse
        | .[0].value
        | map(select(.name | test("^iPhone")))
        | .[0].udid // ""
    ' 2>/dev/null || true)
    if [ -n "$SIM_ID" ] && [ "$SIM_ID" != "null" ]; then
        DESTINATION="platform=iOS Simulator,id=${SIM_ID}"
        info "シミュレーター自動選択: ${SIM_ID}"
    else
        DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=18.6"
        warn "シミュレーター自動選択失敗。フォールバック: ${DESTINATION}"
    fi
fi

# ────────────────────────────────────────────
# xcodebuild コマンド組み立て
# ────────────────────────────────────────────
header "Xcode テスト実行"
echo "  プロジェクト    : ${XCODEPROJ}"
echo "  スキーム        : ${SCHEME}"
echo "  テストターゲット: ${TEST_TARGET}"
echo "  destination     : ${DESTINATION}"
[ -n "$ONLY_TESTING" ] && echo "  テスト絞り込み  : ${ONLY_TESTING}"
echo ""

CMD=(
    xcodebuild test
    -project "${XCODEPROJ}"
    -scheme "${SCHEME}"
    -destination "${DESTINATION}"
    -parallel-testing-enabled NO
    -maximum-concurrent-test-simulator-destinations 1
    -resultBundlePath "${RESULT_BUNDLE}"
)

if [ "$SKIP_UI_TESTS" = "true" ]; then
    CMD+=(-skip-testing:"${SCHEME}UITests")
fi

if [ -n "$ONLY_TESTING" ]; then
    CMD+=(-only-testing "${ONLY_TESTING}")
fi

# ────────────────────────────────────────────
# テスト実行（同期。出力はログファイルへ）
# ────────────────────────────────────────────
mkdir -p "$TMP_DIR"

# 既存の xcresult を削除（xcodebuild は上書き不可）
if [ -e "$RESULT_BUNDLE" ]; then
    rm -rf "$RESULT_BUNDLE"
fi

date "+%Y-%m-%d %H:%M:%S" > "$TIMESTAMP_FILE"

info "ログ保存先: ${LOG_FILE}"
info "xcodebuild 実行中（完了まで数分かかります）..."
info "（出力はログファイルに書き込みます。完了後に結果を表示します）"

# tee を使うと MCP のバッファが溢れて SIGPIPE が発生し xcodebuild が強制終了する。
# ログファイルへの直接リダイレクトにして SIGPIPE を回避する。
set +e
"${CMD[@]}" > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

# ────────────────────────────────────────────
# 結果表示（xcresulttool で XCTest + Swift Testing の全結果を表示）
# ────────────────────────────────────────────
echo ""
header "テスト結果"

SUMMARY_RAW=$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>&1) || true
SUMMARY=$(echo "$SUMMARY_RAW" | jq 'select(.totalTestCount != null)' 2>/dev/null) || SUMMARY=""
TESTS=$(xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" 2>/dev/null) || TESTS=""

if [ -z "$SUMMARY" ]; then
    # xcresulttool が使えない場合（ビルドエラー等）はログから抽出してフォールバック
    warn "xcresulttool でテスト結果を読み取れませんでした。ログから抽出します。"
    grep -E "(Executed [0-9]+ test|Test Suite '|FAILED|SUCCEEDED)" \
        "$LOG_FILE" 2>/dev/null | tail -20 || true
    echo ""
    if [ "$EXIT_CODE" -eq 0 ]; then
        echo -e "${GREEN}✅ 全テスト PASSED${NC}"
    else
        echo -e "${RED}❌ テスト FAILED（exit code: ${EXIT_CODE}）${NC}"
        grep -E "error:|Error" "$LOG_FILE" 2>/dev/null | head -20 || true
    fi
    exit "$EXIT_CODE"
fi

TOTAL=$(echo "$SUMMARY"  | jq '.totalTestCount // 0') || TOTAL=0
PASSED=$(echo "$SUMMARY" | jq '.passedTests // 0')    || PASSED=0
FAILED=$(echo "$SUMMARY" | jq '.failedTests // 0')    || FAILED=0

echo "  合計  : ${TOTAL}"
echo -e "  PASSED: ${GREEN}${PASSED}${NC}"
echo -e "  FAILED: ${RED}${FAILED}${NC}"
echo ""

if [ "$FAILED" -gt 0 ]; then
    header "失敗したテスト"
    echo "$SUMMARY" | jq -r '
        .testFailures[]? |
        "  ❌ " + (.testName // "unknown")
    ' 2>/dev/null || true
    echo ""

    header "エラー詳細"
    echo "$SUMMARY" | jq -r '
        .testFailures[]? |
        "──────────────────\n  テスト: " + (.testName // "unknown") + "\n  " + (.failureText // "")
    ' 2>/dev/null || true
    echo ""
fi

if [ -n "$TESTS" ]; then
    header "全テスト一覧"
    echo "$TESTS" | jq -r '
        def walk_nodes:
            .[]? |
            if .nodeType == "Test Case" then
                if .result == "Passed" then "  ✅ " + .name
                elif .result == "Failed" then "  ❌ " + .name
                else "  ⚪ " + .name end
            else
                (.children? // [] | walk_nodes)
            end;
        .testNodes | walk_nodes
    ' 2>/dev/null || true
    echo ""
fi

BUILD_FAILED=0
if [ "$EXIT_CODE" -ne 0 ]; then
    BUILD_FAILED=1
fi
grep -q "\*\* TEST FAILED \*\*" "$LOG_FILE" 2>/dev/null && BUILD_FAILED=1 || true

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}❌ ${FAILED} テスト失敗${NC}"
    exit 1
elif [ "$BUILD_FAILED" -eq 1 ]; then
    header "ビルドエラー（テスト未実行）"
    grep -E "error:" "$LOG_FILE" 2>/dev/null | grep -v "^$" | head -30 || true
    echo ""
    echo -e "${RED}❌ ビルドエラーのためテストが実行されませんでした${NC}"
    exit 1
else
    echo -e "${GREEN}✅ 全テスト PASSED (${PASSED}/${TOTAL})${NC}"
    exit 0
fi

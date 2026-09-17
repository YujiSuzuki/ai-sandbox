#!/bin/bash
# xcode-test.sh
# @timeout: 600
# Run Xcode tests on the host OS (macOS).
# Invoked from the container via HostMCP's run_host_tool.
#
# The xcresult is always saved to .sandbox/tmp/<Scheme>-all.xcresult, and
# after the test run xcresulttool prints the full XCTest + Swift Testing results.
#
# Usage:
#   ./xcode-test.sh [options]
#
# Options:
#   --only <TestClass>       Run only a specific test class (e.g. --only MyFeatureTests)
#   --project <path>         Path to the .xcodeproj. Absolute, or relative to WORKSPACE_DIR
#                             (auto-detected under WORKSPACE_DIR if omitted, but only up to
#                             2 levels deep -- pass this explicitly for a project nested
#                             deeper, e.g. inside a sub-repo's own ios/ subdirectory)
#   --scheme <scheme>        Xcode scheme name (default: the .xcodeproj's base name)
#   --test-target <name>     Unit test target name (default: <scheme>Tests). Only matters
#                             when --only has no "/" at all (see WARNING below) -- needed to
#                             filter a UI test class by name alone, since its real target
#                             (<scheme>UITests) differs from this default.
#   --no-skip-ui-tests       Also run UI tests (default: UI tests are skipped)
#   --destination <dest>     xcodebuild destination (default: iOS Simulator, latest iPhone)
#   --clean                  Run `xcodebuild clean test` instead of a plain incremental
#                             test run. Use this when you suspect xcodebuild is reusing
#                             stale build products instead of picking up a source change --
#                             e.g. a symptom like "CoreData: warning: Multiple
#                             NSEntityDescriptions claim the NSManagedObject subclass ..." in
#                             the output, or a test you just added reporting 0 executed
#                             tests with no compile steps in the log even though the class
#                             itself is found. Takes noticeably longer (a full rebuild, not
#                             incremental) -- raise --timeout / client_timeout_seconds to
#                             match if the default 600s isn't enough (see the two-layer
#                             timeout note below).
#   --help, -h               Show this help
#
# Examples:
#   ./xcode-test.sh
#   ./xcode-test.sh --project myapp/ios/MyApp.xcodeproj  # relative to WORKSPACE_DIR; needed
#                                                         # when nested deeper than auto-detect's 2 levels
#   ./xcode-test.sh --clean  # force a full rebuild if stale build products are suspected
#   ./xcode-test.sh --only MyFeatureTests
#   ./xcode-test.sh --only "MyFeatureTests/test_something"
#   ./xcode-test.sh --only "MyAppTests/MyFeatureTests"  # TargetName/ClassName form also works
#
# Note: this script declares its own timeout as 600s via the "@timeout: 600"
#   header (hostmcp.yaml's global default is host_access.host_tools.timeout,
#   60s; rather than raising that shared default, this tool extends its own
#   timeout individually). The declaration only takes effect once approved
#   via `hostmcp tools sync`, and is clamped to hostmcp.yaml's
#   host_access.host_tools.max_tool_timeout (default 1800s). When invoking
#   via MCP's run_host_tool, pass client_timeout_seconds (a separate layer
#   from this header's @timeout) to raise the client-side wait to match --
#   see README.md for the two-layer explanation.
#
# WARNING: --only takes a Swift struct name (the type matching @Suite), not a
#   filename. If the filename and struct name differ, --only silently matches
#   0 tests instead of erroring.
#
#   Example: a HandleFeatureTests struct inside FeatureTests.swift
#     WRONG:   --only FeatureTests       -> 0 tests (no struct matches the filename)
#     CORRECT: --only HandleFeatureTests -> runs normally
#
#   Recommended: wrap tests in an outer struct named after the file, with inner nested structs
#   (see .sandbox/host-tools/README.md).
#
# WARNING (XCTest, e.g. UI test targets): to run a single test *method*, all
#   three segments -- Target/Class/Method -- are required. This script's
#   auto-prefixing only adds the target when --only has no "/" at all; once you
#   add one "/", the two segments you give are passed straight through, and
#   xcodebuild's -only-testing: always reads the first of those as the target.
#   That's harmless when the class name differs from the target name (the
#   2-segment "Class/Method" form then falls back to being read correctly) --
#   but a UI test class is conventionally named the same as its target (e.g.
#   class MyAppUITests inside target MyAppUITests), and there the 2-segment
#   form is read as Target/Class instead, silently matching 0 tests.
#
#   This is also where --test-target actually matters: with a single-segment
#   --only (no "/" at all, e.g. --only MyFeatureUITests to run a whole UI test
#   class), auto-prefixing builds "${TEST_TARGET}/${value}" -- pass
#   --test-target explicitly, since the default (<scheme>Tests) won't match a
#   UI test target's real name (<scheme>UITests) and silently matches 0 tests.
#
#   Example: testSomething() inside class MyAppUITests, target MyAppUITests
#     WRONG:   --test-target MyAppUITests --only "MyAppUITests/testSomething"
#              -> 0 tests (read as Target=MyAppUITests / Class=testSomething)
#     CORRECT: --test-target MyAppUITests --only "MyAppUITests/MyAppUITests/testSomething"
#
#   Put together, running one UI test method inside a project nested deeper
#   than auto-detect's 2 levels (see --project above) needs --project
#   (auto-detect won't find it), --no-skip-ui-tests (UI tests are skipped by
#   default), and the 3-segment --only -- --test-target is not required here
#   since a fully-qualified 3-segment --only bypasses auto-prefixing entirely:
#     ./xcode-test.sh --project myapp/ios/MyApp.xcodeproj --no-skip-ui-tests \
#       --only "MyAppUITests/MyAppUITests/testSomething"
#
# Command-line usage example
#
# Note that the `hostmcp client --timeout 600` below is a separate layer from
# the header's "@timeout: 600" declaration above. `--timeout` is how long the
# client waits for the HTTP response (hostmcp's own implementation:
# internal/cli/client.go), independent of the host-side execution time limit
# that force-kills the tool (what the header's @timeout declaration governs).
# Extending the server side via @timeout doesn't help if the client's
# --timeout stays short -- the client gives up waiting first -- so both need
# to be raised together, to roughly 600.
# hostmcp client --timeout 600 --url http://host.docker.internal:18080 host-tools run xcode-test.sh
#   When passing options:
# hostmcp client --timeout 600 --url http://host.docker.internal:18080 host-tools run xcode-test.sh -- --only MyFeatureTests

# ---
# xcode-test.sh
# @timeout: 600
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
#   --project <path>         .xcodeproj のパス。絶対パス、または WORKSPACE_DIR からの相対パス
#                             （未指定時は WORKSPACE_DIR 内を自動検出するが、深さ2階層までしか
#                             探索しない -- サブリポジトリの ios/ 配下など、それより深い場所に
#                             ある場合は明示的に指定すること）
#   --scheme <scheme>        Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --test-target <name>     UT ターゲット名（デフォルト: <scheme>Tests）。意味を持つのは
#                             --only に「/」が一切ない場合のみ（下のWARNING参照）-- UIテスト
#                             クラスをクラス名だけで絞り込む際、実際のターゲット名
#                             （<scheme>UITests）がこのデフォルトと異なるため必要になる。
#   --no-skip-ui-tests       UI テストもあわせて実行（デフォルト: UI テストはスキップ）
#   --destination <dest>     xcodebuild destination（デフォルト: iOS Simulator, 最新 iPhone）
#   --clean                  素の増分テスト実行の代わりに `xcodebuild clean test` を実行する。
#                             ソースの変更をxcodebuildが拾えず古いビルド成果物を使い回して
#                             いる疑いがある時に使う -- 例えば出力に「CoreData: warning:
#                             Multiple NSEntityDescriptions claim the NSManagedObject
#                             subclass ...」のような症状が出ている、追加したばかりのテスト
#                             が「0件実行」と報告されクラス自体は見つかっているのにログに
#                             コンパイル関連の行が一つもない、などのサイン。フルリビルド
#                             になるため明確に時間が長くなる -- デフォルトの600秒で足りない
#                             場合は --timeout / client_timeout_seconds も合わせて延ばす
#                             こと（下記の二層タイムアウトの説明を参照）。
#   --help, -h               このヘルプを表示
#
# Examples:
#   ./xcode-test.sh
#   ./xcode-test.sh --project myapp/ios/MyApp.xcodeproj  # WORKSPACE_DIR からの相対パス。
#                                                         # 自動検出の2階層より深い場合に必要
#   ./xcode-test.sh --clean  # 古いビルド成果物が疑われる時にフルリビルドを強制する
#   ./xcode-test.sh --only MyFeatureTests
#   ./xcode-test.sh --only "MyFeatureTests/test_something"
#   ./xcode-test.sh --only "MyAppTests/MyFeatureTests"  # TargetName/ClassName 形式でも可
#
# Note: このスクリプトはヘッダーの「@timeout: 600」で自身のタイムアウトを
#   600秒に宣言している（hostmcp.yamlのグローバル既定値は host_access.host_tools.timeout
#   で60秒。全ツール共通のこの既定値を上げる代わりに、このツールだけ個別に延長する
#   仕組み）。この宣言は `hostmcp tools sync` で承認されて初めて有効になり、
#   hostmcp.yamlの host_access.host_tools.max_tool_timeout（既定1800秒）を超える
#   宣言はクランプされる。MCP の run_host_tool 経由で呼び出す場合は、
#   client_timeout_seconds（このヘッダーの @timeout とは別レイヤー）を渡すことで
#   クライアント側の待機時間も合わせて延ばせる（二層構造の詳細は README.md 参照）。
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
# ⚠️ XCTest（UIテストターゲットなど）: 特定のテスト*メソッド*を1つだけ実行するには
#   Target/Class/Method の3段すべてが必要。このスクリプトの自動プレフィックスは
#   --only に「/」が一切ない場合にのみターゲット名を補うので、「/」を1つでも
#   含めた時点で、渡した2つのセグメントはそのまま xcodebuild に渡り、
#   -only-testing: はその最初のセグメントを常にターゲット名として解釈する。
#   クラス名とターゲット名が異なる場合は無害（2段の「Class/Method」形式でも
#   結果的に正しく解釈される）が、UIテストのクラスは慣習的にターゲットと
#   同じ名前になる（例: ターゲット MyAppUITests の中のクラス MyAppUITests）ため、
#   その場合は2段形式が Target/Class として解釈されてしまい、テストが黙って0件になる。
#
#   --test-target が実際に意味を持つのもここ: 「/」を一切含まない単一セグメントの
#   --only（例: UIテストクラスを丸ごと実行する --only MyFeatureUITests）では、
#   自動プレフィックスが "${TEST_TARGET}/${値}" を組み立てるため、--test-target を
#   明示的に指定すること -- デフォルト（<scheme>Tests）はUIテストターゲットの
#   実際の名前（<scheme>UITests）と一致せず、黙って0件になる。
#
#   例: クラス MyAppUITests（ターゲット MyAppUITests）内の testSomething()
#     ❌ --test-target MyAppUITests --only "MyAppUITests/testSomething"
#        → 0件（Target=MyAppUITests / Class=testSomething と解釈される）
#     ✅ --test-target MyAppUITests --only "MyAppUITests/MyAppUITests/testSomething"
#
#   組み合わせると、自動検出の2階層より深い場所にあるプロジェクト（上の --project 参照）で
#   UIテストのメソッドを1つだけ実行するには、--project（自動検出が届かない）、
#   --no-skip-ui-tests（UIテストはデフォルトでスキップされる）、3段の --only が必要になる --
#   3段すべて指定した --only は自動プレフィックス処理を経由しないため、--test-target は不要:
#     ./xcode-test.sh --project myapp/ios/MyApp.xcodeproj --no-skip-ui-tests \
#       --only "MyAppUITests/MyAppUITests/testSomething"
#
# コマンドラインからの使用例
#
# 下記の `hostmcp client --timeout 600` は、上記のヘッダー宣言「@timeout: 600」とは
# 別レイヤーの設定である点に注意。`--timeout` はクライアントがHTTP応答を待つ時間
# （hostmcp本体の実装: internal/cli/client.go）で、ホスト側でツールを強制終了する
# 実行時間制限（ヘッダーの@timeout宣言が対象とするもの）とは独立している。
# サーバー側を@timeout宣言で延ばしても、クライアント側の--timeoutが短いままだと
# クライアントが先に応答待ちを諦めてしまうため、両方を揃えて600程度にする必要がある。
# hostmcp client --timeout 600 --url http://host.docker.internal:18080 host-tools run xcode-test.sh
#   オプションを渡す時
# hostmcp client --timeout 600 --url http://host.docker.internal:18080 host-tools run xcode-test.sh -- --only MyFeatureTests

set -euo pipefail

# ────────────────────────────────────────────
# Color output
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
# Defaults
# ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get the workspace path from .project (a JSON file auto-generated by HostMCP sync)
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
CLEAN=false

# ────────────────────────────────────────────
# Argument parsing
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
        --clean)
            CLEAN=true; shift ;;
        --help|-h)
            show_help ;;
        *)
            error "Unknown option: $1"; exit 1 ;;
    esac
done

# Resolve the workspace path
if [ -z "$WORKSPACE_DIR" ]; then
    error "Cannot determine the workspace path."
    error "Check that a .project file exists."
    exit 1
fi

# Resolve .xcodeproj (auto-detect if not specified)
if [ -z "$XCODEPROJ" ]; then
    XCODEPROJ_LIST=$(find "$WORKSPACE_DIR" -maxdepth 2 -name "*.xcodeproj" -type d 2>/dev/null)
    XCODEPROJ_COUNT=$(echo "$XCODEPROJ_LIST" | grep -c . 2>/dev/null || true)
    if [ "$XCODEPROJ_COUNT" -eq 0 ]; then
        error "No .xcodeproj found (searched up to 2 levels under WORKSPACE_DIR): ${WORKSPACE_DIR}"
        error "Specify one explicitly with --project."
        exit 1
    elif [ "$XCODEPROJ_COUNT" -gt 1 ]; then
        error "Multiple .xcodeproj found. Specify one explicitly with --project:"
        echo "$XCODEPROJ_LIST" >&2
        exit 1
    fi
    XCODEPROJ=$(echo "$XCODEPROJ_LIST" | head -1)
fi

# Derive SCHEME automatically (from the .xcodeproj's base name)
if [ -z "$SCHEME" ]; then
    SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
fi

# Derive TEST_TARGET automatically (<Scheme>Tests)
if [ -z "$TEST_TARGET" ]; then
    TEST_TARGET="${SCHEME}Tests"
fi

# Resolve --only (auto-prefix with TEST_TARGET if it has no "/")
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
# Preflight checks
# ────────────────────────────────────────────
if ! command -v xcodebuild &>/dev/null; then
    error "xcodebuild not found. Check that Xcode is installed."
    exit 1
fi

if [ ! -d "$XCODEPROJ" ]; then
    error "Xcode project not found: ${XCODEPROJ}"
    exit 1
fi

XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -1 || true)
info "Using Xcode: ${XCODE_VERSION}"

# If --destination isn't specified, auto-select the latest available iOS iPhone simulator
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
        info "Auto-selected simulator: ${SIM_ID}"
    else
        DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=18.6"
        warn "Simulator auto-selection failed. Falling back to: ${DESTINATION}"
    fi
fi

# ────────────────────────────────────────────
# Build the xcodebuild command
# ────────────────────────────────────────────
header "Running Xcode tests"
echo "  Project        : ${XCODEPROJ}"
echo "  Scheme         : ${SCHEME}"
echo "  Test target    : ${TEST_TARGET}"
echo "  Destination    : ${DESTINATION}"
[ -n "$ONLY_TESTING" ] && echo "  Filter         : ${ONLY_TESTING}"
[ "$CLEAN" = "true" ] && echo "  Clean          : yes (full rebuild)"
echo ""

CMD=(xcodebuild)
[ "$CLEAN" = "true" ] && CMD+=(clean)
CMD+=(
    test
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
# Run tests (synchronous; output goes to a log file)
# ────────────────────────────────────────────
mkdir -p "$TMP_DIR"

# Remove any existing xcresult (xcodebuild refuses to overwrite one)
if [ -e "$RESULT_BUNDLE" ]; then
    rm -rf "$RESULT_BUNDLE"
fi

date "+%Y-%m-%d %H:%M:%S" > "$TIMESTAMP_FILE"

info "Log: ${LOG_FILE}"
info "Running xcodebuild (this can take a few minutes)..."
info "(Output is written to the log file; results are shown once it finishes)"

# Piping through tee overflows MCP's buffer and triggers SIGPIPE, which kills
# xcodebuild. Redirect straight to the log file instead to avoid SIGPIPE.
set +e
"${CMD[@]}" > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

# ────────────────────────────────────────────
# Show results (xcresulttool prints full XCTest + Swift Testing results)
# ────────────────────────────────────────────
echo ""
header "Test results"

SUMMARY_RAW=$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>&1) || true
SUMMARY=$(echo "$SUMMARY_RAW" | jq 'select(.totalTestCount != null)' 2>/dev/null) || SUMMARY=""
TESTS=$(xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" 2>/dev/null) || TESTS=""

if [ -z "$SUMMARY" ]; then
    # If xcresulttool can't produce a summary (e.g. a build error), fall back to extracting from the log
    warn "Could not read test results via xcresulttool. Extracting from the log instead."
    grep -E "(Executed [0-9]+ test|Test Suite '|FAILED|SUCCEEDED)" \
        "$LOG_FILE" 2>/dev/null | tail -20 || true
    echo ""
    if [ "$EXIT_CODE" -eq 0 ]; then
        echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
    else
        echo -e "${RED}❌ TESTS FAILED (exit code: ${EXIT_CODE})${NC}"
        grep -E "error:|Error" "$LOG_FILE" 2>/dev/null | head -20 || true
    fi
    exit "$EXIT_CODE"
fi

TOTAL=$(echo "$SUMMARY"  | jq '.totalTestCount // 0') || TOTAL=0
PASSED=$(echo "$SUMMARY" | jq '.passedTests // 0')    || PASSED=0
FAILED=$(echo "$SUMMARY" | jq '.failedTests // 0')    || FAILED=0

echo "  Total : ${TOTAL}"
echo -e "  PASSED: ${GREEN}${PASSED}${NC}"
echo -e "  FAILED: ${RED}${FAILED}${NC}"
echo ""

if [ "$FAILED" -gt 0 ]; then
    header "Failed tests"
    echo "$SUMMARY" | jq -r '
        .testFailures[]? |
        "  ❌ " + (.testName // "unknown")
    ' 2>/dev/null || true
    echo ""

    header "Failure details"
    echo "$SUMMARY" | jq -r '
        .testFailures[]? |
        "──────────────────\n  Test: " + (.testName // "unknown") + "\n  " + (.failureText // "")
    ' 2>/dev/null || true
    echo ""
fi

if [ -n "$TESTS" ]; then
    header "All tests"
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
    echo -e "${RED}❌ ${FAILED} test(s) failed${NC}"
    exit 1
elif [ "$BUILD_FAILED" -eq 1 ]; then
    header "Build error (tests did not run)"
    grep -E "error:" "$LOG_FILE" 2>/dev/null | grep -v "^$" | head -30 || true
    echo ""
    echo -e "${RED}❌ Tests did not run because of a build error${NC}"
    exit 1
else
    echo -e "${GREEN}✅ ALL TESTS PASSED (${PASSED}/${TOTAL})${NC}"
    exit 0
fi

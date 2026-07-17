#!/bin/bash
# run-host-setup-tests.sh
# .sandbox/host-setup/test-*.sh をホスト OS 上で実行する（汎用ランナー）。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# .sandbox/host-setup/ 配下のテストは実ネットワーク・実 go/curl・実シェル設定ファイルを
# 必要とするため AI Sandbox コンテナ内では実行できない（各テストスクリプト自身が
# /workspace の存在をチェックしてガードしている）。このラッパーは
# HostMCP 経由でホスト OS 上に実行を委譲する。デフォルトでは host-setup/ 配下の
# test-*.sh を全部実行し、--test-script で1つに絞ることもできる。
#
# Usage:
#   ./run-host-setup-tests.sh
#   ./run-host-setup-tests.sh --test-script test-install-hostmcp.sh
#   ./run-host-setup-tests.sh --workspace <path>
#
# Options:
#   --test-script <name>  host-setup/ 配下の特定のテストファイル名のみ実行（省略時は全件）
#   --workspace <path>    ワークスペースルートパス（.project で自動取得できない場合）
#   --help, -h             このヘルプを表示
#
# コマンドラインからの使用例
# hostmcp client --url http://host.docker.internal:18080 host-tools run run-host-setup-tests.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# .project (HostMCP sync で自動生成される JSON) からワークスペースパスを取得
PROJECT_META="${SCRIPT_DIR}/.project"
WORKSPACE_DIR=""
if [ -f "$PROJECT_META" ]; then
    WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null)
fi

TEST_SCRIPT_FILTER=""

show_help() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test-script)
            [[ $# -lt 2 ]] && { error "--test-script requires an argument"; exit 1; }
            TEST_SCRIPT_FILTER="$2"; shift 2 ;;
        --workspace)
            [[ $# -lt 2 ]] && { error "--workspace requires an argument"; exit 1; }
            WORKSPACE_DIR="$2"; shift 2 ;;
        --help|-h)
            show_help ;;
        *)
            error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$WORKSPACE_DIR" ]; then
    error "ワークスペースパスを特定できません。"
    error ".project ファイルが存在するか確認するか、--workspace <path> で指定してください。"
    exit 1
fi

HOST_SETUP_DIR="${WORKSPACE_DIR}/.sandbox/host-setup"
if [ ! -d "$HOST_SETUP_DIR" ]; then
    error "host-setup ディレクトリが見つかりません: $HOST_SETUP_DIR"
    exit 1
fi

# 実行対象テストスクリプトの一覧を作成
# Plain bash globbing on purpose (not `find ... -print0 | sort -z`): macOS's
# default BSD sort has no -z/--zero-terminated option, so that pipeline
# silently produced zero results there even though the same command worked
# fine in this Linux container's GNU sort during authoring. Bash's own glob
# expansion is already lexically sorted and portable across both.
# あえて素の bash グロブを使用（`find ... -print0 | sort -z` ではなく）:
# macOS標準のBSD sortには -z/--zero-terminated オプションがなく、作成時に
# 動作確認したLinuxコンテナのGNU sortでは通っても、実行先のmacOSでは
# サイレントに0件になっていた。bashのグロブ展開自体が辞書順でソート済みかつ
# 両OSで一貫して動く。
declare -a TEST_SCRIPTS=()
if [ -n "$TEST_SCRIPT_FILTER" ]; then
    # --test-script must be a bare filename matching the test-*.sh convention —
    # host-setup/ also contains non-test scripts (e.g. install-hostmcp.sh), and
    # without this check this "test runner" host tool could be used to execute
    # any of them instead of a test.
    # --test-script はtest-*.sh規則に一致する単純なファイル名のみ許可する —
    # host-setup/ にはinstall-hostmcp.shのようなテスト以外のスクリプトも存在し、
    # このチェックがないと「テストランナー」であるはずのこのホストツールで
    # テスト以外の任意のスクリプトを実行できてしまう。
    case "$TEST_SCRIPT_FILTER" in
        */*)
            error "無効な --test-script 指定です（パス区切りは使用できません）: $TEST_SCRIPT_FILTER"
            exit 1
            ;;
        test-*.sh) ;;
        *)
            error "無効な --test-script 指定です（test-*.sh という名前のファイルのみ指定できます）: $TEST_SCRIPT_FILTER"
            exit 1
            ;;
    esac
    candidate="${HOST_SETUP_DIR}/${TEST_SCRIPT_FILTER}"
    if [ ! -f "$candidate" ]; then
        error "テストスクリプトが見つかりません: $candidate"
        exit 1
    fi
    TEST_SCRIPTS=("$candidate")
else
    for f in "$HOST_SETUP_DIR"/test-*.sh; do
        [ -f "$f" ] && TEST_SCRIPTS+=("$f")
    done
fi

if [ "${#TEST_SCRIPTS[@]}" -eq 0 ]; then
    error "実行対象のテストスクリプトが見つかりません（${HOST_SETUP_DIR}/test-*.sh）。"
    exit 1
fi

LOG_DIR="${WORKSPACE_DIR}/.sandbox/tmp"
mkdir -p "$LOG_DIR"

info "Impact / 影響範囲: creates/overwrites log files under ${LOG_DIR}/*-output.log; each invoked test suite also creates and removes several mktemp -d temp directories (fake \$HOME, mock PATH dirs) on the host during the run"
info "Impact / 影響範囲: ${LOG_DIR}/*-output.log にログファイルを作成（上書き）します。各テストスイート自体も、実行中にホスト上で mktemp -d による一時ディレクトリ（偽の \$HOME やモック PATH）を複数作成・削除します"
info "Risk / リスク: Low - only local temp files/dirs (all self-cleaned by the test suites), no ports or processes left running"
info "Risk / リスク: 低 - ローカルの一時ファイル・ディレクトリのみ（テストスイートが自ら後片付け）。ポートやプロセスは残りません"
info "Recovery / 失敗時の対処法: rm -f ${LOG_DIR}/*-output.log"

overall_exit=0
declare -a RESULTS=()

for test_script in "${TEST_SCRIPTS[@]}"; do
    name="$(basename "$test_script" .sh)"
    out_log="${LOG_DIR}/${name}-output.log"

    info "Running: $test_script"
    # tee を使うと MCP のバッファが溢れて SIGPIPE が発生しテストスイートが強制終了する。
    # ログファイルへの直接リダイレクトにして SIGPIPE を回避する。
    set +e
    bash "$test_script" > "$out_log" 2>&1
    test_exit=$?
    set -e

    if [ "$test_exit" -ne 0 ]; then
        error "FAILED: $name (exit code: $test_exit) — full log: $out_log"
        echo "--- summary line from $out_log ---"
        # || true: a crash before the test script prints its own summary/assertions
        # (e.g. syntax error) means these greps match nothing; under set -e + pipefail
        # an unguarded exit 1 here would kill this runner itself mid-loop.
        grep -E "passed,|failed" "$out_log" | tail -n 5 || true
        echo "--- failing assertions (❌) from $out_log ---"
        grep -B2 -A4 "❌" "$out_log" || true
        RESULTS+=("FAIL  $name")
        overall_exit=1
    else
        info "PASSED: $name"
        RESULTS+=("PASS  $name")
    fi
done

echo ""
info "=== Summary ==="
for r in "${RESULTS[@]}"; do
    info "$r"
done

if [ "$overall_exit" -ne 0 ]; then
    error "Recovery / 失敗時の対処法: rm -f ${LOG_DIR}/*-output.log"
fi

exit "$overall_exit"

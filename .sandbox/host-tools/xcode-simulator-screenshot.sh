#!/bin/bash
# @timeout: 300
# xcode-simulator-screenshot.sh
# Build an iOS app, install + launch it on a Simulator, and capture a
# screenshot to a path under WORKSPACE_DIR so it can be read from the
# container (the shared workspace mount is the only channel back to the AI;
# there is no other way to see what's on the host's screen).
# Invoked from the container via HostMCP's run_host_tool.
#
# Usage:
#   ./xcode-simulator-screenshot.sh [options]
#
# Options:
#   --project <path>      Path to the .xcodeproj (auto-detected under WORKSPACE_DIR if omitted)
#   --scheme <scheme>     Xcode scheme name (default: the .xcodeproj's base name)
#   --output <path>       Screenshot output path, relative to WORKSPACE_DIR (default: tmp/simulator-screenshot.png)
#   --wait <seconds>      Seconds to wait after launch before capturing (default: 3)
#   --help, -h            Show this help
#
# Examples:
#   ./xcode-simulator-screenshot.sh
#   ./xcode-simulator-screenshot.sh --scheme Umakuiku --output tmp/home.png

# ---
# xcode-simulator-screenshot.sh
# iOSアプリをビルドし、シミュレータにインストール・起動した上でスクリーンショットを撮り、
# WORKSPACE_DIR配下のパスに保存する（共有ワークスペースのマウントだけが、AIに結果を
# 見せられる唯一の経路。ホストの画面を他の方法で見る手段は無い）。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# Usage:
#   ./xcode-simulator-screenshot.sh [options]
#
# Options:
#   --project <path>      .xcodeproj のパス（未指定時は WORKSPACE_DIR 内を自動検出）
#   --scheme <scheme>     Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --output <path>       スクリーンショットの保存先。WORKSPACE_DIR からの相対パス（デフォルト: tmp/simulator-screenshot.png）
#   --wait <seconds>      起動後、撮影までの待機秒数（デフォルト: 3）
#   --help, -h            このヘルプを表示
#
# Examples:
#   ./xcode-simulator-screenshot.sh
#   ./xcode-simulator-screenshot.sh --scheme Umakuiku --output tmp/home.png

set -euo pipefail

# ────────────────────────────────────────────
# Color output / カラー出力
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
# Path validation helper / パス検証ヘルパー
# ────────────────────────────────────────────
# HostMCP doesn't validate arguments once a Host Tool is approved, so this
# check is the only line of defense confirming that the output path stays
# within WORKSPACE_DIR.
# HostMCP は Host Tool 承認後の引数を検証しないため、出力先パスが WORKSPACE_DIR
# 配下に収まっているかどうかは、このチェックが唯一の防衛線になる。
require_within() {
    local target="$1" base="$2" label="$3"
    local resolved_base resolved_target
    resolved_base="$(cd "$base" 2>/dev/null && pwd -P)" || { error "${label}: 基点ディレクトリが解決できません: ${base}"; exit 1; }
    resolved_target="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || { error "${label}: パスが解決できません: ${target}"; exit 1; }
    case "$resolved_target" in
        "$resolved_base"|"$resolved_base"/*) ;;
        *)
            error "${label} が許可された範囲外です: ${target}"
            error "許可範囲: ${resolved_base} 配下のみ"
            exit 1
            ;;
    esac
}

# ────────────────────────────────────────────
# Defaults / デフォルト値
# ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_META="${SCRIPT_DIR}/.project"
WORKSPACE_DIR=""
if [ -f "$PROJECT_META" ]; then
    WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null) || WORKSPACE_DIR=""
fi

XCODEPROJ=""
SCHEME=""
OUTPUT_REL="tmp/simulator-screenshot.png"
WAIT_SECONDS=3

# ────────────────────────────────────────────
# Argument parsing / 引数パース
# ────────────────────────────────────────────
show_help() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            [[ $# -lt 2 ]] && { error "--project requires an argument"; exit 1; }
            XCODEPROJ="$2"; shift 2 ;;
        --scheme)
            [[ $# -lt 2 ]] && { error "--scheme requires an argument"; exit 1; }
            SCHEME="$2"; shift 2 ;;
        --output)
            [[ $# -lt 2 ]] && { error "--output requires an argument"; exit 1; }
            OUTPUT_REL="$2"; shift 2 ;;
        --wait)
            [[ $# -lt 2 ]] && { error "--wait requires an argument"; exit 1; }
            WAIT_SECONDS="$2"; shift 2 ;;
        --help|-h)
            show_help ;;
        *)
            error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$WORKSPACE_DIR" ]; then
    error "ワークスペースパスを特定できません。"
    error ".project ファイルが存在するか確認してください。"
    exit 1
fi

# 出力先が ".." を含んで WORKSPACE_DIR 外を指せてしまわないよう、相対パス指定に限定する。
case "$OUTPUT_REL" in
    /*|*..*)
        error "--output は WORKSPACE_DIR からの相対パスで指定してください（'..'や絶対パスは不可）: ${OUTPUT_REL}"
        exit 1
        ;;
esac
OUTPUT_PATH="${WORKSPACE_DIR}/${OUTPUT_REL}"

# .xcodeproj の解決（未指定時は自動検出)
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

# require_within は cd による解決を要するため、まだ存在しないディレクトリには使えない。
# シンボリックリンク越しに WORKSPACE_DIR 外へ mkdir -p してしまわないよう、実在する
# 最も近い祖先ディレクトリを先に require_within で検証してから mkdir -p し、最後に
# 出力先パス自体を改めて require_within で検証する（xcode-install-app.sh と同じ手順）。
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
EXISTING_ANCESTOR="$OUTPUT_DIR"
while [ ! -d "$EXISTING_ANCESTOR" ]; do
    EXISTING_ANCESTOR="$(dirname "$EXISTING_ANCESTOR")"
done
require_within "${EXISTING_ANCESTOR}/." "$WORKSPACE_DIR" "--output"
mkdir -p "$OUTPUT_DIR"
require_within "$OUTPUT_PATH" "$WORKSPACE_DIR" "--output"

if [ -z "$SCHEME" ]; then
    SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
fi

# ────────────────────────────────────────────
# Preflight checks / 事前チェック
# ────────────────────────────────────────────
for bin in xcodebuild xcrun jq; do
    if ! command -v "$bin" &>/dev/null; then
        error "${bin} が見つかりません。"
        exit 1
    fi
done

if [ ! -d "$XCODEPROJ" ]; then
    error "Xcode プロジェクトが見つかりません: ${XCODEPROJ}"
    exit 1
fi

# ────────────────────────────────────────────
# Pick a simulator (same selection logic as xcode-build.sh) / シミュレーター選択
# ────────────────────────────────────────────
SIM_ID=$(xcrun simctl list devices available -j 2>/dev/null | jq -r '
    .devices
    | to_entries
    | map(select(.key | test("com.apple.CoreSimulator.SimRuntime.iOS")))
    | sort_by(.key) | reverse
    | .[0].value
    | map(select(.name | test("^iPhone")))
    | .[0].udid // ""
' 2>/dev/null || true)

if [ -z "$SIM_ID" ] || [ "$SIM_ID" = "null" ]; then
    error "利用可能なiOSシミュレーターが見つかりませんでした。"
    exit 1
fi
info "シミュレーター: ${SIM_ID}"
DESTINATION="platform=iOS Simulator,id=${SIM_ID}"

# ────────────────────────────────────────────
# Build / ビルド
# ────────────────────────────────────────────
header "Xcode ビルド実行"
LOG_FILE="${WORKSPACE_DIR}/tmp/xcode-simulator-screenshot-build.log"
mkdir -p "${WORKSPACE_DIR}/tmp"
info "ログ保存先: ${LOG_FILE}"

set +e
xcodebuild build \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -destination "${DESTINATION}" \
    > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
    error "BUILD FAILED (exit code: ${EXIT_CODE})"
    grep -E "error:" "$LOG_FILE" | head -40 || true
    exit $EXIT_CODE
fi
info "BUILD SUCCEEDED"

# ────────────────────────────────────────────
# Resolve build product & bundle id / ビルド成果物とバンドルIDの解決
# ────────────────────────────────────────────
SETTINGS_JSON=$(xcodebuild -showBuildSettings -json \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -destination "${DESTINATION}" 2>/dev/null)

TARGET_SETTINGS=$(echo "$SETTINGS_JSON" | jq -c --arg t "$SCHEME" \
    '([.[] | select(.target == $t)] + .)[0].buildSettings // {}')

BUILT_PRODUCTS_DIR=$(echo "$TARGET_SETTINGS" | jq -r '.BUILT_PRODUCTS_DIR // empty')
WRAPPER_NAME=$(echo "$TARGET_SETTINGS" | jq -r '.WRAPPER_NAME // empty')
BUNDLE_ID=$(echo "$TARGET_SETTINGS" | jq -r '.PRODUCT_BUNDLE_IDENTIFIER // empty')

if [ -z "$BUILT_PRODUCTS_DIR" ] || [ -z "$WRAPPER_NAME" ] || [ -z "$BUNDLE_ID" ]; then
    error "ビルド成果物・バンドルIDを特定できませんでした。"
    exit 1
fi

APP_PATH="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
if [ ! -d "$APP_PATH" ]; then
    error "ビルド成果物が見つかりません: ${APP_PATH}"
    exit 1
fi

# ────────────────────────────────────────────
# Boot, install, launch, capture / 起動・インストール・起動・撮影
# ────────────────────────────────────────────
header "シミュレーターで起動・撮影"
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1 || true
xcrun simctl install "$SIM_ID" "$APP_PATH"
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" >/dev/null

info "${WAIT_SECONDS}秒待機して描画を待ちます..."
sleep "$WAIT_SECONDS"

xcrun simctl io "$SIM_ID" screenshot "$OUTPUT_PATH"

info "スクリーンショット保存先: ${OUTPUT_PATH}"
exit 0

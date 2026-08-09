#!/bin/bash
# xcode-install-app.sh
# macOS アプリをビルドし、DerivedData 配下のランダムなハッシュパスから
# 既知の固定ディレクトリ（デフォルト: ~/.hostmcp/Applications）へコピーする。
# コンテナ側からは常に同じパスでビルド成果物を参照できるようにするためのツール。
# HostMCP の run_host_tool 経由でコンテナから呼び出す。
#
# Usage:
#   ./xcode-install-app.sh [options]
#
# Options:
#   --project <path>         .xcodeproj のパス（未指定時は WORKSPACE_DIR 内を自動検出）
#   --scheme <scheme>        Xcode スキーム名（デフォルト: .xcodeproj のベース名）
#   --configuration <cfg>    ビルド構成（デフォルト: Debug）
#   --dest-dir <path>        インストール先ディレクトリ（デフォルト: ~/.hostmcp/Applications）
#   --workspace <path>       ワークスペースルートパス（.project で自動取得できない場合）
#   --help, -h               このヘルプを表示
#
# Examples:
#   ./xcode-install-app.sh --project AirDropStatus/AirDropStatus.xcodeproj
#   ./xcode-install-app.sh --scheme AirDropStatus --dest-dir ~/.hostmcp/Applications

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
# パス検証ヘルパー
# ────────────────────────────────────────────
# HostMCP は Host Tool 承認後の引数を検証しないため、rm -rf 等の対象パスが
# 想定範囲に収まっているかどうかは、このチェックが唯一の防衛線になる。
require_within() {
    local target="$1" base="$2" label="$3"
    local resolved_base resolved_target
    resolved_base="$(cd "$base" 2>/dev/null && pwd -P)" || { error "${label}: 基点ディレクトリが解決できません: ${base}"; exit 1; }
    resolved_target="$(cd "$target" 2>/dev/null && pwd -P)" || { error "${label}: パスが解決できません: ${target}"; exit 1; }
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
# デフォルト値
# ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_META="${SCRIPT_DIR}/.project"
WORKSPACE_DIR=""
WORKSPACE_FROM_PROJECT_META=false
if [ -f "$PROJECT_META" ]; then
    # `|| WORKSPACE_DIR=""` を付けないと、.project が壊れたJSONの場合に jq が非ゼロ終了し、
    # set -e でここで無言のまま終了してしまう（後段の親切なエラーメッセージに到達しない）。
    WORKSPACE_DIR=$(jq -r '.workspace // ""' "$PROJECT_META" 2>/dev/null) || WORKSPACE_DIR=""
    [ -n "$WORKSPACE_DIR" ] && WORKSPACE_FROM_PROJECT_META=true
fi

XCODEPROJ=""
SCHEME=""
CONFIGURATION="Debug"
DEST_DIR="${HOME}/.hostmcp/Applications"

# ────────────────────────────────────────────
# 引数パース
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
        --configuration)
            [[ $# -lt 2 ]] && { error "--configuration requires an argument"; exit 1; }
            CONFIGURATION="$2"; shift 2 ;;
        --dest-dir)
            [[ $# -lt 2 ]] && { error "--dest-dir requires an argument"; exit 1; }
            DEST_DIR="$2"; shift 2 ;;
        --workspace)
            [[ $# -lt 2 ]] && { error "--workspace requires an argument"; exit 1; }
            # .project は HostMCP が自動生成する信頼済みの値なので、CLI引数による
            # 上書きを許すと --project の require_within チェックが無意味になる
            # （--workspace と --project を両方好きに指定できてしまうため）。
            if [ "$WORKSPACE_FROM_PROJECT_META" = true ]; then
                error "--workspace は .project に既に設定されているため上書きできません: ${WORKSPACE_DIR}"
                exit 1
            fi
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

# --project でホスト上の無関係なプロジェクトを指定されると、Build Phase 経由で
# 任意コード実行を許すことになるため、WORKSPACE_DIR 配下であることを必須にする。
require_within "$XCODEPROJ" "$WORKSPACE_DIR" "--project"

XCODE_VERSION=$(set +o pipefail; xcodebuild -version 2>/dev/null | head -1 || echo "unknown")
info "使用 Xcode: ${XCODE_VERSION}"

DESTINATION="platform=macOS"

# ────────────────────────────────────────────
# ビルド実行
# ────────────────────────────────────────────
header "Xcode ビルド実行"
echo "  プロジェクト : ${XCODEPROJ}"
echo "  スキーム     : ${SCHEME}"
echo "  構成         : ${CONFIGURATION}"
echo "  destination  : ${DESTINATION}"
echo ""

LOG_FILE="${WORKSPACE_DIR}/tmp/xcode-install-app-last.log"
mkdir -p "${WORKSPACE_DIR}/tmp"
info "ログ保存先: ${LOG_FILE}"
info "xcodebuild 実行中（完了まで数分かかります）..."

set +e
xcodebuild build \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    > "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
    header "ビルド失敗"
    grep -E "error:" "$LOG_FILE" | head -60 || true
    error "BUILD FAILED (exit code: ${EXIT_CODE})"
    error "ログ: ${LOG_FILE}"
    exit $EXIT_CODE
fi
info "BUILD SUCCEEDED"

# ────────────────────────────────────────────
# ビルド成果物のパスを取得
# ────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    error "jq が見つかりません。"
    exit 1
fi

SETTINGS_ERR_FILE="${WORKSPACE_DIR}/tmp/xcode-install-app-settings-err.log"

set +e
SETTINGS_JSON=$(xcodebuild -showBuildSettings -json \
    -project "${XCODEPROJ}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" 2>"$SETTINGS_ERR_FILE")
SETTINGS_EXIT=$?
set -e

if [ $SETTINGS_EXIT -ne 0 ]; then
    error "ビルド設定の取得に失敗しました(exit code: ${SETTINGS_EXIT})。"
    tail -20 "$SETTINGS_ERR_FILE" >&2 2>/dev/null || true
    exit $SETTINGS_EXIT
fi

# -showBuildSettings -json はスキームがビルドする全ターゲット分(メインアプリ＋
# 組み込みExtension/Widget/Framework等)の要素を返すため、先頭要素をそのまま
# 使うとメインアプリ以外の設定を拾う場合がある。SCHEME名と一致するターゲットを
# 優先し、一致がなければ先頭要素にフォールバックする。
TARGET_SETTINGS=$(echo "$SETTINGS_JSON" | jq -c --arg t "$SCHEME" \
    '([.[] | select(.target == $t)] + .)[0].buildSettings // {}')

BUILT_PRODUCTS_DIR=$(echo "$TARGET_SETTINGS" | jq -r '.BUILT_PRODUCTS_DIR // empty')
WRAPPER_NAME=$(echo "$TARGET_SETTINGS" | jq -r '.WRAPPER_NAME // empty')

if [ -z "$BUILT_PRODUCTS_DIR" ] || [ -z "$WRAPPER_NAME" ]; then
    error "ビルド成果物のパスを特定できませんでした（BUILT_PRODUCTS_DIR/WRAPPER_NAME）。"
    exit 1
fi

# WRAPPER_NAME はこの後 DEST_DIR と結合してコピー先パスを組み立てる。ビルド
# 設定由来の値をそのままパス結合に使うと、"/"や".."を含む値でコピー先
# ディレクトリの外に書き込めてしまうため、単一のファイル/ディレクトリ名
# であることを要求する。"."も単体で許すと DEST_APP が DEST_DIR 自身と
# 一致し、直後の rsync --delete が DEST_DIR 配下を丸ごと消してしまうため拒否する。
case "$WRAPPER_NAME" in
    */*|*..*|.)
        error "ビルド成果物名(WRAPPER_NAME)が不正です: ${WRAPPER_NAME}"
        exit 1
        ;;
esac

SRC_APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
if [ ! -d "$SRC_APP" ]; then
    error "ビルド成果物が見つかりません: ${SRC_APP}"
    exit 1
fi

# ────────────────────────────────────────────
# 固定ディレクトリへコピー
# ────────────────────────────────────────────
header "インストール"
# require_within は cd による解決を要するため、まだ存在しないディレクトリには使えない。
# mkdir -p で作成してしまう前に、$HOME 配下かどうかを文字列レベルで先に弾く。
# 文字列マッチはパスを正規化しないため、"$HOME/../../tmp/evil" のような ".." を含む値は
# "$HOME"/* パターンにそのまま一致してしまう。mkdir -p の前に ".." を明示的に拒否しておく。
case "$DEST_DIR" in
    *..*)
        error "--dest-dir に '..' を含めることはできません: ${DEST_DIR}"
        exit 1
        ;;
esac
case "$DEST_DIR" in
    "$HOME"|"$HOME"/*) ;;
    *)
        error "--dest-dir が許可された範囲外です: ${DEST_DIR}"
        error "許可範囲: ${HOME} 配下のみ"
        exit 1
        ;;
esac
# $DEST_DIR 配下にシンボリックリンクが仕込まれていると、mkdir -p 自体がそれを辿って
# $HOME 外にディレクトリを作成してしまう（作成後の require_within では防げない副作用）。
# それを防ぐため、実在する最も近い祖先ディレクトリを先に require_within で検証してから
# mkdir -p する（$HOME 自体は必ず存在するため、このループは必ず停止する）。
EXISTING_ANCESTOR="$DEST_DIR"
while [ ! -d "$EXISTING_ANCESTOR" ]; do
    EXISTING_ANCESTOR="$(dirname "$EXISTING_ANCESTOR")"
done
require_within "$EXISTING_ANCESTOR" "$HOME" "--dest-dir"
mkdir -p "$DEST_DIR"
# --dest-dir を無検証で rsync / open に渡すと任意パス破壊につながるため、
# $HOME 配下であることを必須にする（作成後の最終確認）。
require_within "$DEST_DIR" "$HOME" "--dest-dir"
DEST_APP="${DEST_DIR}/${WRAPPER_NAME}"
# DEST_DIR 自体が $HOME 配下であっても、DEST_APP（rsync の実際の書き込み先）が
# シンボリックリンクだった場合、rsync --delete はリンクを辿ってリンク先の中身を
# 削除してしまう（DEST_DIR の検証では防げない）。WRAPPER_NAME の文字列チェックは
# パス区切りや ".." を弾くだけで、その名前の場所に何が存在するかは見ていないため、
# ここで別途シンボリックリンクの有無を確認する。
if [ -L "$DEST_APP" ]; then
    error "コピー先が既にシンボリックリンクです: ${DEST_APP}"
    error "安全のため、シンボリックリンクへのインストールは拒否します。手動で削除してから再実行してください。"
    exit 1
fi

info "コピー元: ${SRC_APP}"
info "コピー先: ${DEST_APP}"

# コピー元に存在しないファイルはコピー先から取り除き（--delete）、常に新しいビルドと
# 完全に一致した状態にする。cp では新旧が混在した状態になりうる（cp -R は、コピー先に
# 同名ディレクトリが既にあると中にネストしてコピーしてしまい、末尾ドット指定で中身を
# 上書きしても新ビルドにないファイルは残ってしまう）。
if ! command -v rsync &>/dev/null; then
    error "rsync が見つかりません。"
    exit 1
fi
rsync -a --delete "${SRC_APP}/" "${DEST_APP}/"

info "インストール完了: ${DEST_APP}"
info "起動する場合は手動で: open \"${DEST_APP}\""

exit 0

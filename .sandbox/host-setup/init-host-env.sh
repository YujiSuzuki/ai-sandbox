#!/bin/bash
# init-host-env.sh
# Host-side initialization: language/timezone selection, env files from
# templates, and host OS info.
#
# Interactive mode: prompts for language (English/Japanese) and, when
# Japanese is selected, timezone (Asia/Tokyo default). At the end, if
# HostMCP isn't configured yet, it also offers to hand off to
# install-hostmcp.sh.
#
# Architecture conversion: x86_64→amd64, aarch64→arm64 for cross-build compatibility
#
# Usage:
#   Interactive (default): init-host-env.sh [project_root]
#   Silent (startup):      init-host-env.sh --silent [project_root]
#                          init-host-env.sh -s [project_root]
#
# This script is called from:
#   - cli_sandbox/_common.sh (CLI sandbox startup) — with --silent
#   - .devcontainer/devcontainer.json initializeCommand (DevContainer startup) — with --silent
#
# Writes host OS info to .sandbox/.host-os for cross-build support (used by hostmcp/Makefile build-host)
# Must run on the host OS — refuses to run inside the AI Sandbox container (see guard below).
# @env: host
# ---
# ホスト側の初期化: 言語/タイムゾーン選択、テンプレートからのenvファイル作成、ホストOS情報の書き出し。
#
# 対話モード: 言語（英語/日本語）を確認し、日本語選択時はタイムゾーン（デフォルト Asia/Tokyo）も確認する。
# 最後に、HostMCPが未設定であれば install-hostmcp.sh への引き継ぎも提案する。
#
# 使用法:
#   対話式（デフォルト）: init-host-env.sh [project_root]
#   サイレント（起動時）: init-host-env.sh --silent [project_root]
#                         init-host-env.sh -s [project_root]
#
# クロスビルド用にホストOS情報を .sandbox/.host-os に書き出す
# ホストOS上で実行する必要があります — AI Sandbox コンテナ内では実行を拒否します（下記ガード参照）。

set -euo pipefail

# Refuse to run inside the AI Sandbox container — this script writes host OS
# info to .sandbox/.host-os for cross-build use (see header), which would be
# silently corrupted with the container's own OS/arch if run from inside it.
# Note: $SANDBOX_ENV is NOT a reliable signal here — it can be exported on
# the HOST shell too (cli_sandbox/_common.sh sets it before invoking this
# script, and a user could also `export SANDBOX_ENV=...` manually outside
# any container), so its presence alone doesn't prove we're inside one.
# /.dockerenv is Docker's own marker file, created only inside a container.
# AI Sandbox コンテナ内では実行を拒否する — このスクリプトはクロスビルド用に
# ホストOS情報を .sandbox/.host-os に書き出すため（ヘッダー参照）、コンテナ内で
# 実行するとコンテナ自身のOS/アーキテクチャで情報が黙って上書きされてしまう。
# 注意: $SANDBOX_ENV はここでは判定に使えない — ホストOS側のシェルでも
# 設定されうる値のため（cli_sandbox/_common.sh がこのスクリプトを呼び出す前に
# 設定する場合や、ユーザーが手動で export した場合も含む）、
# これが設定されているだけではコンテナ内にいる証拠にならない。
# /.dockerenv は Docker がコンテナ内にのみ作成する専用のマーカーファイル。
if [[ -f "/.dockerenv" ]]; then
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        echo "❌ このスクリプトは AI Sandbox コンテナ内では実行できません。" >&2
        echo "" >&2
        echo "ホストOS上のターミナルから実行してください:" >&2
        echo "  .sandbox/host-setup/init-host-env.sh" >&2
    else
        echo "❌ This script cannot be run inside the AI Sandbox container." >&2
        echo "" >&2
        echo "Please run it from a terminal on the host OS:" >&2
        echo "  .sandbox/host-setup/init-host-env.sh" >&2
    fi
    exit 1
fi

# Parse arguments / 引数のパース
INTERACTIVE=true
PROJECT_ROOT="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--silent)
            INTERACTIVE=false
            shift
            ;;
        -h|--help)
            echo "Usage: init-host-env.sh [--silent] [project_root]"
            echo "  -s, --silent  Silent mode: skip interactive prompts (used on startup)"
            echo "                サイレントモード: 対話をスキップ（起動時自動実行用）"
            echo "  project_root  Project root directory (default: current directory)"
            echo "                プロジェクトルート（デフォルト: カレントディレクトリ）"
            exit 0
            ;;
        *)
            PROJECT_ROOT="$1"
            shift
            ;;
    esac
done

created=0
SELECTED_LANG=""
SELECTED_TZ=""

# Output a message in the selected language / 選択した言語でメッセージを出力する
msg() {
    local en="$1"
    local ja="$2"
    if [ "$SELECTED_LANG" = "ja_JP.UTF-8" ]; then
        echo "$ja"
    else
        echo "$en"
    fi
}

# Interactive language selection / 対話式の言語選択
# (Always bilingual — language not yet known)
select_language() {
    echo ""
    echo "Select language / 言語を選択してください:"
    echo "  1) English (default)"
    echo "  2) 日本語"
    echo ""
    read -r -p "Enter 1 or 2 [1]: " choice
    case "$choice" in
        2)
            SELECTED_LANG="ja_JP.UTF-8"
            echo "→ 日本語 (ja_JP.UTF-8) を選択しました"
            echo ""
            # Prompt for timezone when Japanese is selected
            # 日本語選択時にタイムゾーンを確認
            select_timezone_for_japanese
            ;;
        *)
            SELECTED_LANG="C.UTF-8"
            echo "→ Selected English (C.UTF-8)"
            ;;
    esac
    echo ""
}

# Interactive timezone selection for Japanese users / 日本語ユーザー向けタイムゾーン選択
# (Only called after Japanese is selected, so Japanese-only messages are correct)
select_timezone_for_japanese() {
    echo "タイムゾーンを Asia/Tokyo に設定しますか?"
    echo "  1) はい (default)"
    echo "  2) いいえ"
    echo ""
    read -r -p "1 または 2 を入力 [1]: " tz_choice
    case "$tz_choice" in
        2)
            echo "→ タイムゾーンは変更しません"
            ;;
        *)
            SELECTED_TZ="Asia/Tokyo"
            echo "→ TZ=Asia/Tokyo を設定します"
            ;;
    esac
}

# Canonical OS name for hostmcp binary filenames and cross-build info (.host-os)
# MINGW/MSYS/CYGWIN (git-bash etc.) report their own uname, not "windows"
# hostmcpバイナリのファイル名・クロスビルド情報(.host-os)用に正規化したOS名を返す
# MINGW/MSYS/CYGWIN（git-bash等）は "windows" ではなく独自の uname を返すため
_detect_os_name() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) uname -s | tr '[:upper:]' '[:lower:]' ;;
    esac
}

# Apply language setting to .env.sandbox / .env.sandbox に言語設定を適用
apply_language_setting() {
    local env_file="$1"
    if [ -n "$SELECTED_LANG" ] && [ -f "$env_file" ]; then
        # Replace LANG= line with selected language
        if grep -q "^LANG=" "$env_file"; then
            # Use temp file for portability (BSD sed vs GNU sed)
            local tmp_file
            tmp_file=$(mktemp)
            sed "s/^LANG=.*/LANG=$SELECTED_LANG/" "$env_file" > "$tmp_file"
            mv "$tmp_file" "$env_file"
        else
            echo "LANG=$SELECTED_LANG" >> "$env_file"
        fi
    fi
}

# Apply timezone setting to .env.sandbox / .env.sandbox にタイムゾーン設定を適用
apply_timezone_setting() {
    local env_file="$1"
    if [ -n "$SELECTED_TZ" ] && [ -f "$env_file" ]; then
        if grep -q "^# *TZ=" "$env_file"; then
            # Uncomment and set TZ line / コメントアウトされた TZ 行を有効化
            local tmp_file
            tmp_file=$(mktemp)
            sed "s|^# *TZ=.*|TZ=$SELECTED_TZ|" "$env_file" > "$tmp_file"
            mv "$tmp_file" "$env_file"
        elif grep -q "^TZ=" "$env_file"; then
            # Replace existing TZ line / 既存の TZ 行を置換
            local tmp_file
            tmp_file=$(mktemp)
            sed "s|^TZ=.*|TZ=$SELECTED_TZ|" "$env_file" > "$tmp_file"
            mv "$tmp_file" "$env_file"
        else
            # Append TZ line / TZ 行を追加
            echo "TZ=$SELECTED_TZ" >> "$env_file"
        fi
    fi
}

# In interactive mode, prompt for language selection
# 対話モードの場合、言語選択を行う
if [ "$INTERACTIVE" = true ]; then
    select_language
fi

# --- .env.sandbox ---
env_sandbox_created=false
if [ ! -f "$PROJECT_ROOT/.env.sandbox" ]; then
    if [ -f "$PROJECT_ROOT/.env.sandbox.example" ]; then
        cp "$PROJECT_ROOT/.env.sandbox.example" "$PROJECT_ROOT/.env.sandbox"
        msg "Created .env.sandbox from .env.sandbox.example (first-time setup)" \
            ".env.sandbox.example から .env.sandbox を作成しました（初回セットアップ）"
        created=$((created + 1))
        env_sandbox_created=true
    else
        touch "$PROJECT_ROOT/.env.sandbox"
        msg "Created empty .env.sandbox (.env.sandbox.example not found)" \
            ".env.sandbox.example が見つからないため、空の .env.sandbox を作成しました"
        created=$((created + 1))
        env_sandbox_created=true
    fi
elif [ "$INTERACTIVE" = true ]; then
    msg ".env.sandbox already exists." ".env.sandbox は既に存在します。"
    _update_prompt=$(msg "Update language setting? [y/N]: " "言語設定を更新しますか? [y/N]: ")
    read -r -p "$_update_prompt" update_lang || true
    if [[ "$update_lang" =~ ^[Yy] ]]; then
        env_sandbox_created=true
    fi
fi

# Apply language setting if selected / 言語設定を適用
if [ "$env_sandbox_created" = true ] && [ -n "$SELECTED_LANG" ]; then
    apply_language_setting "$PROJECT_ROOT/.env.sandbox"
    msg "  Language set to: $SELECTED_LANG" "  言語を設定しました: $SELECTED_LANG"
fi
# Apply timezone setting if selected / タイムゾーン設定を適用
if [ "$env_sandbox_created" = true ] && [ -n "$SELECTED_TZ" ]; then
    apply_timezone_setting "$PROJECT_ROOT/.env.sandbox"
    msg "  Timezone set to: $SELECTED_TZ" "  タイムゾーンを設定しました: $SELECTED_TZ"
fi
if [ "$env_sandbox_created" = true ]; then
    msg "  Edit .env.sandbox to customize." "  設定変更は .env.sandbox を編集してください。"
    echo ""
fi

# --- cli_sandbox/.env ---
if [ -d "$PROJECT_ROOT/cli_sandbox" ] && [ ! -f "$PROJECT_ROOT/cli_sandbox/.env" ]; then
    if [ -f "$PROJECT_ROOT/cli_sandbox/.env.example" ]; then
        cp "$PROJECT_ROOT/cli_sandbox/.env.example" "$PROJECT_ROOT/cli_sandbox/.env"
        msg "Created cli_sandbox/.env from cli_sandbox/.env.example (first-time setup)" \
            "cli_sandbox/.env.example から cli_sandbox/.env を作成しました（初回セットアップ）"
        msg "  Edit cli_sandbox/.env to customize." "  設定変更は cli_sandbox/.env を編集してください。"
        echo ""
        created=$((created + 1))
    else
        touch "$PROJECT_ROOT/cli_sandbox/.env"
        msg "Created empty cli_sandbox/.env (cli_sandbox/.env.example not found)" \
            "cli_sandbox/.env.example が見つからないため、空の cli_sandbox/.env を作成しました"
        echo ""
        created=$((created + 1))
    fi
fi

if [ "$created" -gt 0 ]; then
    msg "--- $created env file(s) initialized. These files are git-ignored. ---" \
        "--- $created 個の環境変数ファイルを初期化しました。これらのファイルは git 管理対象外です。 ---"
    echo ""
fi

# Write host OS info for cross-build (used by hostmcp/Makefile build-host)
# クロスビルド用にホストOS情報を書き出し（hostmcp/Makefile build-host で使用）
HOST_OS_FILE="$PROJECT_ROOT/.sandbox/.host-os"
mkdir -p "$(dirname "$HOST_OS_FILE")"
_detect_os_name > "$HOST_OS_FILE"
uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/' >> "$HOST_OS_FILE"

# Offer to hand off to install-hostmcp.sh if HostMCP isn't set up yet. This
# script only invokes it (never inlines its logic — see header), so
# install-hostmcp.sh remains the single place that owns HostMCP
# install/init/update, whether reached from here or run directly.
# HostMCPが未設定の場合、install-hostmcp.shへの引き継ぎを提案する。このスクリプトは
# 呼び出すだけでロジックはインライン化しない（ヘッダー参照）ため、ここから実行しても
# 直接実行しても、HostMCPのインストール/init/更新を担うのは常に install-hostmcp.sh のみ。
if [ "$INTERACTIVE" = true ] && [ ! -f "$PROJECT_ROOT/.sandbox/config/hostmcp.yaml" ]; then
    echo ""
    _install_hostmcp_prompt=$(msg "Install and configure HostMCP now? [y/N]: " "HostMCPを今すぐインストール・設定しますか？ [y/N]: ")
    read -r -p "$_install_hostmcp_prompt" install_hostmcp_choice || true
    if [[ "$install_hostmcp_choice" =~ ^[Yy] ]]; then
        _INIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        "$_INIT_SCRIPT_DIR/install-hostmcp.sh" "$PROJECT_ROOT"
    else
        msg "To install and configure HostMCP later, run:" "後でHostMCPをインストール・設定するには、以下を実行してください:"
        echo "  .sandbox/host-setup/install-hostmcp.sh"
    fi
fi

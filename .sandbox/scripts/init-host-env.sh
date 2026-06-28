#!/bin/bash
# init-host-env.sh
# Host-side initialization: create env files from templates and write host OS info
#
# Timezone behavior: Only offered when Japanese is selected (Asia/Tokyo default)
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
# ---
# ホスト側の初期化: テンプレートからenvファイル作成、ホストOS情報の書き出し
#
# 使用法:
#   対話式（デフォルト）: init-host-env.sh [project_root]
#   サイレント（起動時）: init-host-env.sh --silent [project_root]
#                         init-host-env.sh -s [project_root]
#
# クロスビルド用にホストOS情報を .sandbox/.host-os に書き出す

set -euo pipefail

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
DKMCP_AVAILABLE=false
DKMCP_INIT_SUCCESS=false
_DKMCP_CANCELLED=false

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

# SIGINT handler for hostmcp setup / hostmcp セットアップ中の SIGINT ハンドラー
_hostmcp_sigint_handler() {
    echo ""
    msg "Installation cancelled." "インストールをキャンセルしました。"
    _DKMCP_CANCELLED=true
}

# hostmcp install check / hostmcp インストール確認
setup_hostmcp_install() {
    trap '_hostmcp_sigint_handler' INT

    if ! command -v go > /dev/null 2>&1; then
        echo ""
        msg "Error: go command not found." "エラー: go コマンドが見つかりません。"
        msg "Go is required to install hostmcp." "hostmcp をインストールするには Go が必要です。"
        msg "Please install Go from https://go.dev/doc/install" "https://go.dev/doc/install を参照してインストールしてください。"
        return 0
    fi

    local gopath_raw
    if ! gopath_raw=$(go env GOPATH 2>/dev/null); then
        echo ""
        msg "Could not get GOPATH. Check \`go env GOPATH\`." "GOPATH が取得できません。\`go env GOPATH\` を確認してください。"
        return 0
    fi
    if [ -z "$gopath_raw" ]; then
        gopath_raw="$HOME/go"
    fi
    local gopath_bin="$gopath_raw/bin"

    if [ -f "$gopath_bin/hostmcp" ]; then
        DKMCP_AVAILABLE=true
        return 0
    fi

    echo ""
    msg "hostmcp not found. Install it?" "hostmcp が見つかりません。インストールしますか？"
    msg "  1) Yes (run go install github.com/YujiSuzuki/hostmcp@latest)" "  1) はい (go install github.com/YujiSuzuki/hostmcp@latest を実行)"
    msg "  2) No" "  2) いいえ"
    echo ""
    local _prompt
    _prompt=$(msg "Enter 1 or 2 [1]: " "1 または 2 を入力 [1]: ")
    read -r -p "$_prompt" install_choice || true
    if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi

    case "$install_choice" in
        2)
            local display_path
            display_path="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd)" || display_path="/path/to/your-workspace"
            echo ""
            msg "Skipped HostMCP setup." "HostMCP のセットアップをスキップしました。"
            msg "To set up later, run:" "後からセットアップするには以下を実行してください:"
            echo "  go install github.com/YujiSuzuki/hostmcp@latest"
            echo "  hostmcp init --workspace $display_path"
            echo "  hostmcp serve --workspace $display_path"
            return 0
            ;;
        *)
            msg "Installing... (go install github.com/YujiSuzuki/hostmcp@latest)" "インストール中... (go install github.com/YujiSuzuki/hostmcp@latest)"
            if ! go install github.com/YujiSuzuki/hostmcp@latest 2>&1; then
                if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi
                msg "Error: Failed to install hostmcp. To install manually: go install github.com/YujiSuzuki/hostmcp@latest" \
                    "エラー: hostmcp のインストールに失敗しました。手動でインストールする場合: go install github.com/YujiSuzuki/hostmcp@latest"
                return 0
            fi
            if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi
            if [ ! -f "$gopath_bin/hostmcp" ]; then
                msg "Error: Failed to install hostmcp. To install manually: go install github.com/YujiSuzuki/hostmcp@latest" \
                    "エラー: hostmcp のインストールに失敗しました。手動でインストールする場合: go install github.com/YujiSuzuki/hostmcp@latest"
                return 0
            fi
            msg "hostmcp installation complete." "hostmcp のインストールが完了しました。"
            DKMCP_AVAILABLE=true
            ;;
    esac
}

# hostmcp init (port selection + execution) / ポート確認・hostmcp init 実行
setup_hostmcp_init() {
    if [ "$DKMCP_AVAILABLE" != true ]; then return 0; fi

    local abs_project_root
    if ! abs_project_root="$(cd "$PROJECT_ROOT" && pwd)"; then
        echo ""
        msg "Error: Cannot resolve project root path. Skipping hostmcp setup." \
            "エラー: プロジェクトルートのパスを解決できません。hostmcp セットアップをスキップします。"
        return 0
    fi

    if [ -f "$abs_project_root/.sandbox/config/hostmcp.yaml" ]; then
        DKMCP_INIT_SUCCESS=skipped
        show_hostmcp_next_steps "$abs_project_root"
        return 0
    fi

    echo ""
    msg "Generating HostMCP configuration file." "HostMCP の設定ファイルを生成します。"
    msg "Use the default port (18080)?" "ポートはデフォルト（18080）でよいですか？"
    msg "  1) Yes (default)" "  1) はい (default)"
    msg "  2) No (specify custom port)" "  2) いいえ（カスタムポートを指定）"
    echo ""
    local _prompt
    _prompt=$(msg "Enter 1 or 2 [1]: " "1 または 2 を入力 [1]: ")
    read -r -p "$_prompt" port_choice || true
    if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi

    local port=""
    if [ "$port_choice" = "2" ]; then
        local retry=0
        while [ $retry -lt 3 ]; do
            local _port_prompt
            _port_prompt=$(msg "Enter port number (1024-65535): " "ポート番号を入力してください（1024–65535）: ")
            read -r -p "$_port_prompt" port_input || true
            if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi

            if [ -z "$port_input" ]; then
                port=""
                break
            fi

            if ! echo "$port_input" | grep -qE '^[0-9]+$'; then
                msg "Invalid port number. Enter an integer (1-65535):" "無効なポート番号です。整数（1〜65535）を入力してください:"
                retry=$((retry + 1))
                continue
            fi

            local port_num=$((port_input + 0))
            if [ "$port_num" -le 0 ] || [ "$port_num" -ge 65536 ]; then
                msg "Invalid port number. Enter an integer (1-65535):" "無効なポート番号です。整数（1〜65535）を入力してください:"
                retry=$((retry + 1))
                continue
            fi

            if [ "$port_num" -le 1023 ]; then
                msg "Warning: Port $port_num may require administrator privileges." "警告: ポート $port_num は管理者権限が必要な場合があります。"
            fi

            port="$port_input"
            break
        done

        if [ $retry -ge 3 ]; then
            msg "Failed to enter port number. Using default port (18080)." "ポート番号の入力に失敗しました。デフォルトポート（18080）を使用します。"
            port=""
        fi
    fi

    local init_exit=0
    if [ -n "$port" ]; then
        hostmcp init --workspace "$abs_project_root" --port "$port" 2>&1 || init_exit=$?
    else
        hostmcp init --workspace "$abs_project_root" 2>&1 || init_exit=$?
    fi

    if [ $init_exit -ne 0 ]; then
        echo ""
        msg "Error: Failed to generate HostMCP configuration file." "エラー: HostMCP の設定ファイル生成に失敗しました。"
        msg "If an incomplete config file remains, delete it manually:" "不完全な設定ファイルが残っている場合は手動で削除してください:"
        echo "  rm .sandbox/config/hostmcp.yaml"
        msg "Then run init-host-env.sh again." "その後、再度 init-host-env.sh を実行してください。"
        return 0
    fi

    DKMCP_INIT_SUCCESS=true
    show_hostmcp_next_steps "$abs_project_root"
}

# Show next steps after hostmcp setup / hostmcp セットアップ後の次ステップ案内
show_hostmcp_next_steps() {
    local workspace_path="$1"

    local message_en message_ja
    case "$DKMCP_INIT_SUCCESS" in
        true)    message_en="HostMCP setup complete.";               message_ja="HostMCP のセットアップが完了しました。" ;;
        skipped) message_en="HostMCP configuration already exists."; message_ja="HostMCP の設定ファイルは既に存在します。" ;;
        *)       return 0 ;;
    esac

    echo "========================================"
    msg "$message_en" "$message_ja"
    echo "----------------------------------------"
    echo ""
    msg "Next steps:" "次のステップ:"
    echo ""
    msg "1. Start HostMCP (keep this terminal open):" "1. HostMCP を起動（このターミナルは開いたままにしてください）:"
    echo "     hostmcp serve --workspace '$workspace_path'"
    echo ""
    msg "2. Open this folder in VS Code:" "2. VS Code でこのフォルダを開く:"
    echo "     cd '$workspace_path' && code ."
    echo ""
    msg "3. When prompted, click [Reopen in Container]" "3. 表示されるダイアログで [コンテナーで再度開く] をクリック"
    msg "   (or: Cmd+Shift+P → \"Reopen in Container\")" "   （または: Cmd+Shift+P → \"コンテナーで再度開く\"）"
    echo "----------------------------------------"
    echo ""
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
    setup_hostmcp_install
    setup_hostmcp_init
    trap - INT
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
    read -r -p "$_update_prompt" update_lang
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
uname -s | tr '[:upper:]' '[:lower:]' > "$HOST_OS_FILE"
uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/' >> "$HOST_OS_FILE"

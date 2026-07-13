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
# Must run on the host OS — refuses to run inside the AI Sandbox container (see guard below).
# @env: host
# ---
# ホスト側の初期化: テンプレートからenvファイル作成、ホストOS情報の書き出し
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

# Fetch latest hostmcp version tag from GitHub Releases
_fetch_hostmcp_version() {
    local version_url version=""
    if command -v curl > /dev/null 2>&1; then
        version_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            "https://github.com/YujiSuzuki/hostmcp/releases/latest" 2>/dev/null) || true
        version=$(printf '%s' "$version_url" | sed 's|.*/tag/||' | tr -d '[:space:]')
    elif command -v wget > /dev/null 2>&1; then
        version=$(wget --server-response --spider -q \
            "https://github.com/YujiSuzuki/hostmcp/releases/latest" 2>&1 \
            | grep -i 'location:' | tail -1 \
            | sed 's|.*/tag/||' | tr -d '[:space:]') || true
    fi
    case "$version" in
        v*.*.*) printf '%s' "$version" ;;
        *)      ;;
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

# Download hostmcp binary from GitHub Releases / GitHub Releases からバイナリをダウンロード
_download_hostmcp_binary() {
    local version="${1:-}"
    local install_dir="$2"
    local os arch filename install_path url download_ok

    os=$(_detect_os_name)
    arch=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
    filename="hostmcp_${os}_${arch}"
    [ "$os" = "windows" ] && filename="${filename}.exe"

    if [ -n "$version" ]; then
        url="https://github.com/YujiSuzuki/hostmcp/releases/download/${version}/${filename}"
    else
        url="https://github.com/YujiSuzuki/hostmcp/releases/latest/download/${filename}"
    fi
    install_path="$install_dir/hostmcp"

    msg "Downloading hostmcp ($filename) from GitHub Releases..." \
        "GitHub Releases から hostmcp ($filename) をダウンロード中..."

    mkdir -p "$install_dir"

    download_ok=false
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$url" -o "$install_path" 2>&1 && download_ok=true
    elif command -v wget > /dev/null 2>&1; then
        wget -q "$url" -O "$install_path" 2>&1 && download_ok=true
    else
        msg "Error: Neither curl nor wget found." "エラー: curl も wget も見つかりません。"
        msg "Please download manually from: https://github.com/YujiSuzuki/hostmcp/releases/latest" \
            "手動でダウンロードしてください: https://github.com/YujiSuzuki/hostmcp/releases/latest"
        return 1
    fi

    if [ "$_DKMCP_CANCELLED" = true ]; then
        rm -f "$install_path"
        return 1
    fi

    if [ "$download_ok" != true ] || [ ! -s "$install_path" ]; then
        rm -f "$install_path"
        msg "Error: Download failed. Binary for ${os}/${arch} may not exist in the latest release." \
            "エラー: ダウンロードに失敗しました。${os}/${arch} 向けバイナリが最新リリースに存在しない可能性があります。"
        msg "Install Go and run: go install github.com/YujiSuzuki/hostmcp@latest" \
            "Go をインストールして実行してください: go install github.com/YujiSuzuki/hostmcp@latest"
        return 1
    fi

    chmod +x "$install_path"
    msg "hostmcp installed to: $install_path" "hostmcp をインストールしました: $install_path"
    _warn_stale_hostmcp_hash "$install_dir"

    # Make discoverable for the rest of this script / このスクリプト内で hostmcp を使えるようにする
    local original_path="$PATH"
    export PATH="$install_dir:$PATH"

    # Warn if not in PATH permanently / PATH への永続追加が必要な場合は案内
    case ":$original_path:" in
        *":$install_dir:"*) ;;
        *)
            _offer_path_append "$install_dir"
            ;;
    esac
    return 0
}

# Warn that bash caches resolved command paths (`hash`), so a shell that already
# looked up `hostmcp` before this install (e.g. from a prior install in the other
# of the two known dirs, ~/go/bin or ~/.local/bin) may keep running the old,
# now-missing path until `hash -r` or a new shell. Also flag a leftover binary
# at that other location, since switching install dirs across runs is exactly
# what leaves one behind.
# bashはコマンドの解決済みパスをキャッシュ（`hash`）するため、このインストール以前に
# 一度でも `hostmcp` を解決したことのあるシェル（例: 2つのインストール先候補
# ~/go/bin と ~/.local/bin のもう一方に以前インストールしていた場合）は、
# `hash -r` するか新しいシェルを開くまで、存在しなくなった古いパスを使い続ける
# ことがある。実行のたびにインストール先を切り替えられる仕様上、もう一方の場所に
# 古いバイナリが残っていないかも合わせて警告する。
_warn_stale_hostmcp_hash() {
    local installed_dir="$1"
    local go_bin="$HOME/go/bin"
    local local_bin="$HOME/.local/bin"
    local other_dir="$local_bin"
    [ "$installed_dir" = "$local_bin" ] && other_dir="$go_bin"

    msg "Note: if a shell already looked up 'hostmcp' before this install, run 'hash -r' (or open a new terminal) so it finds this one." \
        "注意: このインストール前に一度でも 'hostmcp' を解決したシェルがある場合は、'hash -r' を実行するか新しいターミナルを開いて、こちらを認識させてください。"

    if [ -f "$other_dir/hostmcp" ]; then
        msg "A hostmcp binary also exists at $other_dir — consider removing it to avoid confusion: rm $other_dir/hostmcp" \
            "$other_dir にも hostmcp のバイナリが残っています。混乱を避けるため削除を検討してください: rm $other_dir/hostmcp"
    fi
}

# Offer to append PATH export to the user's shell rc file / シェル設定ファイルへの PATH 追記を提案
_offer_path_append() {
    local install_dir="$1"
    local rc_file rc_label export_line

    case "${SHELL:-}" in
        */zsh) rc_file="$HOME/.zshrc"; rc_label="~/.zshrc" ;;
        */bash) rc_file="$HOME/.bashrc"; rc_label="~/.bashrc" ;;
        *) rc_file=""; rc_label="~/.zshrc or ~/.bashrc" ;;
    esac
    export_line="export PATH=\"$install_dir:\$PATH\""

    echo ""
    msg "Note: $install_dir is not in your PATH." \
        "注意: $install_dir が PATH に含まれていません。"
    echo "  $export_line"

    if [ -z "$rc_file" ]; then
        msg "Add this line to your shell's rc file (e.g. ~/.zshrc or ~/.bashrc)." \
            "上記を、お使いのシェルの設定ファイル（例: ~/.zshrc や ~/.bashrc）に追記してください。"
        return 0
    fi

    local _prompt _append_choice
    _prompt=$(msg "Add this line to $rc_label now? [y/N]: " "上記を今すぐ $rc_label に追記しますか？ [y/N]: ")
    read -r -p "$_prompt" _append_choice || true
    if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi

    if [[ "$_append_choice" =~ ^[Yy] ]]; then
        if [ -f "$rc_file" ] && grep -qF "$install_dir" "$rc_file" 2>/dev/null; then
            msg "$rc_label already references $install_dir. Skipped." \
                "$rc_label には既に $install_dir の記述があります。スキップしました。"
        else
            {
                echo ""
                echo "# Added by ai-sandbox init-host-env.sh for hostmcp"
                echo "$export_line"
            } >> "$rc_file"
            msg "Added to $rc_label. Run 'source $rc_label' or restart your terminal to apply." \
                "$rc_label に追記しました。'source $rc_label' を実行するかターミナルを再起動して反映してください。"
        fi
    else
        msg "Skipped. Add this line to $rc_label manually if needed." \
            "スキップしました。必要であれば上記を $rc_label に手動で追記してください。"
    fi
}

# hostmcp install check / hostmcp インストール確認
setup_hostmcp_install() {
    trap '_hostmcp_sigint_handler' INT

    # Determine GOPATH bin dir — used both for the "already installed" check and as the
    # install target when downloading a binary (kept in sync with where `go install` would
    # place it, so a later manual `go install` doesn't create a second, conflicting copy)
    # GOPATH/bin を決定 — インストール済みチェックと、バイナリダウンロード時のインストール先の両方で使用
    # （`go install` が置く場所と揃えておくことで、後から手動で `go install` した際に
    #  別の場所に重複インストールされて衝突するのを防ぐ）
    local gopath_bin
    if command -v go > /dev/null 2>&1; then
        local gopath_raw
        if gopath_raw=$(go env GOPATH 2>/dev/null) && [ -n "$gopath_raw" ]; then
            gopath_bin="$gopath_raw/bin"
        else
            gopath_bin="$HOME/go/bin"
        fi
    else
        gopath_bin="$HOME/go/bin"
    fi

    # Already installed? / インストール済みチェック
    if { [ -n "$gopath_bin" ] && [ -f "$gopath_bin/hostmcp" ]; } || command -v hostmcp > /dev/null 2>&1; then
        DKMCP_AVAILABLE=true
        return 0
    fi

    local hostmcp_version=""
    if ! command -v go > /dev/null 2>&1; then
        hostmcp_version=$(_fetch_hostmcp_version)
        if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi
    fi

    echo ""
    msg "hostmcp not found. Install it?" "hostmcp が見つかりません。インストールしますか？"
    if command -v go > /dev/null 2>&1; then
        msg "  1) Yes (go install github.com/YujiSuzuki/hostmcp@latest)" \
            "  1) はい (go install github.com/YujiSuzuki/hostmcp@latest を実行)"
    elif [ -n "$hostmcp_version" ]; then
        msg "  1) Yes (download hostmcp $hostmcp_version from GitHub Releases)" \
            "  1) はい (GitHub Releases から hostmcp $hostmcp_version をダウンロード)"
    else
        msg "  1) Yes (download binary from GitHub Releases)" \
            "  1) はい (GitHub Releases からバイナリをダウンロード)"
    fi
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
            if command -v go > /dev/null 2>&1; then
                echo "  go install github.com/YujiSuzuki/hostmcp@latest"
            else
                echo "  # Download from: https://github.com/YujiSuzuki/hostmcp/releases/latest"
            fi
            echo "  hostmcp init --workspace $display_path"
            echo "  hostmcp serve --workspace $display_path"
            return 0
            ;;
        *)
            if command -v go > /dev/null 2>&1; then
                msg "Installing... (go install github.com/YujiSuzuki/hostmcp@latest)" \
                    "インストール中... (go install github.com/YujiSuzuki/hostmcp@latest)"
                if ! go install github.com/YujiSuzuki/hostmcp@latest 2>&1; then
                    if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi
                    msg "Error: Failed to install hostmcp. To install manually: go install github.com/YujiSuzuki/hostmcp@latest" \
                        "エラー: hostmcp のインストールに失敗しました。手動でインストールする場合: go install github.com/YujiSuzuki/hostmcp@latest"
                    return 0
                fi
                if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi
                # On Windows, `go install` produces hostmcp.exe, not hostmcp.
                # Windowsでは `go install` は hostmcp ではなく hostmcp.exe を生成する
                if [ ! -f "$gopath_bin/hostmcp" ] && [ ! -f "$gopath_bin/hostmcp.exe" ]; then
                    msg "Error: Failed to install hostmcp. To install manually: go install github.com/YujiSuzuki/hostmcp@latest" \
                        "エラー: hostmcp のインストールに失敗しました。手動でインストールする場合: go install github.com/YujiSuzuki/hostmcp@latest"
                    return 0
                fi
                msg "hostmcp installation complete." "hostmcp のインストールが完了しました。"
                _warn_stale_hostmcp_hash "$gopath_bin"
                DKMCP_AVAILABLE=true
            else
                # Default to ~/.local/bin here: this branch only runs when Go is absent,
                # and ~/.local/bin (unlike ~/go/bin) doesn't imply a Go toolchain — offering
                # a GOPATH-shaped path as the default for a no-Go user is confusing and
                # reverses the original rationale for choosing ~/.local/bin in this fallback.
                # ここでは ~/.local/bin をデフォルトにする: この分岐はGoが存在しない場合のみ
                # 実行されるため、~/go/bin と違い Go ツールチェーンを前提としない ~/.local/bin の方が
                # Go未導入ユーザーにとって分かりやすい。GOPATH風のパスをデフォルトにすると、
                # このフォールバックで元々 ~/.local/bin を選んでいた理由と矛盾してしまう。
                local local_bin="$HOME/.local/bin"
                echo ""
                msg "Where should hostmcp be installed?" "hostmcp のインストール先を選択してください:"
                msg "  1) $local_bin (default)" "  1) $local_bin (デフォルト)"
                msg "  2) $gopath_bin" "  2) $gopath_bin"
                echo ""
                local _dir_prompt dir_choice download_dir
                _dir_prompt=$(msg "Enter 1 or 2 [1]: " "1 または 2 を入力 [1]: ")
                read -r -p "$_dir_prompt" dir_choice || true
                if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi
                case "$dir_choice" in
                    2) download_dir="$gopath_bin" ;;
                    *) download_dir="$local_bin" ;;
                esac
                if _download_hostmcp_binary "$hostmcp_version" "$download_dir"; then
                    DKMCP_AVAILABLE=true
                fi
            fi
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

            # Force base-10 interpretation: a bare `$((port_input))` treats a
            # leading-zero numeral as octal, which is a fatal arithmetic error
            # under `set -euo pipefail` for digits 8/9 (e.g. "08080"), and
            # silently misreads other leading-zero input (e.g. "0123" -> 83).
            # 先頭ゼロの数値をbashが8進数として解釈してしまうのを防ぐため、
            # 10進数指定で強制変換する。8/9を含む場合(例: "08080")は
            # `set -euo pipefail` 下で致命的エラーになり、それ以外でも
            # 誤った値（例: "0123" → 83）として黙って解釈されてしまう。
            local port_num=$((10#$port_input))
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

    echo ""
    echo ""
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

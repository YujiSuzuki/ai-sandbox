#!/bin/bash
# install-hostmcp.sh
# Host-side HostMCP installation, configuration, and update wizard.
#
# Not invoked automatically at container/DevContainer startup (unlike
# init-host-env.sh) — HostMCP itself is never auto-started, so there is no
# silent-mode variant here. Always interactive.
#
# Usage:
#   install-hostmcp.sh [project_root]
#
# Must run on the host OS — refuses to run inside the AI Sandbox container
# (see guard below), for the same reason as init-host-env.sh: it writes/reads
# host-side state (Go toolchain, PATH, shell rc files) that would be
# meaningless or actively wrong if run from inside the container.
# @env: host
# ---
# ホスト側の HostMCP インストール・設定・更新ウィザード。
#
# init-host-env.sh と異なり、コンテナ/DevContainer起動時には自動実行されない
# （HostMCP自体が自動起動されることはないため）。常に対話モード。
#
# 使用法:
#   install-hostmcp.sh [project_root]
#
# ホストOS上で実行する必要があります — init-host-env.sh と同じ理由で、AI Sandbox
# コンテナ内では実行を拒否します（下記ガード参照）。Goツールチェーン・PATH・シェル
# 設定ファイルなど、コンテナ内では意味を持たない（あるいは害になる）ホスト側の
# 状態を扱うため。

set -euo pipefail

if [[ -f "/.dockerenv" ]]; then
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        echo "❌ このスクリプトは AI Sandbox コンテナ内では実行できません。" >&2
        echo "" >&2
        echo "ホストOS上のターミナルから実行してください:" >&2
        echo "  .sandbox/host-setup/install-hostmcp.sh" >&2
    else
        echo "❌ This script cannot be run inside the AI Sandbox container." >&2
        echo "" >&2
        echo "Please run it from a terminal on the host OS:" >&2
        echo "  .sandbox/host-setup/install-hostmcp.sh" >&2
    fi
    exit 1
fi

# Parse arguments / 引数のパース
PROJECT_ROOT="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: install-hostmcp.sh [project_root]"
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

DKMCP_AVAILABLE=false
DKMCP_INIT_SUCCESS=false
_DKMCP_CANCELLED=false

# Language is taken from the host shell's own locale, not an interactive prompt
# (unlike init-host-env.sh's language selection): this script is invoked on
# its own, without that step, so it must be able to pick a language by itself.
# 言語はホストシェル自身のロケールから判定する（init-host-env.sh の対話式言語選択とは異なる）:
# このスクリプトは単独で呼び出されるため、その選択ステップなしに自力で言語を決める必要がある。
_is_japanese() {
    [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]
}

# Output a message in the host locale's language / ホストのロケールに応じてメッセージを出力する
msg() {
    local en="$1"
    local ja="$2"
    if _is_japanese; then
        echo "$ja"
    else
        echo "$en"
    fi
}

# Required by _startup_common.sh's fetch_latest_release (called below), which
# assumes the caller defines this. A no-op here: this script has no --debug flag.
# _startup_common.sh の fetch_latest_release（下記で使用）が呼び出し元での定義を
# 前提としているため必要。このスクリプトには --debug フラグがないため no-op。
debug_log() { :; }

# Reuse the update-check helpers (fetch_latest_release, build_api_url,
# extract_tag_from_json) already written and tested for sandbox-mcp's update
# check, for the _check_hostmcp_update feature below — rather than writing a
# third GitHub-release-polling implementation for that one new call site.
# This does NOT replace _fetch_hostmcp_version further down: that curl/wget
# redirect-scraping helper is still the one used by the actual install and
# no-Go upgrade paths, so two release-polling mechanisms intentionally
# coexist in this file — one per use case, not one leftover from a partial
# refactor.
# sandbox-mcp の更新チェック用に既に実装・テスト済みのヘルパー
# （fetch_latest_release, build_api_url, extract_tag_from_json）を、下記の
# _check_hostmcp_update 機能のためだけに再利用する — この1箇所のためだけに
# 3つ目のGitHubリリース取得ロジックを新たに書かないため。これは後述の
# _fetch_hostmcp_version を置き換えるものではない: そちらのcurl/wget
# リダイレクトスクレイピング方式は、実際のインストール処理とGo未導入時の
# 更新処理で引き続き使われる。つまりこのファイルには2つのリリース取得手段が
# 意図的に併存している（用途ごとに1つずつであり、リファクタ漏れではない）。
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_COMMON_LIB="$(cd "$_SCRIPT_DIR/.." && pwd)/scripts/_startup_common.sh"
if [ -f "$_COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$_COMMON_LIB"
fi

HOSTMCP_REPO="YujiSuzuki/hostmcp"

# Restrict fetch_latest_release (called from _check_hostmcp_update below) to
# stable releases only. Without this it defaults to CHECK_CHANNEL=all, which
# can return a pre-release as "latest" — but the actual upgrade paths
# (_fetch_hostmcp_version's /releases/latest redirect, and `go install
# ...@latest`) only ever resolve to the latest stable release, so a
# pre-release "latest" would never match what upgrading actually installs,
# causing the same "update available" prompt to repeat indefinitely.
# 下記 _check_hostmcp_update から呼ばれる fetch_latest_release を安定版限定にする。
# これを設定しないとデフォルトの CHECK_CHANNEL=all になり、プレリリースが
# "最新" として返ることがある。しかし実際の更新経路（_fetch_hostmcp_version の
# /releases/latest リダイレクト、および `go install ...@latest`）は常に安定版
# のみを解決するため、プレリリースが「最新」だと通知と実際のインストール結果が
# 一致せず、「更新があります」の通知が延々と繰り返されてしまう。
CHECK_CHANNEL="stable"

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

# Canonical OS name for hostmcp binary filenames
# MINGW/MSYS/CYGWIN (git-bash etc.) report their own uname, not "windows"
# hostmcpバイナリのファイル名用に正規化したOS名を返す
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
                echo "# Added by ai-sandbox install-hostmcp.sh"
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

# Check whether the installed hostmcp is behind the latest GitHub release, and
# offer to upgrade. Only runs when hostmcp is already installed (fresh installs
# already get the latest release, so there's nothing to check there).
# Network/API failures are treated the same as "no update available": this is
# a convenience check on top of a script whose main job (install/init) already
# succeeded, not something that should block or alarm the user.
# インストール済みのhostmcpがGitHubの最新リリースより古くないか確認し、更新を提案する。
# 既にインストール済みの場合のみ実行（新規インストールは常に最新版が入るため確認不要）。
# ネットワーク/API障害は「更新なし」と同様に扱う: このチェックはスクリプト本来の仕事
# （インストール/init）が既に成功した上でのおまけであり、失敗してもユーザーを
# 妨げたり不安にさせたりすべきではないため。
_check_hostmcp_update() {
    local gopath_bin="$1"
    local installed_version latest_version

    installed_version=$(hostmcp version 2>/dev/null) || installed_version=""
    if [ -z "$installed_version" ]; then
        return 0
    fi

    # Test seam: same convention as check-sandbox-mcp-updates.sh's MOCK_LATEST_VERSION,
    # so tests don't depend on a real network call or a faked curl+JSON response.
    # テスト用フック: check-sandbox-mcp-updates.sh の MOCK_LATEST_VERSION と同じ規約。
    # テストが実ネットワーク呼び出しやcurl+JSONのモックに依存しなくて済む。
    if [ -n "${MOCK_LATEST_VERSION:-}" ]; then
        latest_version="$MOCK_LATEST_VERSION"
    else
        latest_version=$(fetch_latest_release "$HOSTMCP_REPO" 2>/dev/null) || return 0
    fi
    if [ -z "$latest_version" ]; then
        return 0
    fi

    if [ "$installed_version" = "$latest_version" ]; then
        msg "hostmcp is up to date ($installed_version)." \
            "hostmcp は最新です（${installed_version}）。"
        return 0
    fi

    echo ""
    msg "hostmcp update available: $installed_version -> $latest_version" \
        "hostmcp の更新があります: $installed_version -> $latest_version"
    msg "  1) Yes, update now" "  1) はい、今すぐ更新する"
    msg "  2) No (default)" "  2) いいえ（デフォルト）"
    echo ""
    local _prompt _choice
    _prompt=$(msg "Enter 1 or 2 [2]: " "1 または 2 を入力 [2]: ")
    read -r -p "$_prompt" _choice || true
    if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi

    if [ "$_choice" = "1" ]; then
        _upgrade_hostmcp "$gopath_bin"
    fi
}

# Update hostmcp the same way it would be freshly installed: go install if Go
# is available, otherwise a prebuilt binary re-download to wherever it's
# currently installed. Success is judged by the install command's own exit
# status, not by comparing the resulting version to $latest: a plain
# `go install pkg@latest` has no -ldflags, so the binary may keep its source
# default version and would not reliably match a real release tag even on
# success (same reasoning as sandbox-mcp's check-sandbox-mcp-updates.sh).
# 新規インストールと同じ方式で更新する: Go があれば go install、なければ現在の
# インストール先にビルド済みバイナリを再ダウンロード。成功判定はインストール
# コマンド自体の終了コードで行う（バージョン文字列の一致では判定しない）:
# 素の `go install pkg@latest` には -ldflags が付かないため、バイナリがソース側の
# デフォルトバージョンのままとなり、更新に成功していても実際のリリースタグと
# 一致するとは限らないため（sandbox-mcp の check-sandbox-mcp-updates.sh と同じ理由）。
_upgrade_hostmcp() {
    local gopath_bin="$1"

    if command -v go > /dev/null 2>&1; then
        msg "Updating... (go install github.com/YujiSuzuki/hostmcp@latest)" \
            "更新中... (go install github.com/YujiSuzuki/hostmcp@latest)"
        if go install github.com/YujiSuzuki/hostmcp@latest 2>&1; then
            # On Windows, `go install` produces hostmcp.exe, not hostmcp.
            # Windowsでは `go install` は hostmcp ではなく hostmcp.exe を生成する
            if [ ! -f "$gopath_bin/hostmcp" ] && [ ! -f "$gopath_bin/hostmcp.exe" ]; then
                msg "Error: Update failed. Binary not found at $gopath_bin after go install." \
                    "エラー: 更新に失敗しました。go install 後に $gopath_bin にバイナリが見つかりません。"
                return 1
            fi
            hash -r 2>/dev/null || true
            msg "hostmcp updated." "hostmcp を更新しました。"
            # go install always targets $gopath_bin, which may not be where the
            # currently-active `hostmcp` on PATH resolves to (e.g. it was originally
            # installed via binary download to ~/.local/bin) — warn the same way
            # _download_hostmcp_binary already does, so the user notices before
            # assuming the update took effect.
            # go install は常に $gopath_bin を対象にするため、PATH上で現在アクティブな
            # `hostmcp` の場所と一致しない場合がある（例: 元々バイナリダウンロードで
            # ~/.local/bin にインストールしていた場合）。_download_hostmcp_binary と
            # 同様に警告し、更新が反映されたと誤認しないようにする。
            _warn_stale_hostmcp_hash "$gopath_bin"
        else
            msg "Error: Update failed. To update manually: go install github.com/YujiSuzuki/hostmcp@latest" \
                "エラー: 更新に失敗しました。手動で更新する場合: go install github.com/YujiSuzuki/hostmcp@latest"
        fi
        return 0
    fi

    local install_dir existing_path
    if [ -n "$gopath_bin" ] && [ -f "$gopath_bin/hostmcp" ]; then
        install_dir="$gopath_bin"
    elif existing_path="$(command -v hostmcp 2>/dev/null)"; then
        install_dir="$(dirname "$existing_path")"
    else
        # Shouldn't happen: caller only reaches here after confirming hostmcp is available.
        msg "Error: Could not determine hostmcp's install location." \
            "エラー: hostmcp のインストール先を特定できませんでした。"
        return 1
    fi

    local hostmcp_version
    hostmcp_version=$(_fetch_hostmcp_version)
    if _download_hostmcp_binary "$hostmcp_version" "$install_dir"; then
        hash -r 2>/dev/null || true
        msg "hostmcp updated." "hostmcp を更新しました。"
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
        _check_hostmcp_update "$gopath_bin"
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
    # Check read's own exit status rather than swallowing it with `|| true`:
    # a genuine Enter keypress (accepting the "[1]" default) makes read return
    # 0 with an empty string, but closed/non-interactive stdin (e.g. this
    # script reached via a non-TTY bridge) also empties the variable while
    # making read fail — and this prompt's default (empty falls to the `*`
    # branch below) is "proceed with install". Without distinguishing the two,
    # a non-interactive invocation would silently install/download software
    # with no real consent. Abort instead when no input was actually read.
    # read自身の終了ステータスを`|| true`で握りつぶさずに確認する:
    # 本物のEnterキー入力（"[1]"のデフォルトを承認）ならreadは成功して空文字列
    # になるが、閉じられた/非対話的なstdin（例: 非TTY経由でこのスクリプトに
    # 到達した場合）でも変数は空になり、かつreadは失敗する。このプロンプトの
    # デフォルト（空文字は下の`*`分岐に落ちる）は「インストールを続行する」なので、
    # 両者を区別しないと、非対話呼び出しで本当の同意なしにソフトウェアの
    # インストール/ダウンロードが黙って実行されてしまう。実際に入力を読めな
    # かった場合は中止する。
    if ! read -r -p "$_prompt" install_choice; then
        if [ "$_DKMCP_CANCELLED" = true ]; then return 0; fi
        msg "Error: No input received (non-interactive execution?). Aborting HostMCP installation for safety." \
            "エラー: 入力を取得できませんでした（非対話実行の可能性）。安全のためHostMCPのインストールを中止します。"
        return 0
    fi
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
        msg "Then run install-hostmcp.sh again." "その後、再度 install-hostmcp.sh を実行してください。"
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

setup_hostmcp_install
setup_hostmcp_init
trap - INT

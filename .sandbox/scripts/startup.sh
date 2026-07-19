#!/bin/bash
# startup.sh
# Orchestrate all startup scripts for AI Sandbox
# ---
# AI Sandbox の起動スクリプトを統合管理

set -e  # Exit on error

WORKSPACE="${WORKSPACE:-/workspace}"

# Import common functions from _startup_common.sh if available
if [[ -f "$WORKSPACE/.sandbox/scripts/_startup_common.sh" ]]; then
    source "$WORKSPACE/.sandbox/scripts/_startup_common.sh"
fi

# Parse arguments
# 引数解析
NO_SPONSOR=false
for arg in "$@"; do
    case "$arg" in
        --no-sponsor) NO_SPONSOR=true ;;
    esac
done

# Language detection based on locale
# ロケールに基づく言語検出
if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    MSG_TITLE="🚀 AI Sandbox 起動"
    MSG_MERGE_FAILED="⚠️  設定マージに失敗しましたが、続行します..."
    MSG_COMPARE_FAILED="⚠️  設定比較に失敗しましたが、続行します..."
    MSG_VALIDATE_FAILED="⚠️  秘匿検証に失敗しましたが、続行します..."
    MSG_SYNC_CHECK_FAILED="⚠️  秘匿同期チェックに失敗しましたが、続行します..."
    MSG_LANG_HOOK_FAILED="⚠️  言語リマインダーフックの設定に失敗しましたが、続行します..."
    MSG_REGISTERING="📦 SandboxMCP 登録"
    MSG_FETCHING="  📥 sandbox-mcp を取得中..."
    MSG_ALREADY_INSTALLED="  ✅ sandbox-mcp は既にインストール済みです（更新: go install github.com/YujiSuzuki/sandbox-mcp@latest）"
    MSG_REGISTER_FAILED="⚠️  SandboxMCP 登録に失敗しましたが、続行します..."
    MSG_REGISTER_OK="  ✅ 登録済み"
    MSG_REGISTER_SKIP="  ⚠️  登録失敗（既に登録済み？）"
    MSG_NO_GO="⚠️  Go が見つかりません。GitHub Releases からビルド済みバイナリを試します"
    MSG_DOWNLOADING="  📥 sandbox-mcp のビルド済みバイナリをダウンロード中..."
    MSG_DOWNLOAD_OK="  ✅ sandbox-mcp をインストールしました:"
    MSG_DOWNLOAD_FAILED="  ⚠️  ダウンロードに失敗しました。手動でインストールしてください: go install github.com/YujiSuzuki/sandbox-mcp@latest"
    MSG_DKMCP_REGISTER_FAILED="⚠️  HostMCP 登録に失敗しましたが、続行します..."
    MSG_DKMCP_CONNECTED="🔗 HostMCP: ✅ registered, 接続OK"
    MSG_DKMCP_OFFLINE="🔗 HostMCP: ⚠️ registered, 接続不可（ホスト OS で hostmcp serve を起動してください）"
    MSG_INSTALLING_DKMCP_CLIENT="📦 hostmcp CLI インストール（client フォールバック用）"
    MSG_DKMCP_CLIENT_ALREADY_INSTALLED="  ✅ hostmcp は既にインストール済みです"
    MSG_DKMCP_CLIENT_FETCHING="  📥 hostmcp を取得中..."
    MSG_DKMCP_CLIENT_INSTALL_FAILED="  ⚠️  hostmcp のインストールに失敗しましたが、続行します..."
    MSG_DKMCP_CLIENT_NO_GO="  ⚠️  Go が見つかりません。GitHub Releases からビルド済みバイナリを試します"
    MSG_DKMCP_CLIENT_DOWNLOADING="  📥 hostmcp のビルド済みバイナリをダウンロード中..."
    MSG_DKMCP_CLIENT_DOWNLOAD_OK="  ✅ hostmcp をインストールしました:"
    MSG_DKMCP_CLIENT_DOWNLOAD_FAILED="  ⚠️  ダウンロードに失敗しました。手動でインストールしてください: go install github.com/YujiSuzuki/hostmcp@latest"
    MSG_COMPLETE="✅ 起動完了"
else
    MSG_TITLE="🚀 AI Sandbox Startup"
    MSG_MERGE_FAILED="⚠️  Settings merge failed, but continuing..."
    MSG_COMPARE_FAILED="⚠️  Config comparison failed, but continuing..."
    MSG_VALIDATE_FAILED="⚠️  Secret validation failed, but continuing..."
    MSG_SYNC_CHECK_FAILED="⚠️  Secret sync check failed, but continuing..."
    MSG_LANG_HOOK_FAILED="⚠️  Language reminder hook setup failed, but continuing..."
    MSG_REGISTERING="📦 Registering SandboxMCP"
    MSG_FETCHING="  📥 Fetching sandbox-mcp..."
    MSG_ALREADY_INSTALLED="  ✅ sandbox-mcp already installed (to update: go install github.com/YujiSuzuki/sandbox-mcp@latest)"
    MSG_REGISTER_FAILED="⚠️  SandboxMCP registration failed, but continuing..."
    MSG_REGISTER_OK="  ✅ registered"
    MSG_REGISTER_SKIP="  ⚠️  registration failed (already registered?)"
    MSG_NO_GO="⚠️  Go not found, trying prebuilt binary from GitHub Releases instead"
    MSG_DOWNLOADING="  📥 Downloading sandbox-mcp prebuilt binary..."
    MSG_DOWNLOAD_OK="  ✅ sandbox-mcp installed to:"
    MSG_DOWNLOAD_FAILED="  ⚠️  Download failed. Install manually: go install github.com/YujiSuzuki/sandbox-mcp@latest"
    MSG_DKMCP_REGISTER_FAILED="⚠️  HostMCP registration failed, but continuing..."
    MSG_DKMCP_CONNECTED="🔗 HostMCP: ✅ registered, connected"
    MSG_DKMCP_OFFLINE="🔗 HostMCP: ⚠️ registered, server not reachable (run 'hostmcp serve' on host OS)"
    MSG_INSTALLING_DKMCP_CLIENT="📦 Installing hostmcp CLI (client fallback)"
    MSG_DKMCP_CLIENT_ALREADY_INSTALLED="  ✅ hostmcp already installed"
    MSG_DKMCP_CLIENT_FETCHING="  📥 Fetching hostmcp..."
    MSG_DKMCP_CLIENT_INSTALL_FAILED="  ⚠️  hostmcp installation failed, but continuing..."
    MSG_DKMCP_CLIENT_NO_GO="  ⚠️  Go not found, trying prebuilt binary from GitHub Releases instead"
    MSG_DKMCP_CLIENT_DOWNLOADING="  📥 Downloading hostmcp prebuilt binary..."
    MSG_DKMCP_CLIENT_DOWNLOAD_OK="  ✅ hostmcp installed to:"
    MSG_DKMCP_CLIENT_DOWNLOAD_FAILED="  ⚠️  Download failed. Install manually: go install github.com/YujiSuzuki/hostmcp@latest"
    MSG_COMPLETE="✅ Startup complete"
fi

# Note: install_sandbox_mcp_binary (download prebuilt binary from GitHub Releases,
# used when Go is unavailable) is defined in _startup_common.sh, shared with
# check-sandbox-mcp-updates.sh's --auto-update path.
# 注: install_sandbox_mcp_binary は _startup_common.sh で定義（check-sandbox-mcp-updates.sh の
# --auto-update と共有）。

# Run startup scripts in order
# 起動スクリプトを順番に実行

cat <<'BANNER'

   _   ___   ___               _ _
  /_\ |_ _| / __| __ _ _ _  __| | |__  ___ __ __
 / _ \ | |  \__ \/ _` | ' \/ _` | '_ \/ _ \\ \ /
/_/ \_\___| |___/\__,_|_||_\__,_|_.__/\___//_\_\

                    +
 ___               _ _               __  __  ___ ___
/ __| __ _ _ _  __| | |__  _____ __ |  \/  |/ __| _ \
\__ \/ _` | ' \/ _` | '_ \/ _ \ \ / | |\/| | (__|  _/
|___/\__,_|_||_\__,_|_.__/\___/_\_\ |_|  |_|\___|_|

                    +
 _   _              _     __  __    ___   ___
| |_| |  ___   ___ | |_  |  \/  |  / __| | _ \
| ___ | / _ \ (_-< |  _| | |\/| | | (__  |  _/
|_| |_| \___/ /__/  \__| |_|  |_|  \___| |_|

BANNER

# 1. Merge Claude settings (low-failure, essential)
# Claude 設定のマージ（失敗しにくい、必須）
"$WORKSPACE/.sandbox/scripts/merge-claude-settings.sh" || {
    echo "$MSG_MERGE_FAILED"
    echo ""
}

# 2. Compare secret config consistency (report mismatches first)
# 秘匿設定の整合性チェック（不一致を先に報告）
"$WORKSPACE/.sandbox/scripts/compare-secret-config.sh" || {
    echo "$MSG_COMPARE_FAILED"
    echo ""
}

# 3. Validate secrets (critical check, but does not block startup on failure)
# 秘匿検証（重要チェック。ただし失敗しても起動はブロックしない）
"$WORKSPACE/.sandbox/scripts/validate-secrets.sh" || {
    echo "$MSG_VALIDATE_FAILED"
    echo ""
}

# 4. Check secret sync (warning only)
# 秘匿同期チェック（警告のみ）
"$WORKSPACE/.sandbox/scripts/check-secret-sync.sh" || {
    echo "$MSG_SYNC_CHECK_FAILED"
    echo ""
}

# 5. Check for upstream updates (informational only)
# 上流更新チェック（情報提供のみ）
"$WORKSPACE/.sandbox/scripts/check-upstream-updates.sh" || true

# 6. Show sponsor message (informational only, skip with --no-sponsor)
# スポンサーメッセージ表示（情報提供のみ、--no-sponsor でスキップ）
if [ "$NO_SPONSOR" = "false" ]; then
    "$WORKSPACE/.sandbox/scripts/show-sponsor.sh" || true
fi

# 7. Register SandboxMCP (via Go if available, otherwise a prebuilt binary download)
# SandboxMCP 登録（Go があれば go install、なければビルド済みバイナリをダウンロード）
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$MSG_REGISTERING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sandbox_mcp_ready=false
if command -v sandbox-mcp >/dev/null 2>&1; then
    echo "$MSG_ALREADY_INSTALLED"
    sandbox_mcp_ready=true
    "$WORKSPACE/.sandbox/scripts/check-sandbox-mcp-updates.sh" || true
elif command -v go >/dev/null 2>&1; then
    echo "$MSG_FETCHING"
    if go install github.com/YujiSuzuki/sandbox-mcp@latest; then
        sandbox_mcp_ready=true
    else
        echo "$MSG_REGISTER_FAILED"
    fi
else
    echo "$MSG_NO_GO"
    if declare -f install_sandbox_mcp_binary >/dev/null 2>&1; then
        # install_sandbox_mcp_binary already echoes $MSG_DOWNLOAD_FAILED on failure
        install_sandbox_mcp_binary && sandbox_mcp_ready=true
    else
        echo "$MSG_DOWNLOAD_FAILED"
    fi
fi
if [ "$sandbox_mcp_ready" = "true" ]; then
    if command -v claude >/dev/null 2>&1; then
        claude mcp add sandbox-mcp sandbox-mcp \
            && echo "  [Claude] $MSG_REGISTER_OK" \
            || echo "  [Claude] $MSG_REGISTER_SKIP"
    fi
    if command -v gemini >/dev/null 2>&1; then
        gemini mcp add sandbox-mcp sandbox-mcp \
            && echo "  [Gemini] $MSG_REGISTER_OK" \
            || echo "  [Gemini] $MSG_REGISTER_SKIP"
    fi
fi

# 8. Install hostmcp CLI (via Go if available, otherwise a prebuilt binary download)
# Used for `hostmcp client ...` fallback commands when the MCP protocol is unavailable.
# Never installs/runs `hostmcp serve` here — that requires host OS Docker access.
# hostmcp CLI インストール（Go があれば go install、なければビルド済みバイナリをダウンロード）
# MCP接続が使えない場合の `hostmcp client ...` フォールバック用。
# `hostmcp serve`（ホストOSのDockerアクセスが必要）はここではインストール・実行しない。
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$MSG_INSTALLING_DKMCP_CLIENT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if command -v hostmcp >/dev/null 2>&1; then
    echo "$MSG_DKMCP_CLIENT_ALREADY_INSTALLED"
elif command -v go >/dev/null 2>&1; then
    echo "$MSG_DKMCP_CLIENT_FETCHING"
    go install github.com/YujiSuzuki/hostmcp@latest \
        || echo "$MSG_DKMCP_CLIENT_INSTALL_FAILED"
else
    echo "$MSG_DKMCP_CLIENT_NO_GO"
    if declare -f install_hostmcp_binary >/dev/null 2>&1; then
        # install_hostmcp_binary already echoes $MSG_DKMCP_CLIENT_DOWNLOAD_FAILED on failure
        install_hostmcp_binary || true
    else
        echo "$MSG_DKMCP_CLIENT_DOWNLOAD_FAILED"
    fi
fi

# 9. Register HostMCP if not registered, or show one-liner status
# HostMCP 登録（未登録なら登録、登録済みなら1行サマリー）
hostmcp_check=0
"$WORKSPACE/.sandbox/scripts/setup-hostmcp.sh" --check 2>/dev/null || hostmcp_check=$?
if [ "$hostmcp_check" -eq 0 ]; then
    # Registered + connected → one-liner
    # 登録済み＋接続OK → 1行サマリー
    echo ""
    echo "$MSG_DKMCP_CONNECTED"
elif [ "$hostmcp_check" -eq 2 ]; then
    # Registered but offline → one-liner warning
    # 登録済みだがオフライン → 1行警告
    echo ""
    echo "$MSG_DKMCP_OFFLINE"
else
    # Not registered → full registration
    # 未登録 → フル登録出力
    echo ""
    "$WORKSPACE/.sandbox/scripts/setup-hostmcp.sh" || {
        echo "$MSG_DKMCP_REGISTER_FAILED"
        echo ""
    }
fi

# 10. Register the Japanese response-language reminder hook (Japanese
# locale only; no-op and no output for any other locale)
# 日本語応答リマインダーフックの登録（日本語ロケール限定。それ以外の
# ロケールでは何もせず、出力もしない）
"$WORKSPACE/.sandbox/scripts/setup-language-hook.sh" || {
    echo "$MSG_LANG_HOOK_FAILED"
    echo ""
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$MSG_COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

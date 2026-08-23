#!/bin/bash
# _common.sh
# Common functions for CLI sandbox scripts
# CLI サンドボックススクリプト用の共通関数
#
# Usage: source this file from claude.sh, gemini.sh, ai_sandbox.sh
# 使用法: claude.sh, gemini.sh, ai_sandbox.sh からこのファイルを source する
#
# Required variables (must be set before sourcing):
# 必須変数（source 前に設定すること）:
#   SCRIPT_NAME          - Script filename (e.g., "claude.sh")
#   COMPOSE_PROJECT_NAME - Docker Compose project name (e.g., "cli-claude")
#   SANDBOX_ENV          - Sandbox environment name (e.g., "cli_claude")
#
# NOTE: Below, COMPOSE_PROJECT_NAME is auto-suffixed with the workspace directory
#       name (unless overridden via cli_sandbox/.env) so that different workspaces
#       sharing this same cli_sandbox/ template don't collide on the same named
#       volume. See the auto-isolation block below.
# 注意: 下記で、COMPOSE_PROJECT_NAME にはワークスペースディレクトリ名が自動的に
#       サフィックスとして付加されます（cli_sandbox/.env で上書きされている場合を除く）。
#       これは、同じ cli_sandbox/ テンプレートを使う別のワークスペース同士が、
#       同じ名前付きボリュームで衝突しないようにするためです。下記の自動分離ブロックを参照。
#
# NOTE: claude.sh / gemini.sh / ai_sandbox.sh must set COMPOSE_PROJECT_NAME as
#       `COMPOSE_PROJECT_NAME=value` at line start — no default-value syntax like
#       `${VAR:-default}`. .sandbox/scripts/test-advanced-features.sh detects each
#       script's project name via `grep "^COMPOSE_PROJECT_NAME="`, which only
#       matches a literal, unindented assignment.
# 注意: claude.sh / gemini.sh / ai_sandbox.sh では、COMPOSE_PROJECT_NAME を
#       `COMPOSE_PROJECT_NAME=value` の形で行頭に設定すること。`${VAR:-default}`
#       のようなデフォルト値構文は使わない。.sandbox/scripts/test-advanced-features.sh
#       が `grep "^COMPOSE_PROJECT_NAME="` で各スクリプトのプロジェクト名を検出しており、
#       行頭のリテラルな代入でなければマッチしない。

# Validate required variables
# 必須変数の検証
if [ -z "$SCRIPT_NAME" ] || [ -z "$COMPOSE_PROJECT_NAME" ] || [ -z "$SANDBOX_ENV" ]; then
    echo "Error: Required variables not set before sourcing _common.sh"
    echo "エラー: _common.sh を source する前に必須変数が設定されていません"
    echo ""
    echo "Required: SCRIPT_NAME, COMPOSE_PROJECT_NAME, SANDBOX_ENV"
    exit 1
fi

# Check if running from correct directory (parent of cli_sandbox)
# 正しいディレクトリ（cli_sandbox の親ディレクトリ）から実行されているかチェック
if [ ! -f "cli_sandbox/docker-compose.yml" ]; then
    echo "Error: Please run from parent directory of cli_sandbox"
    echo "エラー: cli_sandbox の親ディレクトリから実行してください"
    echo ""
    echo "Usage: ./cli_sandbox/$SCRIPT_NAME"
    echo "使用法: ./cli_sandbox/$SCRIPT_NAME"
    exit 1
fi

# Export environment variables
# 環境変数をエクスポート
_default_compose_project_name="$COMPOSE_PROJECT_NAME"
export COMPOSE_PROJECT_NAME
export SANDBOX_ENV

# Parse startup verbosity options from command line arguments
# コマンドライン引数から起動時詳細度オプションを解析
#
# Usage: parse_startup_verbosity "$@"
#        set -- "${REMAINING_ARGS[@]}"
#
# Options:
#   --quiet, -q   : Only show warnings and errors
#   --summary, -s : Show condensed summary
#   --verbose, -v : Show full detailed output (default)
#
parse_startup_verbosity() {
    REMAINING_ARGS=()
    # Load default from config file if exists
    # 設定ファイルからデフォルト値を読み込み
    if [ -f ".sandbox/config/startup.conf" ]; then
        # shellcheck source=/dev/null
        source ".sandbox/config/startup.conf"
    fi
    STARTUP_VERBOSITY="${STARTUP_VERBOSITY:-verbose}"

    for arg in "$@"; do
        case "$arg" in
            --quiet|-q)
                STARTUP_VERBOSITY="quiet"
                ;;
            --summary|-s)
                STARTUP_VERBOSITY="summary"
                ;;
            --verbose|-v)
                STARTUP_VERBOSITY="verbose"
                ;;
            *)
                REMAINING_ARGS+=("$arg")
                ;;
        esac
    done

    export STARTUP_VERBOSITY
}

# Parse verbosity from arguments passed to the script
# スクリプトに渡された引数から詳細度を解析
parse_startup_verbosity "$@"
set -- "${REMAINING_ARGS[@]}"

# Host-side initialization: create env files from templates and write host OS info
# ホスト側の初期化: テンプレートからenvファイル作成、ホストOS情報の書き出し
.sandbox/host-setup/init-host-env.sh --silent .

# Load environment files for docker-compose variable substitution
# docker-compose.yml の変数置換(${...})を有効にするため、事前に環境変数を読み込む
if [ -f .env.sandbox ]; then
    set -a && source .env.sandbox && set +a
fi
if [ -f cli_sandbox/.env ]; then
    set -a && source cli_sandbox/.env && set +a
fi

# Auto-isolate COMPOSE_PROJECT_NAME per workspace, unless cli_sandbox/.env overrode
# it above. Without this, COMPOSE_PROJECT_NAME is fixed per script (e.g. always
# "cli-claude"), so two different workspaces both using claude.sh would collide
# on the same named volume (cli-claude_cli-sandbox-home), silently sharing one
# home directory (credentials, go/bin, shell history) across unrelated projects.
# .envで上書きされていない場合に限り、COMPOSE_PROJECT_NAMEをワークスペースごとに
# 自動分離する。これがないと COMPOSE_PROJECT_NAME はスクリプトごとに固定（例: 常に
# "cli-claude"）なので、claude.sh を使う別々のワークスペースが同じ名前付きボリューム
# （cli-claude_cli-sandbox-home）に衝突し、無関係なプロジェクト間でホームディレクトリ
# （認証情報、go/bin、シェル履歴）が黙って共有されてしまう。
if [ "$COMPOSE_PROJECT_NAME" = "$_default_compose_project_name" ]; then
    # A readable sanitized name alone isn't collision-proof: different names can
    # sanitize to the same string (e.g. "my project" and "my.project" both become
    # "my-project"), and an all-non-ASCII name (e.g. an all-Japanese directory)
    # sanitizes to an empty string. A checksum of the untouched path is appended
    # (or used alone, when sanitization yields nothing) so the suffix stays unique
    # regardless of what characters the workspace directory name contains.
    # 読みやすいサニタイズ済み名だけでは衝突を防げない。異なる名前が同じ文字列に
    # サニタイズされうる（例: "my project" と "my.project" はどちらも "my-project"
    # になる）うえ、全角文字のみの名前（日本語ディレクトリ名等）はサニタイズ後に
    # 空文字になる。そのため、元のパスのチェックサムを付加（サニタイズ結果が空の
    # 場合はチェックサムのみを使用）し、ディレクトリ名に含まれる文字種に関わらず
    # サフィックスの一意性を保つ。
    _workspace_sanitized=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
    _workspace_hash=$(pwd | cksum | cut -d' ' -f1)
    if [ -n "$_workspace_sanitized" ]; then
        _workspace_suffix="${_workspace_sanitized}-${_workspace_hash}"
    else
        _workspace_suffix="$_workspace_hash"
    fi
    COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}-${_workspace_suffix}"
fi
unset _default_compose_project_name _workspace_suffix _workspace_sanitized _workspace_hash

# Run startup scripts
# 起動時スクリプトを実行
# On startup: merge Claude settings, compare configs, validate secrets, check secret sync, and check for template updates
# Run low-failure scripts first to ensure essential setup completes even if validation fails
# Compare config consistency before validation so root cause (config mismatch) is reported first
# Update check runs last as it's informational only
# 起動時: Claude設定マージ、設定整合性チェック、シークレット検証、シークレット同期チェック、テンプレート更新チェック
# 失敗しにくいスクリプトを先に実行し、検証が失敗しても必須のセットアップが完了するようにする
# 検証より先に設定整合性を比較し、根本原因（設定の不一致）を先に報告する
# 更新チェックは情報提供のみなので最後に実行
#
# Sets HAS_WARNINGS=true if any warnings (⚠️) are detected in output
# 出力に警告（⚠️）が含まれる場合、HAS_WARNINGS=true を設定
run_startup_scripts() {
    local output
    local exit_code
    local temp_file
    temp_file=$(mktemp)

    # Show output in real-time while capturing to temp file
    # リアルタイムで出力を表示しながら一時ファイルにキャプチャ
    docker-compose -f ./cli_sandbox/docker-compose.yml --project-directory . run --rm \
        -e SANDBOX_ENV -e STARTUP_VERBOSITY \
        --entrypoint bash cli-sandbox \
        -c "/workspace/.sandbox/scripts/startup.sh" 2>&1 | tee "$temp_file"
    exit_code=${PIPESTATUS[0]}

    # Read captured output for warning check
    # 警告チェック用にキャプチャされた出力を読み取り
    output=$(cat "$temp_file")
    rm -f "$temp_file"

    # Check for warnings (⚠️ emoji)
    # 警告（⚠️ 絵文字）をチェック
    if echo "$output" | grep -q "⚠️"; then
        HAS_WARNINGS=true
    else
        HAS_WARNINGS=false
    fi
    export HAS_WARNINGS

    return $exit_code
}

# Run AI tool in container
# コンテナ内で AI ツールを実行
run_in_container() {
    docker-compose -f ./cli_sandbox/docker-compose.yml --project-directory . run --rm -e SANDBOX_ENV cli-sandbox "$@"
}

# Ask user whether to continue with warnings (for non-blocking warnings)
# 警告がある場合に続行するか確認（非ブロッキング警告用）
# Only prompts in default mode (not quiet)
# default モードでのみプロンプト表示（quiet では表示しない）
confirm_continue_with_warnings() {
    # Skip if quiet mode
    # quiet モードではスキップ
    if [ "$STARTUP_VERBOSITY" = "quiet" ]; then
        return 0
    fi

    local msg_warnings msg_prompt msg_continuing msg_exiting
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        msg_warnings="⚠️  警告があります（上記参照）"
        msg_prompt="続行しますか？ [Y/n]: "
        msg_continuing="続行します..."
        msg_exiting="終了します。"
    else
        msg_warnings="⚠️  Warnings detected (see above)"
        msg_prompt="Continue? [Y/n]: "
        msg_continuing="Continuing..."
        msg_exiting="Exiting."
    fi

    echo ""
    echo "$msg_warnings"
    printf "%s" "$msg_prompt"
    read -r answer
    case "$answer" in
        [nN]|[nN][oO])
            echo ""
            echo "$msg_exiting"
            return 1
            ;;
        *)
            echo "$msg_continuing"
            echo ""
            return 0
            ;;
    esac
}

# Ask user whether to continue or exit after validation failure
# バリデーション失敗後に続行するか終了するか確認
confirm_continue_after_failure() {
    local msg_failed msg_prompt msg_entering msg_fix msg_exiting
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        msg_failed="⚠️  起動検証に失敗しました。上記のメッセージを確認してください。"
        msg_prompt="シェルのみで続行しますか？（AIツールは起動しません） [y/N]: "
        msg_entering="⚠️  調査用のシェルに入ります。修正はこのシェル内またはホスト OS で行えます。"
        msg_fix="   検証エラーを解消してから AI ツールを起動してください。"
        msg_exiting="終了します。"
    else
        msg_failed="⚠️  Startup validation failed. Please review the messages above."
        msg_prompt="Continue with shell only? (AI tools will NOT be started) [y/N]: "
        msg_entering="⚠️  Entering shell for investigation. Fixes can be made here or on the host OS."
        msg_fix="   Please resolve the validation errors before starting AI tools."
        msg_exiting="Exiting."
    fi

    echo ""
    echo "$msg_failed"
    echo ""
    printf "%s" "$msg_prompt"
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "$msg_entering"
            echo ""
            echo "$msg_fix"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            return 0
            ;;
        *)
            echo ""
            echo "$msg_exiting"
            return 1
            ;;
    esac
}

# Get environment message based on locale
# ロケールに基づいて環境メッセージを取得
get_env_message() {
    local tool_name="$1"
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        echo "この環境はCLI ${tool_name}環境で動作しています。"
    else
        echo "This environment is running in CLI ${tool_name} environment."
    fi
}

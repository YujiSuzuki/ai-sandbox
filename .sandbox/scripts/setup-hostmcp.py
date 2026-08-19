#!/usr/bin/env python3
# setup-hostmcp.py
# ⚠️ This script is for use inside the container (sandbox) only. It does not work on the host OS.
# Register HostMCP as an MCP server for AI tools (Claude Code, Gemini CLI)
# @advertise: true
#
# Detects available AI tools and registers HostMCP as an SSE MCP server.
# Also checks registration status and connectivity. Designed for AI-driven setup:
# AI can run --check to detect missing registration, then offer to register.
#
# Usage:
#   .sandbox/scripts/setup-hostmcp.py [options]
#
# Options:
#   --check       Silent check (exit code: 0=connected, 1=not registered, 2=registered but offline)
#   --status      Human-readable status report
#   --url <url>   Custom HostMCP URL (default: detected from .sandbox/config/hostmcp.yaml's
#                 server.port, else http://host.docker.internal:18080/sse)
#   --unregister  Remove HostMCP from all detected AI tools
#   --help, -h    Show this help
#
# Examples:
#   .sandbox/scripts/setup-hostmcp.py              # Register if needed + verify connectivity
#   .sandbox/scripts/setup-hostmcp.py --check      # Silent check (for AI/startup detection)
#   .sandbox/scripts/setup-hostmcp.py --status     # Show detailed status
#   .sandbox/scripts/setup-hostmcp.py --unregister # Remove HostMCP registration
# ---
# ⚠️ このスクリプトはコンテナ（サンドボックス）内専用です。ホスト OS では動作しません。
# HostMCP を AI ツール（Claude Code, Gemini CLI）に MCP サーバーとして登録
#
# 利用可能な AI ツールを検出し、HostMCP を SSE MCP サーバーとして登録します。
# 登録状態と接続性のチェックも可能で、AI による自動セットアップに活用できます。
# AI が --check で未登録を検出し、「登録しましょうか？」と提案する想定です。
#
# 使用法:
#   .sandbox/scripts/setup-hostmcp.py [options]
#
# オプション:
#   --check       サイレントチェック（終了コード: 0=接続済, 1=未登録, 2=登録済だがオフライン）
#   --status      人向けのステータスレポート
#   --url <url>   カスタム HostMCP URL（デフォルト: .sandbox/config/hostmcp.yaml の
#                 server.port から自動検出、失敗時は http://host.docker.internal:18080/sse）
#   --unregister  全 AI ツールから HostMCP を削除
#   --help, -h    ヘルプ表示

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from _python_common import is_lang_ja, write_json_atomic

# ─── Colors & helpers / カラー出力・ヘルパー関数 ────────────────

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"


def info(msg: str) -> None:
    print(f"{CYAN}ℹ️  {msg}{NC}")


def ok(msg: str) -> None:
    print(f"{GREEN}✅ {msg}{NC}")


def warn(msg: str) -> None:
    print(f"{YELLOW}⚠️  {msg}{NC}")


def err(msg: str) -> None:
    print(f"{RED}❌ {msg}{NC}", file=sys.stderr)


def die(msg: str) -> None:
    err(msg)
    sys.exit(1)


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "🔗 HostMCP セットアップ",
            "REGISTERED": "登録済み",
            "NOT_REGISTERED": "未登録",
            "CLI_NOT_FOUND": "CLI 未インストール",
            "ALREADY_REGISTERED": "登録済み",
            "REGISTERING": "登録中...",
            "REGISTERED_OK": "登録完了",
            "REGISTERED_FALLBACK": "登録完了（.mcp.json 直接編集）",
            "REGISTER_FAILED": "登録に失敗しました",
            "CONNECTIVITY": "接続状態",
            "SERVER_RUNNING": "HostMCP サーバー稼働中",
            "SERVER_NOT_RUNNING": "HostMCP サーバーに接続できません",
            "START_HINT": "ホスト OS で HostMCP を起動してください:",
            "NEXT_STEPS": "次のステップ",
            "CLAUDE_RECONNECT": "Claude Code: /mcp → Reconnect を実行",
            "GEMINI_RESTART": "Gemini CLI: セッションを再起動",
            "NO_AI_TOOLS": "AI ツールが見つかりません（claude / gemini どちらも未インストール）",
            "UNREGISTER_TITLE": "🔗 HostMCP 登録解除",
            "UNREGISTERED": "削除済み",
            "NOT_FOUND": "未登録のためスキップ",
            "HELP_USAGE": "使用法",
            "HELP_OPTIONS": "オプション",
            "HELP_EXAMPLES": "例",
        }
    return {
        "TITLE": "🔗 HostMCP Setup",
        "REGISTERED": "Registered",
        "NOT_REGISTERED": "Not registered",
        "CLI_NOT_FOUND": "CLI not installed",
        "ALREADY_REGISTERED": "Already registered",
        "REGISTERING": "Registering...",
        "REGISTERED_OK": "Registered successfully",
        "REGISTERED_FALLBACK": "Registered via .mcp.json (fallback)",
        "REGISTER_FAILED": "Registration failed",
        "CONNECTIVITY": "Connectivity",
        "SERVER_RUNNING": "HostMCP server is running",
        "SERVER_NOT_RUNNING": "HostMCP server is not reachable",
        "START_HINT": "Start HostMCP on host OS:",
        "NEXT_STEPS": "Next Steps",
        "CLAUDE_RECONNECT": "Claude Code: Run /mcp -> Reconnect",
        "GEMINI_RESTART": "Gemini CLI: Restart the session",
        "NO_AI_TOOLS": "No AI tools found (neither claude nor gemini)",
        "UNREGISTER_TITLE": "🔗 HostMCP Unregister",
        "UNREGISTERED": "Removed",
        "NOT_FOUND": "Not registered, skipping",
        "HELP_USAGE": "Usage",
        "HELP_OPTIONS": "Options",
        "HELP_EXAMPLES": "Examples",
    }


# ─── Constants / 定数 ──────────────────────────────────────────

WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
HOME = Path(os.environ.get("HOME", ""))
DKMCP_NAME = "hostmcp"


def _detect_port_fallback(cfg: Path) -> str | None:
    # Isolate the top-level "server:" block, stop at the next top-level
    # (non-indented) key, then grab the first "port:" line inside it.
    # トップレベルの"server:"ブロックのみを対象にし、次のトップレベル
    # （非インデント）キーで走査を止め、その中の最初の"port:"行を取得。
    in_server = False
    for line in cfg.read_text().splitlines():
        if line.startswith("server:"):
            in_server = True
            continue
        if in_server and re.match(r"^[^ \t]", line):
            in_server = False
        if in_server and re.match(r"^[ \t]+port:[ \t]*[0-9]+", line):
            val = re.sub(r"^[ \t]*port:[ \t]*", "", line)
            val = re.sub(r"[^0-9].*$", "", val)
            return val
    return None


def detect_hostmcp_port() -> int | None:
    """Reads server.port from $WORKSPACE/.sandbox/config/hostmcp.yaml so DEFAULT_URL
    matches the port `hostmcp serve` actually listens on. Returns the port on
    success, None if the config is missing or the port can't be determined,
    leaving callers to fall back to the hardcoded port.

    $WORKSPACE/.sandbox/config/hostmcp.yaml の server.port を読み取り、
    DEFAULT_URL を `hostmcp serve` が実際にリッスンしているポートに合わせます。
    成功時はポート番号を返し、configが無い・ポートが特定できない場合はNoneを
    返します（呼び出し側はハードコードされたポートにフォールバック）。
    """
    cfg = WORKSPACE / ".sandbox" / "config" / "hostmcp.yaml"
    if not cfg.is_file():
        return None

    port = None
    try:
        # No "eval" subcommand: this bare jq-filter form works both with
        # mikefarah/yq (Go) and Debian's apt "yq" package (kislyuk/yq, a
        # Python/jq wrapper), whichever happens to be installed.
        # "eval"サブコマンドを付けない: この素のjqフィルタ形式は、mikefarah/yq
        # （Go版）とDebianのaptパッケージ「yq」（kislyuk/yq、Python/jqラッパー）
        # のどちらがインストールされていても動作する。
        result = subprocess.run(["yq", ".server.port", str(cfg)], capture_output=True, text=True, timeout=10)
        val = result.stdout.strip()
        if val and val != "null":
            port = val
    except (FileNotFoundError, subprocess.SubprocessError):
        port = None

    if not port:
        port = _detect_port_fallback(cfg)

    if port and re.fullmatch(r"[0-9]+", port):
        return int(port)
    return None


_detected_port = detect_hostmcp_port()
if _detected_port is not None:
    DEFAULT_URL = f"http://host.docker.internal:{_detected_port}/sse"
else:
    DEFAULT_URL = "http://host.docker.internal:18080/sse"


# ─── Help / ヘルプ ─────────────────────────────────────────────

def show_help(msgs: dict) -> None:
    print()
    print(f"{msgs['HELP_USAGE']}:")
    print("  .sandbox/scripts/setup-hostmcp.py [options]")
    print()
    print(f"{msgs['HELP_OPTIONS']}:")
    print("  --check       Silent check (exit: 0=connected, 1=not registered, 2=offline)")
    print("  --status      Human-readable status report")
    print(f"  --url <url>   Custom HostMCP URL (default: {DEFAULT_URL})")
    print("  --unregister  Remove HostMCP from all AI tools")
    print("  --help, -h    Show this help")
    print()
    print(f"{msgs['HELP_EXAMPLES']}:")
    print("  .sandbox/scripts/setup-hostmcp.py              # Register + verify")
    print("  .sandbox/scripts/setup-hostmcp.py --check      # Silent check")
    print("  .sandbox/scripts/setup-hostmcp.py --status     # Show status")
    print("  .sandbox/scripts/setup-hostmcp.py --unregister # Remove registration")
    print()
    sys.exit(0)


# ─── Argument parsing / 引数解析 ──────────────────────────────

def parse_args(argv: list[str], msgs: dict) -> tuple[str, str]:
    mode = "default"
    url = DEFAULT_URL

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--check":
            mode = "check"
            i += 1
        elif arg == "--status":
            mode = "status"
            i += 1
        elif arg == "--unregister":
            mode = "unregister"
            i += 1
        elif arg == "--url":
            if i + 1 >= len(argv) or argv[i + 1] == "":
                die("--url requires a URL")
            url = argv[i + 1]
            i += 2
        elif arg in ("--help", "-h"):
            show_help(msgs)
        elif arg.startswith("-"):
            die(f"Unknown option: {arg}")
        else:
            die(f"Unexpected argument: {arg}")

    return mode, url


# ─── Tool detection / ツール検出 ──────────────────────────────

def has_claude() -> bool:
    return shutil.which("claude") is not None


def has_gemini() -> bool:
    return shutil.which("gemini") is not None


# Claude registration is possible via .mcp.json or .mcp.json.example even without claude CLI
# claude CLI がなくても .mcp.json / .mcp.json.example 経由で登録可能
def can_register_claude() -> bool:
    return has_claude() or (WORKSPACE / ".mcp.json").is_file() or (WORKSPACE / ".mcp.json.example").is_file()


# Gemini registration is possible via .gemini/settings.json even without gemini CLI
# gemini CLI がなくても .gemini/settings.json 経由で登録可能
def can_register_gemini() -> bool:
    return has_gemini() or (WORKSPACE / ".gemini" / "settings.json").is_file()


# ─── Registration detection / 登録検出 ────────────────────────

def _json_has_key(path: Path, *keys: str) -> bool:
    # Mirrors `jq -e`: a final value of null or false counts as "not found",
    # not merely "the key is present" -- matches jq -e's own null/false
    # treatment as failure.
    # `jq -e` に合わせている: 最終値が null または false の場合は
    # 「キーが存在する」ではなく「見つからない」扱いとする -- jq -e が
    # null/false を失敗として扱う挙動に一致させる。
    try:
        node = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return False
    for key in keys:
        if not isinstance(node, dict) or key not in node:
            return False
        node = node[key]
    return node is not None and node is not False


def is_claude_registered() -> bool:
    mcp_json = WORKSPACE / ".mcp.json"
    if mcp_json.is_file() and _json_has_key(mcp_json, "mcpServers", DKMCP_NAME):
        return True

    claude_json = HOME / ".claude.json"
    if claude_json.is_file():
        if _json_has_key(claude_json, "projects", str(WORKSPACE), "mcpServers", DKMCP_NAME):
            return True
        if _json_has_key(claude_json, "mcpServers", DKMCP_NAME):
            return True

    return False


def is_gemini_registered() -> bool:
    project_settings = WORKSPACE / ".gemini" / "settings.json"
    if project_settings.is_file() and _json_has_key(project_settings, "mcpServers", DKMCP_NAME):
        return True

    user_settings = HOME / ".gemini" / "settings.json"
    if user_settings.is_file() and _json_has_key(user_settings, "mcpServers", DKMCP_NAME):
        return True

    return False


# ─── Connectivity check / 接続確認 ────────────────────────────

def check_connectivity(url: str) -> bool:
    base_url = url[:-4] if url.endswith("/sse") else url

    # Try base URL - even a 404 means the server is reachable
    try:
        result = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--connect-timeout", "3", "--max-time", "5", f"{base_url}/"],
            capture_output=True, text=True, timeout=10,
        )
        http_code = result.stdout.strip()
    except subprocess.SubprocessError:
        http_code = ""

    return http_code not in ("000", "")


# ─── Registration / 登録 ──────────────────────────────────────

def register_claude(url: str) -> bool:
    # Primary: use claude CLI (official method)
    if has_claude():
        result = subprocess.run(
            ["claude", "mcp", "add", "--transport", "sse", "--scope", "user", DKMCP_NAME, url],
            cwd=WORKSPACE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0

    # Fallback: write .mcp.json directly
    mcp_json = WORKSPACE / ".mcp.json"
    example = WORKSPACE / ".mcp.json.example"
    source = mcp_json if mcp_json.is_file() else example if example.is_file() else None
    if source is None:
        return False

    try:
        data = json.loads(source.read_text())
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(data, dict):
        return False
    data.setdefault("mcpServers", {})[DKMCP_NAME] = {"type": "sse", "url": url}
    write_json_atomic(mcp_json, data)
    return True


def register_gemini(url: str) -> bool:
    # Primary: use gemini CLI (official method)
    if has_gemini():
        result = subprocess.run(
            ["gemini", "mcp", "add", "--transport", "sse", DKMCP_NAME, url],
            cwd=WORKSPACE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0

    # Fallback: write .gemini/settings.json directly
    settings = WORKSPACE / ".gemini" / "settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    if settings.is_file():
        try:
            data = json.loads(settings.read_text())
        except (OSError, json.JSONDecodeError):
            return False
    else:
        data = {"mcpServers": {}}
    if not isinstance(data, dict):
        return False
    data.setdefault("mcpServers", {})[DKMCP_NAME] = {"url": url, "type": "sse"}
    write_json_atomic(settings, data)
    return True


# ─── Unregistration / 登録解除 ────────────────────────────────

def unregister_claude() -> bool:
    removed = False

    # Remove from .mcp.json
    mcp_json = WORKSPACE / ".mcp.json"
    if mcp_json.is_file():
        try:
            data = json.loads(mcp_json.read_text())
        except (OSError, json.JSONDecodeError):
            data = None
        if isinstance(data, dict) and DKMCP_NAME in data.get("mcpServers", {}):
            del data["mcpServers"][DKMCP_NAME]
            write_json_atomic(mcp_json, data)
            removed = True

    # Remove via CLI (handles user/project scope in ~/.claude.json)
    if has_claude():
        result = subprocess.run(
            ["claude", "mcp", "remove", DKMCP_NAME],
            cwd=WORKSPACE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            removed = True

    return removed


def unregister_gemini() -> bool:
    removed = False

    # Remove from project settings
    settings = WORKSPACE / ".gemini" / "settings.json"
    if settings.is_file():
        try:
            data = json.loads(settings.read_text())
        except (OSError, json.JSONDecodeError):
            data = None
        if isinstance(data, dict) and DKMCP_NAME in data.get("mcpServers", {}):
            del data["mcpServers"][DKMCP_NAME]
            write_json_atomic(settings, data)
            removed = True

    # Remove via CLI (handles user scope)
    if has_gemini():
        result = subprocess.run(
            ["gemini", "mcp", "remove", DKMCP_NAME],
            cwd=WORKSPACE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            removed = True

    return removed


# ─── Mode: check / チェックモード ─────────────────────────────
# Returns: 0=registered+connected, 1=not registered, 2=registered but offline

def mode_check(url: str) -> None:
    # Registration state is read from config files directly, so it must be
    # checked regardless of whether the claude/gemini CLI is on PATH right
    # now (e.g. CI runners without the CLI installed still have a
    # ~/.claude.json with hostmcp registered).
    registered = is_claude_registered() or is_gemini_registered()

    if not registered:
        sys.exit(1)

    if check_connectivity(url):
        sys.exit(0)
    else:
        sys.exit(2)


# ─── Mode: status / ステータスモード ──────────────────────────

def mode_status(msgs: dict, url: str) -> None:
    print()
    print(f"{BOLD}{msgs['TITLE']}{NC}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print()

    if can_register_claude():
        if is_claude_registered():
            ok(f"[Claude] {msgs['REGISTERED']}")
        else:
            warn(f"[Claude] {msgs['NOT_REGISTERED']}")
    else:
        print(f"  {DIM}[Claude] {msgs['CLI_NOT_FOUND']}{NC}")

    if can_register_gemini():
        if is_gemini_registered():
            ok(f"[Gemini] {msgs['REGISTERED']}")
        else:
            warn(f"[Gemini] {msgs['NOT_REGISTERED']}")
    else:
        print(f"  {DIM}[Gemini] {msgs['CLI_NOT_FOUND']}{NC}")

    print()

    print(f"{BOLD}{msgs['CONNECTIVITY']}{NC}")
    print("──────────────────────────────────────")
    if check_connectivity(url):
        ok(f"{msgs['SERVER_RUNNING']} ({url})")
    else:
        warn(f"{msgs['SERVER_NOT_RUNNING']} ({url})")
        print()
        info(msgs["START_HINT"])
        print(f"  {CYAN}cd hostmcp && make install && hostmcp serve{NC}")
    print()
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")


# ─── Mode: default / デフォルトモード ─────────────────────────

def mode_default(msgs: dict, url: str) -> None:
    any_new = False
    has_any_tool = False

    print()
    print(f"{BOLD}{msgs['TITLE']}{NC}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print()

    # Claude
    if can_register_claude():
        has_any_tool = True
        if is_claude_registered():
            ok(f"[Claude] {msgs['ALREADY_REGISTERED']}")
        else:
            info(f"[Claude] {msgs['REGISTERING']}")
            if register_claude(url):
                if has_claude():
                    ok(f"[Claude] {msgs['REGISTERED_OK']}")
                else:
                    ok(f"[Claude] {msgs['REGISTERED_FALLBACK']}")
                any_new = True
            else:
                err(f"[Claude] {msgs['REGISTER_FAILED']}")

    # Gemini
    if can_register_gemini():
        has_any_tool = True
        if is_gemini_registered():
            ok(f"[Gemini] {msgs['ALREADY_REGISTERED']}")
        else:
            info(f"[Gemini] {msgs['REGISTERING']}")
            if register_gemini(url):
                if has_gemini():
                    ok(f"[Gemini] {msgs['REGISTERED_OK']}")
                else:
                    ok(f"[Gemini] {msgs['REGISTERED_FALLBACK']}")
                any_new = True
            else:
                err(f"[Gemini] {msgs['REGISTER_FAILED']}")

    # No tools found
    if not has_any_tool:
        warn(msgs["NO_AI_TOOLS"])
        print()
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        sys.exit(1)

    print()

    # Connectivity check
    print(f"{BOLD}{msgs['CONNECTIVITY']}{NC}")
    print("──────────────────────────────────────")
    if check_connectivity(url):
        ok(msgs["SERVER_RUNNING"])
    else:
        warn(msgs["SERVER_NOT_RUNNING"])
        print()
        info(msgs["START_HINT"])
        print(f"  {CYAN}cd hostmcp && make install && hostmcp serve{NC}")

    # Post-registration guidance
    if any_new:
        print()
        print(f"{BOLD}{msgs['NEXT_STEPS']}{NC}")
        print("──────────────────────────────────────")
        if has_claude():
            info(msgs["CLAUDE_RECONNECT"])
        if has_gemini():
            info(msgs["GEMINI_RESTART"])

    print()
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")


# ─── Mode: unregister / 登録解除モード ────────────────────────

def mode_unregister(msgs: dict) -> None:
    print()
    print(f"{BOLD}{msgs['UNREGISTER_TITLE']}{NC}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print()

    if can_register_claude():
        if unregister_claude():
            ok(f"[Claude] {msgs['UNREGISTERED']}")
        else:
            print(f"  {DIM}[Claude] {msgs['NOT_FOUND']}{NC}")

    if can_register_gemini():
        if unregister_gemini():
            ok(f"[Gemini] {msgs['UNREGISTERED']}")
        else:
            print(f"  {DIM}[Gemini] {msgs['NOT_FOUND']}{NC}")

    print()
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")


# ─── Main / メイン ────────────────────────────────────────────

def main() -> None:
    msgs = get_messages(is_lang_ja())
    mode, url = parse_args(sys.argv[1:], msgs)

    if mode == "check":
        mode_check(url)
    elif mode == "status":
        mode_status(msgs, url)
    elif mode == "unregister":
        mode_unregister(msgs)
    else:
        mode_default(msgs, url)


if __name__ == "__main__":
    main()

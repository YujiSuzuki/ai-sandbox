#!/usr/bin/env python3
# check-sandbox-mcp-updates.py
# Check for updates to the installed sandbox-mcp binary
#
# Unlike check-upstream-updates.py (which only knows a new template tag
# exists), this script compares the actually installed `sandbox-mcp version`
# against the latest GitHub release tag, since we have real ground truth here.
#
# Intentional deviations from the bash original:
# - The GitHub releases API call goes through _python_common.py's
#   fetch_latest_release() (stdlib urllib.request) rather than curl.
# - install_sandbox_mcp_binary() below still shells out to curl/wget for the
#   actual binary download, unlike the API call above: this mirrors the bash
#   original's own curl-then-wget fallback, and keeps this codepath testable
#   the same way the bash version was (a stub `curl`/`wget` prepended to
#   PATH) rather than needing a different mocking technique for just this
#   one function.
# - OS/arch detection uses the stdlib `platform` module instead of shelling
#   out to `uname` (no test depends on `uname` being an external command, so
#   this loses no mockability, unlike the curl/wget case above).
# ---
# インストール済み sandbox-mcp バイナリの更新をチェック
# check-upstream-updates.py（新しいタグの存在しか分からない）と異なり、
# 実際にインストールされている `sandbox-mcp version` と GitHub の最新タグを
# 直接比較する（実際のインストール済みバージョンという確かな情報源があるため）。
#
# bash版からの意図的な差分:
# - GitHub releases APIの呼び出しは _python_common.py の
#   fetch_latest_release()（標準ライブラリのurllib.request）経由で行い、
#   curlは呼ばない。
# - 一方で下記の install_sandbox_mcp_binary() は、実際のバイナリダウンロードに
#   curl/wgetを引き続き使う: bash版自身のcurl→wgetフォールバックを踏襲し、
#   このコードパスをbash版と同じ方法（PATH先頭に置いたcurl/wgetスタブ）で
#   テスト可能なままにするため（この関数だけ別のモック手法が要らなくなる）。
# - OS/アーキテクチャ検出はuname呼び出しではなく標準ライブラリのplatform
#   モジュールを使う（unameが外部コマンドであることに依存するテストは無いため、
#   上記のcurl/wgetの場合と異なりテスト可能性を損なわない）。

import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from _python_common import (
    debug_log,
    fetch_latest_release,
    is_quiet,
    is_summary,
    load_startup_config,
    print_footer,
    print_title,
    should_check,
    update_state,
)

# This is a fixed infra dependency of the template, not a swappable source,
# so it's a constant rather than a config file value (consistent with the
# already-hardcoded repo references in startup.sh).
# テンプレートに同梱される固定の依存パッケージであり、差し替え可能な設定値ではないため
# 定数として扱う（startup.sh に既にハードコードされているリポジトリ参照と同様）。
SANDBOX_MCP_REPO = "YujiSuzuki/sandbox-mcp"


def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "📦 sandbox-mcp 更新チェック",
            "UPDATE_AVAILABLE": "更新があります",
            "CURRENT": "現在のバージョン",
            "LATEST": "最新バージョン",
            "HOW_TO_UPDATE": "更新方法",
            "HOW_TO_UPDATE_CMD": ".sandbox/scripts/check-sandbox-mcp-updates.py --auto-update",
            "AUTO_UPDATING": "  📥 自動更新中...",
            "AUTO_UPDATE_GO": "  📥 go install で更新中...",
            "AUTO_UPDATE_OK": "  ✅ sandbox-mcp を更新しました:",
            "AUTO_UPDATE_FAILED": "  ⚠️  自動更新に失敗しました。手動で更新してください: go install github.com/YujiSuzuki/sandbox-mcp@latest",
            "NO_GO": "  ⚠️  Go が見つかりません。GitHub Releases からビルド済みバイナリを試します",
            "DOWNLOADING": "  📥 sandbox-mcp のビルド済みバイナリをダウンロード中...",
            "DOWNLOAD_OK": "  ✅ sandbox-mcp をインストールしました:",
            "DOWNLOAD_FAILED": "  ⚠️  ダウンロードに失敗しました。手動でインストールしてください: go install github.com/YujiSuzuki/sandbox-mcp@latest",
        }
    return {
        "TITLE": "📦 sandbox-mcp Update Check",
        "UPDATE_AVAILABLE": "Update available",
        "CURRENT": "Current version",
        "LATEST": "Latest version",
        "HOW_TO_UPDATE": "How to update",
        "HOW_TO_UPDATE_CMD": ".sandbox/scripts/check-sandbox-mcp-updates.py --auto-update",
        "AUTO_UPDATING": "  📥 Auto-updating...",
        "AUTO_UPDATE_GO": "  📥 Updating via go install...",
        "AUTO_UPDATE_OK": "  ✅ sandbox-mcp updated to:",
        "AUTO_UPDATE_FAILED": "  ⚠️  Auto-update failed. Update manually: go install github.com/YujiSuzuki/sandbox-mcp@latest",
        "NO_GO": "  ⚠️  Go not found, trying prebuilt binary from GitHub Releases instead",
        "DOWNLOADING": "  📥 Downloading sandbox-mcp prebuilt binary...",
        "DOWNLOAD_OK": "  ✅ sandbox-mcp installed to:",
        "DOWNLOAD_FAILED": "  ⚠️  Download failed. Install manually: go install github.com/YujiSuzuki/sandbox-mcp@latest",
    }


def install_sandbox_mcp_binary(msgs: dict) -> bool:
    """Downloads a prebuilt sandbox-mcp binary from GitHub Releases (used
    when Go is unavailable). See the module docstring for why this still
    shells out to curl/wget rather than using urllib.request.

    Go が無い場合に GitHub Releases からビルド済み sandbox-mcp バイナリを
    ダウンロードする。curl/wgetを使い続ける理由はモジュール先頭のdocstring
    を参照。
    """
    system = platform.system()
    if system.upper().startswith(("MINGW", "MSYS", "CYGWIN")):
        os_name = "windows"
    else:
        os_name = system.lower()

    machine = platform.machine()
    arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine, machine)

    filename = f"sandbox-mcp_{os_name}_{arch}"
    if os_name == "windows":
        filename += ".exe"

    install_dir = Path(os.environ.get("HOME") or str(Path.home())) / ".local" / "bin"
    install_path = install_dir / "sandbox-mcp"

    print(msgs["DOWNLOADING"])
    install_dir.mkdir(parents=True, exist_ok=True)

    url = f"https://github.com/YujiSuzuki/sandbox-mcp/releases/latest/download/{filename}"

    if shutil.which("curl"):
        result = subprocess.run(["curl", "-fsSL", url, "-o", str(install_path)])
        downloaded = result.returncode == 0
    elif shutil.which("wget"):
        result = subprocess.run(["wget", "-q", url, "-O", str(install_path)])
        downloaded = result.returncode == 0
    else:
        print(msgs["DOWNLOAD_FAILED"])
        return False

    if not downloaded or not install_path.is_file() or install_path.stat().st_size == 0:
        install_path.unlink(missing_ok=True)
        print(msgs["DOWNLOAD_FAILED"])
        return False

    install_path.chmod(install_path.stat().st_mode | 0o111)
    print(f"{msgs['DOWNLOAD_OK']} {install_path}")

    # Make discoverable for the rest of this process (e.g. a later
    # get_installed_version() subprocess call) / このプロセス内で使えるようにする
    os.environ["PATH"] = f"{install_dir}{os.pathsep}{os.environ.get('PATH', '')}"
    return True


def get_installed_version() -> str:
    mock = os.environ.get("MOCK_INSTALLED_VERSION")
    if mock:
        return mock
    try:
        result = subprocess.run(["sandbox-mcp", "version"], capture_output=True, text=True)
    except OSError:
        return ""
    output = result.stdout.strip()
    prefix = "sandbox-mcp "
    if output.startswith(prefix):
        output = output[len(prefix):]
    return output


def auto_update_sandbox_mcp(msgs: dict) -> bool:
    """Updates sandbox-mcp the same way startup.sh installs it fresh: go
    install if Go is available, otherwise a prebuilt binary download.
    Success is judged by the install command's own exit status, not by
    comparing the resulting version to latest: a plain `go install
    pkg@latest` has no -ldflags, so the binary keeps its source default
    version ("dev") and would never match a real release tag even on
    success.

    startup.sh の新規インストールと同じ方式で更新する: Go があれば go install、
    なければビルド済みバイナリのダウンロード。成功判定はインストールコマンド
    自体の終了コードで行う（バージョン文字列の一致では判定しない）: 素の
    `go install pkg@latest` には -ldflags が付かないため、バイナリはソース側の
    デフォルト値（"dev"）のままとなり、更新に成功していても実際のリリース
    タグとは一致しないため。
    """
    print(msgs["AUTO_UPDATING"])
    if shutil.which("go"):
        print(msgs["AUTO_UPDATE_GO"])
        result = subprocess.run(["go", "install", "github.com/YujiSuzuki/sandbox-mcp@latest"])
        install_ok = result.returncode == 0
    else:
        print(msgs["NO_GO"])
        install_ok = install_sandbox_mcp_binary(msgs)

    if install_ok:
        print(f"{msgs['AUTO_UPDATE_OK']} {get_installed_version()}")
        return True

    print(msgs["AUTO_UPDATE_FAILED"])
    return False


def show_update_notification(current: str, latest: str, verbosity: str, msgs: dict) -> None:
    version_display = f"{current} → {latest}"

    if is_quiet(verbosity):
        print(f"📦 {msgs['UPDATE_AVAILABLE']}: {version_display}")
        return

    if is_summary(verbosity):
        print_title(msgs["TITLE"], verbosity)
        print(f"  {msgs['CURRENT']}:  {current}")
        print(f"  {msgs['LATEST']}:   {latest}")
        print_footer(verbosity)
        return

    # Verbose
    print_title(msgs["TITLE"], verbosity)
    print(f"  {msgs['CURRENT']}:  {current}")
    print(f"  {msgs['LATEST']}:   {latest}")
    print()
    print(f"  {msgs['HOW_TO_UPDATE']}:")
    print(f"    {msgs['HOW_TO_UPDATE_CMD']}")
    print_footer(verbosity)


def main() -> None:
    argv = sys.argv[1:]
    debug = os.environ.get("DEBUG_UPDATE_CHECK", "0") == "1" or "--debug" in argv
    auto_update = os.environ.get("AUTO_UPDATE_SANDBOX_MCP", "false") == "true" or "--auto-update" in argv

    check_updates = os.environ.get("CHECK_UPDATES", "true")
    check_channel = os.environ.get("CHECK_CHANNEL", "all")
    check_interval_hours = os.environ.get("CHECK_INTERVAL_HOURS", "24")

    workspace = Path(os.environ.get("WORKSPACE", "/workspace"))
    state_file = Path(os.environ.get("STATE_FILE", str(workspace / ".sandbox" / ".state" / "update-check-sandbox-mcp")))

    if check_updates != "true":
        debug_log(f"CHECK_UPDATES={check_updates} → disabled, exit", debug)
        return

    if not shutil.which("sandbox-mcp") and not os.environ.get("MOCK_INSTALLED_VERSION"):
        debug_log("sandbox-mcp not on PATH → skip", debug)
        return

    installed_version = get_installed_version()
    if not installed_version:
        debug_log("Could not determine installed version → skip", debug)
        return

    # An explicit --auto-update / AUTO_UPDATE_SANDBOX_MCP=true request bypasses the
    # interval throttle: should_check exists to rate-limit the passive check that
    # startup.sh runs on every shell start, not a manual update the user just asked for.
    # 明示的な --auto-update / AUTO_UPDATE_SANDBOX_MCP=true はインターバルスロットリングを
    # 無視する: should_check は startup.sh が毎回実行する受動的チェックを間引くためのもので、
    # ユーザーが今まさに要求した手動更新には適用すべきでない。
    if not auto_update and not should_check(state_file, check_interval_hours):
        debug_log("Interval not elapsed → skip", debug)
        return

    mock_latest = os.environ.get("MOCK_LATEST_VERSION")
    if mock_latest:
        latest_version = mock_latest
        debug_log(f"MOCK_LATEST_VERSION set → skip API call, use '{latest_version}'", debug)
    elif os.environ.get("MOCK_FORCE_FETCH_FAILURE"):
        debug_log("MOCK_FORCE_FETCH_FAILURE set → simulating fetch failure", debug)
        return
    else:
        latest_version = fetch_latest_release(SANDBOX_MCP_REPO, check_channel)
        if latest_version is None:
            debug_log("Fetch failed → exit", debug)
            return

    if not latest_version:
        debug_log("No release found → exit", debug)
        update_state(state_file, "")
        return

    lang_ja = os.environ.get("LANG", "").startswith("ja_JP") or os.environ.get("LC_ALL", "").startswith("ja_JP")
    msgs = get_messages(lang_ja)

    startup_config = load_startup_config()
    verbosity = startup_config["verbosity"]

    if installed_version == latest_version:
        debug_log(f"Same version ({installed_version}) → no notification", debug)
        update_state(state_file, latest_version)
        return

    debug_log(f"Installed ({installed_version}) != latest ({latest_version}) → notify", debug)
    show_update_notification(installed_version, latest_version, verbosity, msgs)

    if auto_update:
        debug_log("AUTO_UPDATE_SANDBOX_MCP → attempting update", debug)
        try:
            auto_update_sandbox_mcp(msgs)
        except OSError:
            pass

    update_state(state_file, latest_version)


if __name__ == "__main__":
    main()

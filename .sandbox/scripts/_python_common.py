#!/usr/bin/env python3
# _python_common.py
# Shared helpers for .sandbox/scripts/ Python scripts: language detection,
# bilingual message output, atomic JSON writes, stdout line-buffering, and
# the verbosity/print/sync-ignore/backup helpers migrated from
# _startup_common.sh. Plays the same role for Python scripts in this
# directory that _startup_common.sh plays for bash scripts here -- import
# it, don't re-implement these per script.
#
# Only the _startup_common.sh functions actually used by the Python-migrated
# scripts are ported here -- as of this writing that's the subset needed by
# the _secret-tag.sh-dependent group (load_startup_config and its shared
# parse_simple_conf() parser, is_quiet/
# is_verbose/is_summary, print_title/print_footer/print_default/print_error,
# load_sync_ignore_patterns/matches_sync_ignore/add_sync_ignore_pattern,
# backup_file/cleanup_backups), print_detail/print_warning (added for
# merge-claude-settings.py), and debug_log/read_state_timestamp/
# get_last_notified_version/is_first_run/should_check/update_state/
# build_api_url/extract_tag_from_json/fetch_latest_release (added for
# check-upstream-updates.py / check-sandbox-mcp-updates.py -- the update-check
# helpers, shared by both). _startup_common.sh's remaining functions (README
# URL helpers, print_summary, and the install_sandbox_mcp_binary/
# install_hostmcp_binary binary-install helpers, both still needed there
# since startup.sh itself, which stays bash, calls them directly) belong to
# scripts that haven't been migrated yet, or must stay in bash regardless of
# migration status; add remaining helpers here if/when their scripts are
# ported, rather than porting the whole file speculatively. Note:
# check-sandbox-mcp-updates.py has its OWN Python port of
# install_sandbox_mcp_binary (defined in that script itself, not here, since
# it's not shared with check-upstream-updates.py) -- it does not import this
# from _python_common.py.
#
# Unlike the earlier is_lang_ja/pick/msg helpers (which take their state as
# an explicit parameter, e.g. pick(lang_ja, ...)), these functions don't
# hold hidden module-level state either: call load_startup_config() once and
# thread its "verbosity" value into is_quiet/print_title/etc. yourself,
# mirroring how callers already thread lang_ja through pick()/msg().
#
# Usage: import from this file, e.g.
#   from _python_common import is_lang_ja, pick, msg, write_json_atomic
# ---
# .sandbox/scripts/ 配下のPythonスクリプト用共有ヘルパー。言語判定、
# バイリンガル出力、JSONの原子的書き込み、標準出力の行バッファリング化、
# および _startup_common.sh から移植した詳細度・出力・sync-ignore・
# バックアップ関連のヘルパーを提供する。このディレクトリのbashスクリプトに
# おける _startup_common.sh と同じ役割を果たす -- 各スクリプトで再実装せず、
# ここからimportすること。
#
# ここに移植しているのは、Python移行済みスクリプトが実際に使っている
# _startup_common.sh の関数のみ -- 現時点では _secret-tag.sh 依存グループが
# 必要とする範囲（load_startup_config、is_quiet/is_verbose/is_summary、
# print_title/print_footer/print_default/print_error、
# load_sync_ignore_patterns/matches_sync_ignore/add_sync_ignore_pattern、
# backup_file/cleanup_backups）、print_detail/print_warning
# （merge-claude-settings.py用に追加）、および debug_log/read_state_timestamp/
# get_last_notified_version/is_first_run/should_check/update_state/
# build_api_url/extract_tag_from_json/fetch_latest_release
# （check-upstream-updates.py / check-sandbox-mcp-updates.py 用に追加した
# 更新チェックヘルパー。両スクリプトで共有）。_startup_common.sh の残りの関数
# （README URL ヘルパー、print_summary、install_sandbox_mcp_binary/
# install_hostmcp_binary バイナリインストール系ヘルパー -- どちらも
# startup.sh自身（bashのまま）が直接呼ぶため、引き続きそちらに必要）は、
# まだ移行していないスクリプトのためのもの、または移行状況に関わらず
# bash側に残る必要があるもの。それらを移行するタイミングで必要な分を
# 追加する（先回りしてファイル全体を移植しない）。なお
# check-sandbox-mcp-updates.py は install_sandbox_mcp_binary の独自Python版を
# 持っている（check-upstream-updates.py と共有しないため、_python_common.py
# ではなくそのスクリプト自身に定義）-- ここからimportしているわけではない。
#
# 先に追加した is_lang_ja/pick/msg ヘルパー（状態を pick(lang_ja, ...) の
# ように明示的な引数として受け取る）と同様、これらの関数も隠れた
# モジュールレベルの状態を持たない: load_startup_config() を一度呼び、
# 返り値の "verbosity" を is_quiet/print_title などへ自分で渡すこと。
# lang_ja を pick()/msg() へ渡す既存の呼び出し方と同じ考え方である。
#
# 使用法: このファイルからimportする。例:
#   from _python_common import is_lang_ja, pick, msg, write_json_atomic

import fnmatch
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

# A script that mixes its own print() output with a subprocess that inherits
# stdout (e.g. `git log`), or with its own err()/die() writes to stderr, gets
# interleaved out of order under the default block-buffering used when
# stdout isn't a tty (e.g. piped into a file or MCP tool capture): the
# subprocess/stderr writes go straight through while print() output sits in
# Python's buffer until it's flushed. Switching to line buffering here, at
# import time, avoids that for every script that imports this module.
#
# print()を子プロセスの継承した標準出力（例: `git log`）や自身の
# err()/die()（標準エラー出力）と混在させると、標準出力がtty出ない場合
# （ファイルやMCPツールのキャプチャへのパイプなど）のデフォルトの
# ブロックバッファリングにより出力順序が入れ替わってしまう。
# サブプロセスやstderrへの書き込みはそのまま素通りする一方、print()の出力は
# flushされるまでPythonのバッファに留まるためである。ここ（import時）で
# 行バッファリングに切り替えておくことで、このモジュールをimportする
# 全スクリプトでこの問題を回避できる。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(line_buffering=True)


def is_lang_ja() -> bool:
    return os.environ.get("LANG", "").startswith("ja_JP") or os.environ.get("LC_ALL", "").startswith("ja_JP")


def pick(lang_ja: bool, en: str, ja: str) -> str:
    return ja if lang_ja else en


def msg(lang_ja: bool, en: str, ja: str) -> None:
    print(pick(lang_ja, en, ja))


def write_json_atomic(target: Path, data) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.parent / f"{target.name}.tmp.{os.getpid()}"
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(target)


# ─── Startup config / 起動設定 ──────────────────────────────────

def _workspace_dir() -> Path:
    return Path(os.environ.get("WORKSPACE", "/workspace"))


def parse_simple_conf(path: Path) -> dict:
    """Parses the simple KEY="value" / KEY=value (# comments, blank lines
    ignored) format used by every file under .sandbox/config/*.conf.
    Returns {} if `path` doesn't exist. Values are returned as raw strings
    (quotes stripped, no further resolution) -- env-var precedence and
    defaults are each caller's own concern.

    .sandbox/config/*.conf 共通の単純な KEY="value" / KEY=value 形式
    （#コメント・空行は無視）をパースする。`path` が存在しなければ {} を返す。
    値は生の文字列のまま返す（クォート除去のみ、それ以上の解決はしない）--
    環境変数優先やデフォルト値は呼び出し側の責務。
    """
    if not path.is_file():
        return {}
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        values[key] = val
    return values


def load_startup_config() -> dict:
    """Reads .sandbox/config/startup.conf, then lets the matching
    environment variable win over whatever the config file says --
    SANDBOX_README_URL/SANDBOX_README_URL_JA for the URL fields (note the
    differing env-var vs. config-key name), STARTUP_VERBOSITY/
    BACKUP_KEEP_COUNT for the other two (same name in both places). Falls
    back to README.md/README.ja.md/verbose/0 if neither the env var nor the
    config file sets a value.

    .sandbox/config/startup.conf を読み込み、対応する環境変数が設定ファイルの
    値より優先されるようにする -- URL系フィールドは
    SANDBOX_README_URL/SANDBOX_README_URL_JA（環境変数名と設定キー名が異なる
    点に注意）、残り2つは STARTUP_VERBOSITY/BACKUP_KEEP_COUNT（環境変数名と
    設定キー名が同じ）。環境変数にも設定ファイルにも値が無ければ
    README.md/README.ja.md/verbose/0 にフォールバックする。
    """
    config_path = _workspace_dir() / ".sandbox" / "config" / "startup.conf"
    file_values = parse_simple_conf(config_path)

    def resolved(env_name: str, file_key: str, default: str) -> str:
        return os.environ.get(env_name) or file_values.get(file_key) or default

    return {
        "readme_url": resolved("SANDBOX_README_URL", "README_URL", "README.md"),
        "readme_url_ja": resolved("SANDBOX_README_URL_JA", "README_URL_JA", "README.ja.md"),
        "verbosity": resolved("STARTUP_VERBOSITY", "STARTUP_VERBOSITY", "verbose"),
        "backup_keep_count": resolved("BACKUP_KEEP_COUNT", "BACKUP_KEEP_COUNT", "0"),
    }


# ─── Verbosity helpers / 詳細度ヘルパー ─────────────────────────

def is_quiet(verbosity: str) -> bool:
    return verbosity == "quiet"


def is_verbose(verbosity: str) -> bool:
    return verbosity == "verbose"


def is_summary(verbosity: str) -> bool:
    return verbosity == "summary"


def print_title(title: str, verbosity: str) -> None:
    if is_quiet(verbosity):
        return
    print()
    print("━" * 60)
    print(title)
    print("━" * 60)
    if is_verbose(verbosity):
        print()


def print_footer(verbosity: str) -> None:
    if is_quiet(verbosity):
        return
    print("━" * 60)
    print()


def print_default(text: str, verbosity: str) -> None:
    if not is_quiet(verbosity):
        print(text)


def print_detail(text: str, verbosity: str) -> None:
    if is_verbose(verbosity):
        print(text)


def print_warning(text: str) -> None:
    print(f"⚠️  {text}")


def print_error(text: str) -> None:
    print(f"❌ {text}", file=sys.stderr)


# ─── Sync-ignore / Sync-ignore ───────────────────────────────────

def load_sync_ignore_patterns() -> list:
    sync_ignore_file = _workspace_dir() / ".sandbox" / "config" / "sync-ignore"
    if not sync_ignore_file.is_file():
        return []
    patterns = []
    for line in sync_ignore_file.read_text().splitlines():
        if line.startswith("#"):
            continue
        if line.strip() == "":
            continue
        patterns.append(line)
    return patterns


def matches_sync_ignore(file_path: str) -> bool:
    """Usage: matches_sync_ignore("/workspace/path/to/file")
    使用法: matches_sync_ignore("/workspace/path/to/file")
    """
    prefix = str(_workspace_dir()) + "/"
    rel_path = file_path[len(prefix):] if file_path.startswith(prefix) else file_path
    filename = os.path.basename(file_path)

    for pattern in load_sync_ignore_patterns():
        if not pattern:
            continue

        if pattern.startswith("**/"):
            # **/*.example -> matches any file ending with .example
            # **/*.sample -> matches any file ending with .sample
            suffix = pattern[len("**/"):]
            if suffix.startswith("*"):
                ext = suffix[1:]
                if filename.endswith(ext):
                    return True
            elif rel_path.endswith(suffix):
                return True
        elif pattern.endswith("/**"):
            # path/** -> matches anything under path/
            prefix_dir = pattern[:-len("/**")]
            if rel_path.startswith(prefix_dir + "/"):
                return True
        elif "*" in pattern:
            if fnmatch.fnmatchcase(rel_path, pattern):
                return True
        else:
            if rel_path == pattern:
                return True

    return False


def add_sync_ignore_pattern(pattern: str) -> None:
    """Append a pattern to sync-ignore if not already present (idempotent --
    avoids duplicate lines when the same item is triaged twice).

    既に存在しなければ sync-ignore にパターンを追記する（冪等 -- 同じ項目を
    2回トリアージしても重複行が増えない）。
    """
    sync_ignore_file = _workspace_dir() / ".sandbox" / "config" / "sync-ignore"
    if sync_ignore_file.is_file() and pattern in sync_ignore_file.read_text().splitlines():
        return
    sync_ignore_file.parent.mkdir(parents=True, exist_ok=True)
    with open(sync_ignore_file, "a") as f:
        f.write(pattern + "\n")


# ─── Backup utilities / バックアップユーティリティ ───────────────

def backup_file(file_path: str, label: str = "") -> str:
    """Backs up a file into .sandbox/backups/, returning the backup path.

    Example: backup_file(COMPOSE_FILE, "devcontainer")
      -> .sandbox/backups/devcontainer.docker-compose.yml.20260130123456

    ファイルを .sandbox/backups/ にバックアップし、バックアップ先のパスを返す。
    """
    backup_dir = _workspace_dir() / ".sandbox" / "backups"
    backup_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    file_basename = os.path.basename(file_path)
    backup_name = f"{label}.{file_basename}.{timestamp}" if label else f"{file_basename}.{timestamp}"
    backup_path = backup_dir / backup_name
    shutil.copy(file_path, backup_path)
    return str(backup_path)


def cleanup_backups(pattern: str, keep) -> None:
    """Deletes old backups matching `pattern` (a glob relative to
    .sandbox/backups/), keeping only the most recent `keep`. `keep` <= 0 (or
    non-numeric) means unlimited -- no cleanup.

    Usage: cleanup_backups("label.docker-compose.yml.*", keep_count)

    `pattern`（.sandbox/backups/ 内でのglobパターン）にマッチする古い
    バックアップを削除し、直近 `keep` 件のみ保持する。`keep` が0以下
    （または数値でない）場合は無制限（削除しない）。
    """
    try:
        keep_n = int(keep)
    except (TypeError, ValueError):
        return
    if keep_n <= 0:
        return

    backup_dir = _workspace_dir() / ".sandbox" / "backups"
    if not backup_dir.is_dir():
        return

    matches = sorted(backup_dir.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)
    for stale in matches[keep_n:]:
        stale.unlink()


# ─── Update-check helpers / 更新チェックヘルパー ──────────────────
# Shared by check-upstream-updates.py and check-sandbox-mcp-updates.py.
# check-upstream-updates.py と check-sandbox-mcp-updates.py で共有。

def debug_log(message: str, enabled: bool) -> None:
    if enabled:
        print(f"[debug] {message}", file=sys.stderr)


def read_state_timestamp(state_file: Path) -> int:
    if not state_file.is_file():
        return 0
    try:
        return int(state_file.read_text().split(":", 1)[0])
    except (OSError, ValueError):
        return 0


def get_last_notified_version(state_file: Path) -> str:
    if not state_file.is_file():
        return ""
    try:
        text = state_file.read_text()
    except OSError:
        return ""
    _, _, version = text.partition(":")
    return version.strip()


def is_first_run(state_file: Path) -> bool:
    return not state_file.is_file()


def should_check(state_file: Path, interval_hours) -> bool:
    """True if a check is due: `interval_hours` <= 0 (or non-numeric, which
    falls back to 24) always returns True; otherwise True once at least that
    many hours have elapsed since the timestamp recorded in `state_file` (or
    if there's no state file yet).

    チェックすべきタイミングか: `interval_hours` が0以下（または数値でなければ
    24にフォールバック）なら常にTrue。それ以外は `state_file` に記録された
    タイムスタンプから指定時間以上経過していれば（またはまだ状態ファイルが
    無ければ）True。
    """
    try:
        interval = int(interval_hours)
    except (TypeError, ValueError):
        interval = 24
    if interval < 0:
        interval = 24
    if interval == 0:
        return True

    last_check = read_state_timestamp(state_file)
    if last_check != 0:
        elapsed = time.time() - last_check
        if elapsed < interval * 3600:
            return False
    return True


def update_state(state_file: Path, version: str) -> None:
    try:
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(f"{int(time.time())}:{version}\n")
    except OSError:
        pass


def build_api_url(repo: str, channel: str) -> str:
    if channel == "stable":
        return f"https://api.github.com/repos/{repo}/releases/latest"
    return f"https://api.github.com/repos/{repo}/releases?per_page=1"


def extract_tag_from_json(data, channel: str) -> str:
    """`data` is the already-parsed JSON body: a dict for the "stable"
    channel (/releases/latest), a list for any other channel
    (/releases?per_page=1). Returns "" if there's no tag_name to find.

    `data` はパース済みのJSONボディ: "stable"チャンネル（/releases/latest）
    ならdict、それ以外（/releases?per_page=1）ならlist。tag_nameが
    見つからなければ "" を返す。
    """
    if channel == "stable":
        if isinstance(data, dict):
            return data.get("tag_name") or ""
        return ""
    if isinstance(data, list) and data and isinstance(data[0], dict):
        return data[0].get("tag_name") or ""
    return ""


def fetch_latest_release(repo: str, channel: str, timeout: float = 3.0):
    """Fetches the latest release tag for `repo` from the GitHub API.

    Returns the tag name, "" if the fetch succeeded but no release/tag was
    found, or None if the fetch itself failed (network error, timeout,
    non-2xx status, invalid JSON) -- callers must treat "" and None
    differently, matching the bash original: a genuine fetch failure should
    not update the state file's timestamp (so the next check retries sooner
    rather than waiting a full interval), while a successful-but-empty
    result should.

    Approximates the bash original's `curl --connect-timeout 1 --max-time 3`
    with a single `timeout` (urllib has no separate connect/total budget);
    inconsequential here since GitHub's release-list endpoint doesn't
    redirect in practice, but note urllib follows redirects by default while
    the original curl call (no `-L`) did not.

    GitHub APIから `repo` の最新リリースタグを取得する。

    取得成功しタグが見つかればそのタグ名、取得は成功したがリリース/タグが
    見つからなければ ""、取得自体が失敗（ネットワークエラー、タイムアウト、
    2xx以外のステータス、不正なJSON）した場合は None を返す -- 呼び出し側は
    "" と None を区別して扱う必要がある（bash版と同じ）: 本当の取得失敗では
    状態ファイルのタイムスタンプを更新しない（次回チェックが1インターバル
    待たされず、すぐ再試行できるようにする）が、成功したが空だった場合は
    更新する。

    bash版の `curl --connect-timeout 1 --max-time 3` を単一の `timeout` で
    近似している（urllibには接続用/全体用の別々のタイムアウトが無い）。
    GitHubのリリース一覧APIは実際にはリダイレクトしないため実害は無いが、
    元のcurl呼び出し（`-L`なし）と異なり、urllibはデフォルトでリダイレクトに
    従う点に注意。
    """
    url = build_api_url(repo, channel)
    req = urllib.request.Request(url, headers={"User-Agent": "ai-sandbox-update-check"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return None
            data = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, ValueError, OSError, UnicodeDecodeError):
        return None
    return extract_tag_from_json(data, channel)

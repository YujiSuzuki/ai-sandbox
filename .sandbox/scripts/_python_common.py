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
# the _secret-tag.sh-dependent group (load_startup_config, is_quiet/
# is_verbose/is_summary, print_title/print_footer/print_default/print_error,
# load_sync_ignore_patterns/matches_sync_ignore/add_sync_ignore_pattern,
# backup_file/cleanup_backups). _startup_common.sh's remaining functions
# (README URL helpers, print_summary/print_detail/print_warning, and the
# update-check/binary-install helpers used by check-upstream-updates.sh /
# check-sandbox-mcp-updates.sh / startup.sh) belong to scripts that haven't
# been migrated yet -- add them here if/when those scripts are ported,
# rather than porting the whole file speculatively.
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
# backup_file/cleanup_backups）。_startup_common.sh の残りの関数（README URL
# ヘルパー、print_summary/print_detail/print_warning、
# check-upstream-updates.sh / check-sandbox-mcp-updates.sh / startup.sh が
# 使う更新チェック・バイナリインストール系ヘルパー）は、まだ移行していない
# スクリプトのためのものなので、それらを移行するタイミングで追加する
# （先回りしてファイル全体を移植しない）。
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


def load_startup_config() -> dict:
    """Reads .sandbox/config/startup.conf (simple KEY="value" / KEY=value
    lines, # comments), then lets the matching environment variable win over
    whatever the config file says -- SANDBOX_README_URL/SANDBOX_README_URL_JA
    for the URL fields (note the differing env-var vs. config-key name),
    STARTUP_VERBOSITY/BACKUP_KEEP_COUNT for the other two (same name in both
    places). Falls back to README.md/README.ja.md/verbose/0 if neither the
    env var nor the config file sets a value.

    .sandbox/config/startup.conf（単純な KEY="value" / KEY=value 行、
    #コメント）を読み込み、対応する環境変数が設定ファイルの値より優先されるよう
    にする -- URL系フィールドは SANDBOX_README_URL/SANDBOX_README_URL_JA
    （環境変数名と設定キー名が異なる点に注意）、残り2つは
    STARTUP_VERBOSITY/BACKUP_KEEP_COUNT（環境変数名と設定キー名が同じ）。
    環境変数にも設定ファイルにも値が無ければ README.md/README.ja.md/verbose/0
    にフォールバックする。
    """
    config_path = _workspace_dir() / ".sandbox" / "config" / "startup.conf"
    file_values = {}
    if config_path.is_file():
        for line in config_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if not m:
                continue
            key, val = m.group(1), m.group(2).strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                val = val[1:-1]
            file_values[key] = val

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

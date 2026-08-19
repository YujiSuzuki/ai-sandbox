#!/usr/bin/env python3
# _python_common.py
# Shared helpers for .sandbox/scripts/ Python scripts: language detection,
# bilingual message output, atomic JSON writes, and stdout line-buffering.
# Plays the same role for Python scripts in this directory that
# _startup_common.sh plays for bash scripts here -- import it, don't
# re-implement these per script.
#
# Usage: import from this file, e.g.
#   from _python_common import is_lang_ja, pick, msg, write_json_atomic
# ---
# .sandbox/scripts/ 配下のPythonスクリプト用共有ヘルパー。言語判定、
# バイリンガル出力、JSONの原子的書き込み、標準出力の行バッファリング化を
# 提供する。このディレクトリのbashスクリプトにおける _startup_common.sh と
# 同じ役割を果たす -- 各スクリプトで再実装せず、ここからimportすること。
#
# 使用法: このファイルからimportする。例:
#   from _python_common import is_lang_ja, pick, msg, write_json_atomic

import json
import os
import sys
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

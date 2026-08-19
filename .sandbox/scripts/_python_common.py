#!/usr/bin/env python3
# _python_common.py
# Shared helpers for .sandbox/scripts/ Python scripts: language detection,
# bilingual message output, and atomic JSON writes. Plays the same role for
# Python scripts in this directory that _startup_common.sh plays for bash
# scripts here -- import it, don't re-implement these per script.
#
# Usage: import from this file, e.g.
#   from _python_common import is_lang_ja, pick, msg, write_json_atomic
# ---
# .sandbox/scripts/ 配下のPythonスクリプト用共有ヘルパー。言語判定、
# バイリンガル出力、JSONの原子的書き込みを提供する。このディレクトリの
# bashスクリプトにおける _startup_common.sh と同じ役割を果たす -- 各
# スクリプトで再実装せず、ここからimportすること。
#
# 使用法: このファイルからimportする。例:
#   from _python_common import is_lang_ja, pick, msg, write_json_atomic

import json
import os
from pathlib import Path


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

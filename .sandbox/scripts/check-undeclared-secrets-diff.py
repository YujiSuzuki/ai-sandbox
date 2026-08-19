#!/usr/bin/env python3
# check-undeclared-secrets-diff.py
# Wraps check-undeclared-secrets.sh --format json: compares this run's
# undeclared-file set against the previous recorded run and reports only
# paths that are NEW in that set (a set difference, not a count comparison --
# a file swap that keeps the total count the same still counts as new).
# Silent when there is nothing new to report. On the very first run (no
# prior state yet), the previous set is treated as empty, so it reports
# every currently-undeclared file -- giving full visibility right from the
# start.
#
# Two-file outbox scheme: STATE_FILE is the CONFIRMED baseline diffs are
# always computed against; PENDING_FILE holds the latest full scan whenever
# there's a newly-detected, not-yet-confirmed finding. STATE_FILE is only
# advanced once delivery is proven -- this script itself never confirms
# anything on detection, it only ever mirrors outstanding findings into
# PENDING_FILE. Confirmation (promoting PENDING_FILE -> STATE_FILE) is done
# externally by setup-output-reminder.sh's "@confirm-target" handling, once
# the AI touches "<name>.resolved" for this notice -- i.e. once the AI has
# actually confirmed telling the human, not merely once the notice has been
# embedded (see its header comment). Leaving STATE_FILE untouched until then
# means an unconfirmed finding keeps being reported as new on every
# subsequent invocation instead of silently disappearing if delivery never
# happens.
# ---
# check-undeclared-secrets.sh --format json をラップし、今回の未宣言ファイル
# 集合を前回記録と比較して、その集合の中で「新規」のパスのみを報告する
# （件数比較ではなく集合差分 -- 合計件数が変わらないファイルの入れ替えでも
# 新規として検出する）。報告すべき新規がなければ無出力。初回実行（まだ前回
# 記録がない）時は前回集合を空として扱うため、その時点の未宣言ファイルを
# 最初から漏れなく報告する。
#
# 2ファイル制のアウトボックス方式: diffの比較元は常にCONFIRMED済みの
# STATE_FILE。新規検知があり未確定の間は、今回のフルスキャンを
# PENDING_FILEへミラーする。STATE_FILEは配送が証明されるまで進めない --
# 本スクリプト自身は検知した瞬間に何かを確定させることはなく、未確定分を
# PENDING_FILEへミラーするだけ。確定(PENDING_FILE -> STATE_FILEへの昇格)は
# setup-output-reminder.shの"@confirm-target"処理が外部で行う。この通知の
# "<name>.resolved"をAIがtouchした時点 -- つまり通知がembedされた時点では
# なく、AIが実際に人間へ伝えたことを確認した時点(そのヘッダーコメント
# 参照)。STATE_FILEをそれまで据え置くことで、未確定の検知は配送されない
# 限り黙って消えるのではなく、毎回「新規」として再報告され続ける。

import json
import os
import subprocess
import sys
from pathlib import Path

WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
CHECK_SCRIPT = Path(os.environ.get("CHECK_SCRIPT", str(WORKSPACE / ".sandbox" / "scripts" / "check-undeclared-secrets.sh")))
STATE_FILE = Path(os.environ.get("STATE_FILE", str(WORKSPACE / ".sandbox" / ".state" / "check-undeclared-secrets.json")))
PENDING_FILE = Path(os.environ.get("PENDING_FILE", str(WORKSPACE / ".sandbox" / ".state" / "check-undeclared-secrets.pending.json")))


def is_lang_ja() -> bool:
    return os.environ.get("LANG", "").startswith("ja_JP") or os.environ.get("LC_ALL", "").startswith("ja_JP")


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def load_json_str(text: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def write_json_atomic(target: Path, data) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(target)


def main() -> None:
    if not os.access(CHECK_SCRIPT, os.X_OK):
        sys.exit(0)

    try:
        result = subprocess.run(
            [str(CHECK_SCRIPT), "--format", "json"],
            capture_output=True, text=True,
        )
    except OSError:
        sys.exit(0)
    if result.returncode != 0:
        sys.exit(0)

    current = load_json_str(result.stdout)
    if current is None:
        sys.exit(0)

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)

    # No prior state, or prior state is corrupted -- treat the previous set
    # as empty, so this run reports the currently-undeclared files and gives
    # full visibility from the very first run.
    # 前回記録がない、または壊れている -- 前回集合を空として扱う。これにより
    # 初回実行時から今回の未宣言ファイルをそのまま報告し、最初から漏れなく
    # 把握できる。
    prev = load_json(STATE_FILE) if STATE_FILE.is_file() else None
    prev_undeclared = prev.get("undeclared", []) if isinstance(prev, dict) else []

    curr_undeclared = current["undeclared"]
    curr_claude_only = current.get("claude_only", [])

    prev_set = set(prev_undeclared)
    new_paths = [p for p in curr_undeclared if p not in prev_set]

    if not new_paths:
        # Nothing new vs. the confirmed baseline: safe to fold this scan
        # straight into STATE_FILE (there is no unconfirmed finding to
        # protect here), and any pending snapshot left by an earlier
        # still-unconfirmed run is now moot -- everything it named is either
        # already confirmed or no longer undeclared.
        # 確定済みbaselineと比べて新規なし: 保護すべき未確定の検知が無いため、
        # 今回のスキャンをそのままSTATE_FILEへ確定してよい。以前の未確定run
        # が残していたpendingスナップショットも、その中身は既に確定済みか、
        # もはや未宣言でなくなっているかのどちらかなので、意味を失っている。
        write_json_atomic(STATE_FILE, current)
        PENDING_FILE.unlink(missing_ok=True)
        sys.exit(0)

    # New findings exist but delivery is not yet proven: mirror them into
    # the pending/outbox file, never into STATE_FILE (see header comment).
    # 新規検知はあるが配送はまだ証明されていない: STATE_FILEではなく
    # pending/アウトボックスファイルへミラーする(ヘッダーコメント参照)。
    write_json_atomic(PENDING_FILE, current)

    claude_only_set = set(curr_claude_only)
    if is_lang_ja():
        print("⚠️  前回チェック時にはなかった、未宣言の秘密っぽいファイルが見つかりました:")
        claude_only_note = "（.claude/settings.json では既にカバー済み。ただしdocker-compose.ymlのようにファイル内容自体を隠すものではありません）"
    else:
        print("⚠️  New undeclared secret-like files found since the last check:")
        claude_only_note = "(already covered by .claude/settings.json -- but that doesn't hide the file's content the way docker-compose.yml does)"

    for path in new_paths:
        if path in claude_only_set:
            print(f"   📄 {path}  {claude_only_note}")
        else:
            print(f"   📄 {path}")

    if is_lang_ja():
        print("詳細: .sandbox/scripts/check-undeclared-secrets.sh / 対処: .sandbox/scripts/triage-undeclared-secrets.sh（1件ずつ確認しながら処理します。名前パターンによる検出のため、内容を確認のうえ選択してください）")
        print("→ AIへ: このメッセージは必ず今回の最初の返信でユーザーに伝えてください。対処（.sandbox/config/sync-ignore への追加・削除など）は必ずユーザーの確認を得てから行い、AI単独で判断・実行しないでください。")
    else:
        print("For details, run: .sandbox/scripts/check-undeclared-secrets.sh -- to act on findings, run: .sandbox/scripts/triage-undeclared-secrets.sh (reviews each item interactively; detected by name pattern only, so check the content before choosing)")
        print("-> AI: mention this in your first reply to the user this session, even if unrelated to their question. Do not remediate (add to .sandbox/config/sync-ignore, delete, etc.) without explicit user confirmation.")

    sys.exit(0)


if __name__ == "__main__":
    main()

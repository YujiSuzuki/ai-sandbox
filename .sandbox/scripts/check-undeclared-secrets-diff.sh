#!/bin/bash
# check-undeclared-secrets-diff.sh
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

set -e

WORKSPACE="${WORKSPACE:-/workspace}"
CHECK_SCRIPT="${CHECK_SCRIPT:-$WORKSPACE/.sandbox/scripts/check-undeclared-secrets.sh}"
STATE_FILE="${STATE_FILE:-$WORKSPACE/.sandbox/.state/check-undeclared-secrets.json}"
PENDING_FILE="${PENDING_FILE:-$WORKSPACE/.sandbox/.state/check-undeclared-secrets.pending.json}"

command -v jq &>/dev/null || exit 0
[ -x "$CHECK_SCRIPT" ] || exit 0

current_json=$("$CHECK_SCRIPT" --format json 2>/dev/null) || exit 0
echo "$current_json" | jq -e . > /dev/null 2>&1 || exit 0

mkdir -p "$(dirname "$STATE_FILE")"

# No prior state, or prior state is corrupted -- treat the previous set as
# empty, so this run reports the currently-undeclared files and gives full
# visibility from the very first run.
# 前回記録がない、または壊れている -- 前回集合を空として扱う。これにより
# 初回実行時から今回の未宣言ファイルをそのまま報告し、最初から漏れなく
# 把握できる。
if [ ! -f "$STATE_FILE" ] || ! jq -e . "$STATE_FILE" > /dev/null 2>&1; then
    prev_undeclared="[]"
else
    prev_undeclared=$(jq -c '.undeclared // []' "$STATE_FILE")
fi
curr_undeclared=$(echo "$current_json" | jq -c '.undeclared')
curr_claude_only=$(echo "$current_json" | jq -c '.claude_only // []')

new_paths_json=$(jq -n --argjson curr "$curr_undeclared" --argjson prev "$prev_undeclared" '$curr - $prev')
new_count=$(echo "$new_paths_json" | jq 'length')

if [ "$new_count" -eq 0 ]; then
    # Nothing new vs. the confirmed baseline: safe to fold this scan
    # straight into STATE_FILE (there is no unconfirmed finding to protect
    # here), and any pending snapshot left by an earlier still-unconfirmed
    # run is now moot -- everything it named is either already confirmed or
    # no longer undeclared.
    # 確定済みbaselineと比べて新規なし: 保護すべき未確定の検知が無いため、
    # 今回のスキャンをそのままSTATE_FILEへ確定してよい。以前の未確定runが
    # 残していたpendingスナップショットも、その中身は既に確定済みか、もはや
    # 未宣言でなくなっているかのどちらかなので、意味を失っている。
    echo "$current_json" | jq '.' > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    rm -f "$PENDING_FILE"
    exit 0
fi

# New findings exist but delivery is not yet proven: mirror them into the
# pending/outbox file, never into STATE_FILE (see header comment).
# 新規検知はあるが配送はまだ証明されていない: STATE_FILEではなく
# pending/アウトボックスファイルへミラーする(ヘッダーコメント参照)。
mkdir -p "$(dirname "$PENDING_FILE")"
echo "$current_json" | jq '.' > "$PENDING_FILE.tmp" && mv "$PENDING_FILE.tmp" "$PENDING_FILE"

if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    echo "⚠️  前回チェック時にはなかった、未宣言の秘密っぽいファイルが見つかりました:"
    claude_only_note="（.claude/settings.json では既にカバー済み。ただしdocker-compose.ymlのようにファイル内容自体を隠すものではありません）"
else
    echo "⚠️  New undeclared secret-like files found since the last check:"
    claude_only_note="(already covered by .claude/settings.json -- but that doesn't hide the file's content the way docker-compose.yml does)"
fi

while IFS=$'\t' read -r path is_claude_only; do
    if [ "$is_claude_only" = "true" ]; then
        echo "   📄 $path  $claude_only_note"
    else
        echo "   📄 $path"
    fi
done < <(jq -n -r --argjson new "$new_paths_json" --argjson claude_only "$curr_claude_only" \
    '$new[] as $p | [$p, (($claude_only | index($p)) != null | tostring)] | @tsv')

if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    echo "詳細と対処方法: .sandbox/scripts/check-undeclared-secrets.sh を実行（名前パターンによる検出のため、内容を確認のうえ対処してください）"
    echo "→ AIへ: このメッセージは必ず今回の最初の返信でユーザーに伝えてください。対処（.sandbox/config/sync-ignore への追加・削除など）は必ずユーザーの確認を得てから行い、AI単独で判断・実行しないでください。"
else
    echo "For details and remediation options, run: .sandbox/scripts/check-undeclared-secrets.sh (detected by name pattern -- review the content before acting)"
    echo "-> AI: mention this in your first reply to the user this session, even if unrelated to their question. Do not remediate (add to .sandbox/config/sync-ignore, delete, etc.) without explicit user confirmation."
fi

exit 0

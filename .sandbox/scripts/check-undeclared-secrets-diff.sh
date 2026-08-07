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
# ---
# check-undeclared-secrets.sh --format json をラップし、今回の未宣言ファイル
# 集合を前回記録と比較して、その集合の中で「新規」のパスのみを報告する
# （件数比較ではなく集合差分 -- 合計件数が変わらないファイルの入れ替えでも
# 新規として検出する）。報告すべき新規がなければ無出力。初回実行（まだ前回
# 記録がない）時は前回集合を空として扱うため、その時点の未宣言ファイルを
# 最初から漏れなく報告する。

set -e

WORKSPACE="${WORKSPACE:-/workspace}"
CHECK_SCRIPT="${CHECK_SCRIPT:-$WORKSPACE/.sandbox/scripts/check-undeclared-secrets.sh}"
STATE_FILE="${STATE_FILE:-$WORKSPACE/.sandbox/.state/check-undeclared-secrets.json}"

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

# Always record the latest scan, whether or not it triggers a notification,
# so the next run diffs against what's actually current.
# 通知の有無に関わらず今回のスキャンを記録し、次回はそれを基準に比較する。
echo "$current_json" > "$STATE_FILE"

new_count=$(echo "$new_paths_json" | jq 'length')
[ "$new_count" -eq 0 ] && exit 0

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
    echo "→ AIへ: このメッセージは必ず今回の最初の返信でユーザーに伝えてください。対処（.gitignoreへの追加・削除など）は必ずユーザーの確認を得てから行い、AI単独で判断・実行しないでください。"
else
    echo "For details and remediation options, run: .sandbox/scripts/check-undeclared-secrets.sh (detected by name pattern -- review the content before acting)"
    echo "-> AI: mention this in your first reply to the user this session, even if unrelated to their question. Do not remediate (add to .gitignore, delete, etc.) without explicit user confirmation."
fi

exit 0

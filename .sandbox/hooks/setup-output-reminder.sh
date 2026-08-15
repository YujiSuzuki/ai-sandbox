#!/bin/bash
# setup-output-reminder.sh
# UserPromptSubmit hook: sandbox-mcp's "@output: file" setup scripts spill
# their stdout to .sandbox/.state/setup-output/sandbox-mcp-pids/<pid>/*.txt
# instead of the MCP initialize instructions field (byte-limit workaround,
# see runSetupScripts() in mainte/sandbox-mcp/internal/server/server.go). The
# one-line pointer left in instructions is easy to miss among other
# system-reminders, so this hook inlines the actual file contents as
# additionalContext once per setup-output directory -- there is no plain
# path left to skip past.
#
# Files whose setup script is tagged "@notify: persistent" (see
# .sandbox/sandbox-mcp-setup/*.sh headers, same comment-tag convention as
# "@output: file") are excluded from that one-shot dump and instead get
# their own repeated reminder, separate and higher-signal, on every turn
# until either the AI marks it resolved (touches the "<name>.resolved"
# marker file next to the source .txt) or a repeat cap is hit. This exists
# because a one-shot dump mixed with 7 other FYI-only files turned out to
# be easy for the AI to miss for an item that actually required action.
#
# Known limitation: when multiple sandbox-mcp connections are alive at
# once (e.g. several VS Code windows on the same workspace), "newest
# mtime among alive PIDs" is a best-effort guess at "this session's
# process", not a guaranteed match -- there is no session_id/PID link
# available to do better. Accepted as out of scope.
#
# A setup script whose repeated notice corresponds to not-yet-confirmed
# state on disk can additionally declare "@confirm-target: <workspace-
# relative path>" alongside "@notify: persistent". Once the AI touches
# "<name>.resolved" -- the same marker that stops the repeat above, i.e.
# once the AI has actually confirmed telling the human, not merely once the
# notice has been embedded -- this hook promotes a pending file living
# right next to the spilled .txt (named "<name>.pending.json", by
# convention -- never a tag-declared absolute path) into the @confirm-target
# path, merging its "undeclared" entries into whatever is already there
# rather than overwriting wholesale (see below for why). This exists for
# producer scripts where writing confirmed state unconditionally right
# after detection, rather than only once delivery is proven, risks silently
# losing a finding if the session ends before any prompt is ever sent, or
# if the AI reads the notice but never actually relays it to the human (see
# 25-undeclared-secrets-diff.sh / check-undeclared-secrets-diff.sh for the
# concrete case this was built for). Keeping the pending file scoped to
# this notice's own PID directory -- rather than a single shared path --
# means one session's promotion always reads only its own candidates, never
# a different, concurrently-alive session's. That alone isn't quite enough,
# though: each session's pending file is a snapshot frozen at connect time,
# so a slower session resolving after a faster one has already promoted a
# fuller snapshot could otherwise clobber that newer confirmation with its
# own stale one -- merging (union of "undeclared") rather than overwriting
# is what keeps promotion monotonic (it can only grow the confirmed set,
# never roll it back) regardless of resolution order across sessions.
# ---
# UserPromptSubmit hook: sandbox-mcpの"@output: file"付きセットアップ
# スクリプトは、標準出力をMCPのinitialize instructionsフィールドに
# 直接載せず.sandbox/.state/setup-output/sandbox-mcp-pids/<pid>/*.txt
# へ書き出す(instructionsのバイト上限を避けるための仕組み、
# mainte/sandbox-mcp/internal/server/server.goのrunSetupScripts()参照)。
# instructions内に残る1行の案内は他のsystem-reminderに埋もれて
# 見落とされやすいため、このhookはsetup-outputディレクトリごとに
# 一度だけ、ファイルの中身そのものをadditionalContextへ埋め込む
# --単なるパスの再掲ではないので読み飛ばす余地がない。
#
# 対応するセットアップスクリプトに"@notify: persistent"タグが
# 付いているファイル(.sandbox/sandbox-mcp-setup/*.sh のヘッダー、
# "@output: file"と同じコメントタグ規約)は、この一括ダンプの対象から
# 除外し、代わりに毎ターン独立して繰り返し通知する--AIが対応済みマーカー
# (元の.txtと同じ場所に置く"<name>.resolved")をtouchするか、上限回数に
# 達するまで。7件のFYI専用ファイルと一緒くたの1回きりダンプでは、
# 本来対応が必要な項目でも見落とされ得ることが判明したための対応。
#
# 既知の制限: 同一ワークスペースに複数のsandbox-mcp接続が同時に
# 生存している場合(例: 複数のVS Codeウィンドウ)、「生存PIDの中で
# mtime最新」はあくまで「このセッションのプロセス」の推測であり、
# 確実な一致を保証しない(session_idとPIDを紐付ける手段が無いため)。
# 許容し、スコープ外とする。
#
# 繰り返し通知の内容がディスク上の未確定な状態と対応しているセットアップ
# スクリプトは、"@notify: persistent"と並べて"@confirm-target: <ワーク
# スペース相対パス>"を追加で宣言できる。AIが"<name>.resolved"をtouch
# した時(上の再掲を止めるのと同じマーカー、つまり通知がembedされた
# 時点ではなく、AIが実際に人間へ伝えたことを確認した時)に、このhookは
# spilled .txtと同じ場所にある(タグで宣言された絶対パスではなく、常に
# "<name>.pending.json"という命名規則の)pendingファイルを@confirm-target
# パスへ昇格させる。その際、丸ごと上書きするのではなく、"undeclared"の
# 内容を既存分とマージする(理由は下記)。これは、検知直後に無条件で
# 状態を確定してしまうと(配送が証明されるまで待たない場合)、プロンプト
# が一度も送られないままセッションが終わった場合や、AIが通知を読んでも
# 実際には人間へ伝えなかった場合に、検知が黙って失われてしまう、という
# プロデューサー側スクリプトのためにある(具体例は25-undeclared-secrets-diff.sh
# / check-undeclared-secrets-diff.sh 参照)。pendingファイルを単一の
# 共有パスではなく、この通知自身のPIDディレクトリに閉じ込めることで、
# あるセッションの昇格は常に自分自身の候補だけを読み、同時に生存して
# いる別セッションのものを読むことはない。ただしそれだけでは不十分で、
# 各セッションのpendingファイルは接続時点で固定されたスナップショット
# であるため、より新しいスナップショットを先に昇格させた速いセッション
# の後から、遅いセッションが古いスナップショットで昇格すると、その
# 新しい確定内容を巻き戻してしまいかねない -- "undeclared"を和集合で
# マージ(上書きではなく)することで、セッション間の解決順序に関わらず
# 昇格を単調(確定済み集合を拡張するだけで、決して縮小させない)に保つ。

set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
OUTPUT_BASE="$WORKSPACE_ROOT/.sandbox/.state/setup-output/sandbox-mcp-pids"
SETUP_SCRIPTS_DIR="$WORKSPACE_ROOT/.sandbox/sandbox-mcp-setup"
PERSISTENT_NOTIFY_CAP="${PERSISTENT_NOTIFY_CAP:-5}"

emit_empty() {
    printf '{}'
    exit 0
}

# True if the setup script matching a spilled .txt file's basename is
# tagged "@notify: persistent" in its leading comment header. Mirrors (but
# does not reuse -- different language/binary) the Go-side @output: file
# parser: skip shebang/blank lines, stop scanning at the first non-comment
# line.
# 対応するセットアップスクリプトのヘッダーに"@notify: persistent"タグが
# あるか判定する。Go側の@output: fileパーサーと同じ規約をbashで踏襲
# (コード共有はしていない): シバン/空行はスキップ、最初の非コメント行で
# 走査を打ち切る。
has_persistent_tag() {
    local sh_file="$1"
    [ -f "$sh_file" ] || return 1
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [ "$line_num" -eq 1 ] && [[ "$line" == "#!"* ]]; then
            continue
        fi
        [ -z "${line// }" ] && continue
        [[ "$line" == "#"* ]] || break
        local content="${line#\#}"
        content="${content# }"
        if [[ "$content" == "@notify:"* ]]; then
            local value="${content#@notify:}"
            value="${value# }"
            value="${value%% *}"
            [ "$value" = "persistent" ] && return 0
        fi
    done < "$sh_file"
    return 1
}

# Reads the value of an arbitrary "@tag: value" header comment from a setup
# script, using the exact same scan rules as has_persistent_tag() (skip
# shebang/blank lines, stop at the first non-comment line, value cropped at
# the first space). Prints the value and returns 0 on a match; returns 1
# (printing nothing) if the file is missing, the tag isn't present, or the
# value is empty.
# セットアップスクリプトのヘッダーコメントから任意の"@tag: value"の値を
# 読み取る。has_persistent_tag()と全く同じ走査ルール(シバン/空行スキップ、
# 最初の非コメント行で打ち切り、値は最初の空白で切り詰め)を使う。一致すれば
# 値を出力してreturn 0、ファイルが無い・タグが無い・値が空のいずれかなら
# 何も出力せずreturn 1。
read_header_tag_value() {
    local sh_file="$1" tag="$2"
    [ -f "$sh_file" ] || return 1
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [ "$line_num" -eq 1 ] && [[ "$line" == "#!"* ]]; then
            continue
        fi
        [ -z "${line// }" ] && continue
        [[ "$line" == "#"* ]] || break
        local content="${line#\#}"
        content="${content# }"
        if [[ "$content" == "${tag}:"* ]]; then
            local value="${content#${tag}:}"
            value="${value# }"
            value="${value%% *}"
            [ -n "$value" ] || return 1
            printf '%s' "$value"
            return 0
        fi
    done < "$sh_file"
    return 1
}

[ -d "$OUTPUT_BASE" ] || emit_empty
command -v jq &> /dev/null || emit_empty

# Opportunistically prune stray *.notified markers left behind by PIDs
# that are no longer alive (sandbox-mcp's own pruneStaleOutputDirs only
# removes the PID directory itself, not our sibling marker).
# 生存していないPIDの野良*.notifiedマーカーを軽く掃除する
# (sandbox-mcp側のpruneStaleOutputDirsはPIDディレクトリ本体しか
# 消さないため)。
for marker in "$OUTPUT_BASE"/*.notified; do
    [ -e "$marker" ] || continue
    marker_pid="$(basename "$marker" .notified)"
    [[ "$marker_pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$marker_pid" 2>/dev/null || rm -f "$marker"
done

# Find the alive PID directory with the newest mtime.
# 生存しているPIDディレクトリのうちmtimeが最新のものを選ぶ。
best_dir=""
best_mtime=-1
for dir in "$OUTPUT_BASE"/*/; do
    [ -d "$dir" ] || continue
    pid="$(basename "$dir")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue

    mtime="$(stat -c '%Y' "$dir" 2>/dev/null || echo -1)"
    if (( mtime > best_mtime )); then
        best_mtime="$mtime"
        best_dir="$dir"
    fi
done

[ -n "$best_dir" ] || emit_empty

marker="${best_dir%/}.notified"

shopt -s nullglob
files=("$best_dir"*.txt)
[ "${#files[@]}" -gt 0 ] || emit_empty

# Split into "@notify: persistent" files (own repeated block below) and
# everything else (goes into the classic one-shot MANDATORY dump).
# "@notify: persistent"付き(下の繰り返しブロック行き)とそれ以外
# (従来の一括MANDATORYダンプ行き)に分ける。
mandatory_files=()
persistent_files=()
for f in "${files[@]}"; do
    sh_file="$SETUP_SCRIPTS_DIR/$(basename "$f" .txt).sh"
    if has_persistent_tag "$sh_file"; then
        persistent_files+=("$f")
    else
        mandatory_files+=("$f")
    fi
done

full_context=""

if [ ! -f "$marker" ] && [ "${#mandatory_files[@]}" -gt 0 ]; then
    context=""
    for f in "${mandatory_files[@]}"; do
        context+=$'\n=== '"$(basename "$f")"$' ===\n'
        context+="$(cat "$f")"
        context+=$'\n'
    done
    header="MANDATORY: sandbox-mcp setup produced the following file(s) at connection start. They were moved out of the MCP instructions field only due to a byte-size limit, not because they are optional. Their full content is reproduced below (not just a path) so it cannot be skipped -- read and apply it now as if it were part of your initial instructions:"
    full_context+="${header}${context}"
    touch "$marker" 2>/dev/null || true
fi

for f in "${persistent_files[@]}"; do
    base="$(basename "$f" .txt)"
    body="$(cat "$f")"
    [ -n "${body// }" ] || continue

    sh_file="$SETUP_SCRIPTS_DIR/${base}.sh"
    resolved="${best_dir%/}/${base}.resolved"

    if [ -f "$resolved" ]; then
        # Promote once the AI has actually confirmed telling the human (by
        # touching .resolved) -- NOT merely once the notice has first been
        # embedded. An AI that reads the notice but forgets to relay it (so
        # never touches .resolved) must not cause the finding to be
        # silently confirmed: it needs to keep resurfacing, in this and
        # future sessions, until someone actually acts on it. Safe to
        # attempt on every call once .resolved exists: after a successful
        # promotion pending_abs no longer exists, so this becomes a no-op
        # (idempotent), and if a promotion attempt fails partway through,
        # pending_abs is only removed as the very last step below, so it
        # survives for a retry on the next call.
        # AIが実際に人間へ伝えたことを確認した時(.resolvedがtouchされた
        # 時)にのみ昇格する -- 通知が最初にembedされた時点ではない。通知を
        # 読んだAIが人間への伝達を忘れた場合(.resolvedを一度もtouchしない
        # 場合)、検知がサイレントに確定されてはならない -- 誰かが実際に
        # 対応するまで、このセッションでも将来のセッションでも再浮上し
        # 続ける必要がある。.resolvedが存在する間は毎回試みても安全:
        # 昇格成功後はpending_absが存在しなくなるため以降は何もしない
        # (冪等)。途中で失敗した場合もpending_absは最後のステップでしか
        # 削除しないため、次回呼び出しで再試行できる。
        target_rel="$(read_header_tag_value "$sh_file" "@confirm-target" 2>/dev/null || true)"
        pending_abs="${best_dir%/}/${base}.pending.json"
        if [ -n "${target_rel:-}" ] && [ -f "$pending_abs" ]; then
            target_abs="$WORKSPACE_ROOT/$target_rel"
            mkdir -p "$(dirname "$target_abs")"
            # Merge into the confirmed set rather than overwriting it: a
            # different, concurrently-alive session may have already
            # promoted its own (possibly more up-to-date) pending snapshot
            # into target_abs. This session's own pending_abs was frozen
            # at connect time and may be stale by comparison -- a plain mv
            # here would silently roll back whatever that other session
            # already confirmed. Unioning "undeclared" means promotion can
            # only ever grow the confirmed baseline, never shrink it.
            # 上書きではなく、確定済み集合へマージする: 別の(同時に生存
            # している)セッションが、自分自身のpendingスナップショット
            # (より新しい可能性がある)を先にtarget_absへ昇格済みかも
            # しれない。このセッション自身のpending_absは接続時点で
            # 固定されたものであり、比較すると古い可能性がある -- ここで
            # 単純にmvしてしまうと、他セッションが既に確定した内容を
            # サイレントに巻き戻してしまう。"undeclared"を和集合で
            # マージすることで、昇格は確定済みbaselineを常に拡張する
            # だけで、決して縮小させない。
            if [ -f "$target_abs" ] && jq -e . "$target_abs" > /dev/null 2>&1; then
                jq -s '.[1] * {undeclared: ((.[0].undeclared // []) + (.[1].undeclared // []) | unique)}' \
                    "$target_abs" "$pending_abs" > "$target_abs.tmp" && mv "$target_abs.tmp" "$target_abs"
            else
                jq '.' "$pending_abs" > "$target_abs.tmp" && mv "$target_abs.tmp" "$target_abs"
            fi
            rm -f "$pending_abs"
        fi
        continue
    fi

    count_file="${best_dir%/}/${base}.notify-count"
    count="$(cat "$count_file" 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [ "$count" -ge "$PERSISTENT_NOTIFY_CAP" ] && continue

    echo "$((count + 1))" > "$count_file"

    full_context+=$'\n\n=== PERSISTENT NOTICE: '"$base"$' ('"$((count + 1))"'/'"$PERSISTENT_NOTIFY_CAP"$') ===\n'
    full_context+="$body"
    full_context+=$'\nThis notice repeats every turn until resolved. Once you have actually done what it asks (e.g. told the user), run: touch "'"$resolved"'"'
done

[ -n "${full_context// }" ] || emit_empty

jq -n -c --arg ctx "$full_context" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'

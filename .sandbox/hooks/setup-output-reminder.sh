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

    resolved="${best_dir%/}/${base}.resolved"
    [ -f "$resolved" ] && continue

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

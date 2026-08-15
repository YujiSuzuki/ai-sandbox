#!/bin/bash
# check-undeclared-secrets.sh
# Warn about files/directories that look like secrets by naming convention
# but are not hidden from AI via docker-compose.yml (Docker volume mount).
# That is the only mechanism that actually removes file content from AI's
# view; .claude/settings.json (permissions.deny) only blocks the Read tool
# and leaves the file itself visible, so it is NOT treated as "declared"
# here -- a path covered solely by permissions.deny still shows up as
# undeclared, annotated with a note that settings.json already covers it.
#
# validate-secrets.sh and check-secret-sync.sh only verify configuration
# that already exists; neither one catches a secret file that was never
# declared anywhere in the first place. This script fills that gap.
#
# This is a heuristic scan based on filename patterns.
#
# Container-only: the docker-compose.yml hidden-file declarations it checks
# against always target the fixed in-container path /workspace/<path>, not
# wherever the repo happens to live on the host, so this comparison is only
# meaningful when $WORKSPACE is actually /workspace (i.e. running inside the
# container where that path is the live mount root).
# @env: container
# ---
# 名前のパターンから「秘密っぽい」ファイル/ディレクトリを検出し、
# docker-compose.yml（Dockerボリュームマウント）で未宣言のものを警告する。
# AIの視界からファイル内容そのものを取り除くのはこの仕組みだけであり、
# .claude/settings.json（permissions.deny）はReadツールを拒否するだけで
# ファイル自体は見える状態のままなので、ここでは「宣言済み」とは扱わない
# -- permissions.denyだけでカバーされているパスも未宣言として表示され、
# settings.jsonで既にカバーされている旨の注記が付く。
#
# validate-secrets.sh と check-secret-sync.sh は「既に存在する設定」を
# 検証するだけで、そもそも一度も宣言されていない秘密ファイルは検出できない。
# このスクリプトはその抜け穴を埋めるためのもの。
#
# これは名前パターンに基づくヒューリスティックな検出です。
#
# コンテナ専用: 照合対象の docker-compose.yml の隠蔽宣言は常にコンテナ内の
# 固定パス /workspace/<path> を指しており、リポジトリがホスト上のどこに
# あるかとは無関係。そのため $WORKSPACE が実際に /workspace であるとき
# （＝コンテナ内で、そのパスが実マウントのルートであるとき）のみ、
# この照合は意味を持つ。

set -e

# Check if running on host OS (not in container)
# ホストOSで実行されていないかチェック
if [[ -z "${SANDBOX_ENV:-}" ]] && [[ ! -f "/.dockerenv" ]]; then
    if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
        echo "❌ このスクリプトはホストOSでは実行できません。"
        echo ""
        echo "以下のいずれかの環境で実行してください："
        echo "  • AI Sandbox のターミナル"
        echo "  • cli_sandbox/ai_sandbox.sh"
    else
        echo "❌ This script cannot be run on the host OS."
        echo ""
        echo "Please run in one of these environments:"
        echo "  • AI Sandbox terminal"
        echo "  • cli_sandbox/ai_sandbox.sh"
    fi
    exit 1
fi

WORKSPACE="${WORKSPACE:-/workspace}"

# Source common startup functions
# 共通起動関数を読み込み
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_startup_common.sh"
# shellcheck source=/dev/null
source "${WORKSPACE}/.sandbox/scripts/_secret-tag.sh"

# Determine which docker-compose.yml to use based on environment
# 環境に応じて使用する docker-compose.yml を決定
if [[ "$SANDBOX_ENV" == cli_* ]]; then
    COMPOSE_FILE="$WORKSPACE/cli_sandbox/docker-compose.yml"
else
    COMPOSE_FILE="$WORKSPACE/.devcontainer/docker-compose.yml"
fi

CLAUDE_SETTINGS="$WORKSPACE/.claude/settings.json"

# Language detection based on locale
# ロケールに基づく言語検出
if [[ "${LANG:-}" == ja_JP* ]] || [[ "${LC_ALL:-}" == ja_JP* ]]; then
    MSG_TITLE="🕵️  未宣言シークレットのスキャン（手動確認用）"
    MSG_DISCLAIMER="名前パターンによる検出です。1件ずつ内容を確認してください。"
    MSG_NONE_FOUND="疑わしいファイルは見つかりませんでした。"
    MSG_HEADER="⚠️  以下は秘密っぽい名前ですが、docker-compose.yml には未宣言です:"
    MSG_ACTION="対処方法:"
    MSG_ACTION1="  本当に秘密なら: docker-compose.yml に追記 (.sandbox/scripts/sync-secrets.sh でも可)"
    MSG_ACTION2="  または: 各プロジェクトの .claude/settings.json の permissions.deny に追記（Readツールは防げるが、ファイル自体はAIから見える状態のままです）"
    MSG_ACTION3="  秘密でないなら: このメッセージは無視してよい"
    MSG_CLAUDE_ONLY_NOTE="（.claude/settings.json では既にカバー済み。ただしdocker-compose.ymlのようにファイル内容自体を隠すものではありません）"
    MSG_IGNORED_HEADER="無視されたファイル (sync-ignore パターンにマッチ):"
    MSG_CHECKED_SUMMARY="チェック対象: %d 件 / docker-compose宣言済み: %d 件 / うち settings.json のみでカバー(未宣言扱い): %d 件 / 無視: %d 件"
else
    MSG_TITLE="🕵️  Undeclared Secrets Scan (manual check)"
    MSG_DISCLAIMER="This is a name-pattern detection -- review each one before acting."
    MSG_NONE_FOUND="No suspicious files found."
    MSG_HEADER="⚠️  These look like secrets by name, but are NOT declared in docker-compose.yml:"
    MSG_ACTION="Action:"
    MSG_ACTION1="  If genuinely secret: add to docker-compose.yml (or run .sandbox/scripts/sync-secrets.sh)"
    MSG_ACTION2="  Or: add to the relevant project's .claude/settings.json permissions.deny (blocks the Read tool, but the file itself remains visible to AI)"
    MSG_ACTION3="  If not secret: safe to ignore"
    MSG_CLAUDE_ONLY_NOTE="(already covered by .claude/settings.json -- but that doesn't hide the file's content the way docker-compose.yml does)"
    MSG_IGNORED_HEADER="Ignored files (matched sync-ignore patterns):"
    MSG_CHECKED_SUMMARY="Checked: %d / Declared in docker-compose.yml: %d / Of those still undeclared, settings.json-only: %d / Ignored: %d"
fi

# Name patterns that look like secrets. Modeled on the file types already
# treated as secrets in this project's own demo (.env, secrets/) plus common
# iOS/Xcode signing material (*.p12, *.mobileprovision, GoogleService-Info.plist,
# etc. -- see ai-sandbox-demo/demo-apps-ios/.gitignore for precedent). ".env*"
# (not just ".env") also catches ".env.local"/".env.production"; the safe
# ".env.example" variant is filtered back out via sync-ignore below.
# 秘密っぽい名前パターン。このプロジェクト自身のデモ (.env, secrets/) と、
# 一般的なiOS/Xcodeの署名関連ファイル（前例: ai-sandbox-demo/demo-apps-ios/.gitignore）
# をもとにしている。".env"だけでなく".env*"にしているのは".env.local"や
# ".env.production"も拾うため。安全な".env.example"はsync-ignoreで除外する。
#
# Directories pruned from the scan: heavy/vendored/generated trees that
# would only add noise or slow the search down.
# スキャン対象から除外するディレクトリ: 重い/vendor/生成物系のツリーで、
# ノイズになるか探索を遅くするだけのもの。
#
# Files and the "secrets" dir are matched in a single find pass (rather than
# two separate find invocations walking the same tree) to avoid doubling the
# traversal cost on large workspaces.
# ファイルと"secrets"ディレクトリを1回のfindでまとめてマッチさせる
# （同じツリーを2回のfind呼び出しで歩くと走査コストが倍になるため）。
find_secret_like_candidates() {
    find "$WORKSPACE" \
        \( -name node_modules -o -name .git -o -name vendor -o -name Pods \
           -o -name dist -o -name build -o -name .build -o -name DerivedData \
           -o -name Carthage -o -name .venv -o -name __pycache__ \) -prune -o \
        \( -type f \( -name ".env*" -o -name "*.key" -o -name "*.pem" -o -name "*.p12" \
           -o -name "*.cer" -o -name "*.mobileprovision" -o -name "GoogleService-Info.plist" \
           -o -name "Secrets.swift" -o -name "*.xcconfig" \) \
           -o -type d -name "secrets" \) -print 2>/dev/null
}

# Compose file content is read once and cached here (as a plain array of
# lines), so is_path_hidden_by_compose below can match against it with
# bash's built-in [[ =~ ]] instead of forking a grep process for every
# candidate path times every ancestor directory it has.
# composeファイルの内容を1回だけ読み込みここにキャッシュしておく（単純な行の配列）。
# これにより下の is_path_hidden_by_compose は、候補パス×祖先ディレクトリの数だけ
# grepプロセスを起動する代わりに、bash組み込みの [[ =~ ]] でマッチできる。
COMPOSE_LINES=()
[ -f "$COMPOSE_FILE" ] && mapfile -t COMPOSE_LINES < "$COMPOSE_FILE"

# Escape regex metacharacters so a literal filesystem path can be embedded
# in a [[ =~ ]] pattern without its own dots/plusses/etc. being interpreted
# as regex syntax (e.g. the "." in ".env" must match a literal dot, not
# "any character").
# ファイルパスに含まれる正規表現メタ文字（ドットやプラスなど）を、
# [[ =~ ]] パターンに埋め込む前にエスケープする（例: ".env" の "."が
# 「任意の1文字」ではなくリテラルのドットとしてマッチするようにする）。
regex_escape() {
    printf '%s' "$1" | sed -E 's/[][\.^$*+?(){}|\\]/\\&/g'
}

# Check if a path is hidden via docker-compose.yml (/dev/null file mount,
# or tmpfs mount on the path itself or an ancestor directory)
# docker-compose.yml で隠蔽されているかチェック（/dev/nullマウント、
# またはそのパス自身か祖先ディレクトリへのtmpfsマウント）
is_path_hidden_by_compose() {
    local path="$1"
    [ ${#COMPOSE_LINES[@]} -eq 0 ] && return 1

    local line
    local escaped_path
    escaped_path=$(regex_escape "$path")
    local devnull_re="^[[:space:]]*-[[:space:]]*/dev/null:${escaped_path}(:ro)?\$"
    for line in "${COMPOSE_LINES[@]}"; do
        [[ "$line" =~ $devnull_re ]] && return 0
    done

    local check_path="$path"
    while [ "$check_path" != "$WORKSPACE" ] && [ "$check_path" != "/" ] && [ -n "$check_path" ]; do
        local escaped_check_path
        escaped_check_path=$(regex_escape "$check_path")
        # A tmpfs: entry only hides a path when tagged with a trailing
        # "# @secret" comment; see _secret-tag.sh for the shared matching
        # regex used by all six secret-sync scripts.
        # tmpfs: エントリは末尾に "# @secret" タグが付いている場合のみ隠蔽と
        # みなす。共通のマッチング正規表現は _secret-tag.sh を参照
        # （6本のスクリプトすべてで共有）。
        local tmpfs_re
        tmpfs_re=$(secret_tag_exact_regex "$escaped_check_path")
        for line in "${COMPOSE_LINES[@]}"; do
            [[ "$line" =~ $tmpfs_re ]] && return 0
        done
        local parent
        parent=$(dirname "$check_path")
        [ "$parent" = "$check_path" ] && break
        check_path="$parent"
    done

    return 1
}

# Extract Read() deny patterns from the (merged) workspace .claude/settings.json
# （マージ済みの）workspace .claude/settings.json から Read() deny パターンを抽出
extract_claude_deny_patterns() {
    [ -f "$CLAUDE_SETTINGS" ] || return 0
    jq -r '.permissions.deny[]? // empty' "$CLAUDE_SETTINGS" 2>/dev/null | \
        grep -E '^Read\(' | \
        sed -E 's/^Read\(([^)]+)\)$/\1/' | sort -u
}

# Deny patterns are extracted once here rather than inside
# is_path_denied_by_claude_settings, to avoid re-running the jq/grep/sed/sort
# pipeline for every single candidate path in the loop below.
# denyパターンはここで1回だけ抽出する。下のループで候補パス1件ごとに
# jq/grep/sed/sortのパイプライン全体を再実行しないようにするため。
mapfile -t CLAUDE_DENY_PATTERNS < <(extract_claude_deny_patterns)

# Check if a path matches any Read() deny pattern
# パスがいずれかの Read() deny パターンにマッチするかチェック
is_path_denied_by_claude_settings() {
    local path="$1"
    local rel_path="${path#"$WORKSPACE"/}"
    local filename="${path##*/}"
    local pattern

    for pattern in "${CLAUDE_DENY_PATTERNS[@]}"; do
        [ -z "$pattern" ] && continue

        if [[ "$pattern" == */ ]]; then
            local dir_pattern="${pattern%/}"
            if [[ "$dir_pattern" == "**/"* ]]; then
                # Strip only the literal leading "**/" (3 chars), not the
                # longest "**/...prefix" via `##**/` -- an unquoted `*` in a
                # bash `${var##pattern}` expansion matches "/" too, so `##**/`
                # eats through every "/" up to the LAST one, collapsing a
                # multi-segment suffix like "**/api/secrets" down to just
                # "secrets" and over-broadening the match workspace-wide.
                local dir_suffix="${dir_pattern:3}"
                # Match the directory itself (at any depth) AND everything
                # beneath it -- a directory-style deny pattern must hide the
                # whole subtree, mirroring is_path_hidden_by_compose()'s
                # ancestor walk for tmpfs mounts below. Single- and
                # multi-segment suffixes are handled the same way; a bare
                # filename comparison here would both miss files nested
                # under a matching directory and wrongly match unrelated
                # files that merely share the directory's name.
                # shellcheck disable=SC2053
                if [[ "$rel_path" == $dir_suffix || "$rel_path" == */$dir_suffix || \
                      "$rel_path" == $dir_suffix/* || "$rel_path" == */$dir_suffix/* ]]; then
                    return 0
                fi
            elif [[ "$rel_path" == "$dir_pattern" || "$rel_path" == "$dir_pattern"/* ]]; then
                return 0
            fi
            continue
        fi

        if [[ "$pattern" == "**/"* ]]; then
            # Same fix as above: strip only the literal leading "**/".
            local suffix="${pattern:3}"
            if [[ "$suffix" == */* ]]; then
                # shellcheck disable=SC2053
                [[ "$rel_path" == $suffix || "$rel_path" == */$suffix ]] && return 0
            else
                # shellcheck disable=SC2053
                [[ "$filename" == $suffix ]] && return 0
            fi
        elif [[ "$pattern" == *"*"* ]]; then
            # shellcheck disable=SC2053
            [[ "$rel_path" == $pattern ]] && return 0
        elif [[ "$rel_path" == "$pattern" ]]; then
            return 0
        fi
    done

    return 1
}

# --format json emits a machine-comparable snapshot (sorted relative paths,
# no emoji/locale text) instead of the human-readable report below. Intended
# for scripts that diff this scan's result against a previous run (e.g.
# check-undeclared-secrets-diff.sh) -- not for human reading.
# --format json は（絵文字やロケール依存の文言を含まない）比較しやすい
# スニペットを、下記の人間向けレポートの代わりに出力する。このスキャン結果を
# 前回実行と比較するスクリプト（check-undeclared-secrets-diff.sh 等）向けで、
# 人が読むためのものではない。
FORMAT="text"
if [ "${1:-}" = "--format" ]; then
    FORMAT="${2:-text}"
fi

# Main
# メイン処理

candidates=$(find_secret_like_candidates | sort -u)

undeclared=()
claude_only=()
ignored=()
declared_count=0

while IFS= read -r path; do
    [ -z "$path" ] && continue

    if matches_sync_ignore "$path"; then
        ignored+=("$path")
        continue
    fi

    if is_path_hidden_by_compose "$path"; then
        declared_count=$((declared_count + 1))
        continue
    fi

    undeclared+=("$path")
    is_path_denied_by_claude_settings "$path" && claude_only+=("$path")
done <<< "$candidates"

total_checked=$(echo "$candidates" | grep -c . || true)

undeclared_rel=()
for f in "${undeclared[@]}"; do
    undeclared_rel+=("${f#"$WORKSPACE"/}")
done

claude_only_rel=()
for f in "${claude_only[@]}"; do
    claude_only_rel+=("${f#"$WORKSPACE"/}")
done

ignored_rel=()
for f in "${ignored[@]}"; do
    ignored_rel+=("${f#"$WORKSPACE"/}")
done

# Linear membership check against claude_only_rel -- lists here are the
# handful of secret-like candidates found in one workspace scan, not a
# hot path, so an O(n) scan per undeclared entry is not worth a lookup
# table.
# claude_only_rel に対する線形探索 -- ここでのリストは1回のワークスペース
# スキャンで見つかった秘密っぽい候補の少数件に限られ、ホットパスではない
# ため、未宣言1件ごとのO(n)探索でもルックアップ表を用意するほどではない。
is_claude_only() {
    local target="$1" p
    for p in "${claude_only_rel[@]}"; do
        [ "$p" = "$target" ] && return 0
    done
    return 1
}

# Build a JSON array from a bash array, without the single-empty-string
# artifact `printf '%s\n' "${empty_arr[@]}" | jq -R .` produces when the
# array has zero elements.
# bash配列からJSON配列を作る。配列が空のとき
# `printf '%s\n' "${empty_arr[@]}" | jq -R .` が生む「空文字列1件」という
# アーティファクトを避けるための分岐。
to_json_array() {
    local -n _arr="$1"
    if [ "${#_arr[@]}" -eq 0 ]; then
        echo "[]"
    else
        printf '%s\n' "${_arr[@]}" | jq -R . | jq -s 'sort'
    fi
}

if [ "$FORMAT" = "json" ]; then
    jq -n \
        --argjson undeclared "$(to_json_array undeclared_rel)" \
        --argjson claude_only "$(to_json_array claude_only_rel)" \
        --argjson ignored "$(to_json_array ignored_rel)" \
        --argjson declared_count "$declared_count" \
        --argjson total_checked "$total_checked" \
        '{undeclared: $undeclared, claude_only: $claude_only, ignored: $ignored, declared_count: $declared_count, total_checked: $total_checked}'
    exit 0
fi

print_title "$MSG_TITLE"
echo "$MSG_DISCLAIMER"
echo ""

if [ ${#undeclared[@]} -eq 0 ]; then
    echo "$MSG_NONE_FOUND"
else
    echo "$MSG_HEADER"
    echo ""
    for rel_path in "${undeclared_rel[@]}"; do
        if is_claude_only "$rel_path"; then
            echo "   📄 $rel_path  $MSG_CLAUDE_ONLY_NOTE"
        else
            echo "   📄 $rel_path"
        fi
    done
    echo ""
    echo "$MSG_ACTION"
    echo "$MSG_ACTION1"
    echo "$MSG_ACTION2"
    echo "$MSG_ACTION3"
fi

if [ ${#ignored[@]} -gt 0 ]; then
    echo ""
    echo "$MSG_IGNORED_HEADER"
    for rel_path in "${ignored_rel[@]}"; do
        echo "   📄 $rel_path"
    done
fi

echo ""
# shellcheck disable=SC2059
printf "${MSG_CHECKED_SUMMARY}\n" "$total_checked" "$declared_count" "${#claude_only[@]}" "${#ignored[@]}"
print_footer

exit 0

#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# What this prints: for each nested repo, which doc files it has
# (CLAUDE.md/README.md/README.ja.md) plus a short excerpt (README.md
# preferred, CLAUDE.md as fallback) -- so the AI can tell what a repo is
# without opening it.
#
# Non-git projects: a depth-1 dir directly under WORKSPACE also counts as
# a project if it has at least one doc file of its own (e.g. an Xcode
# project with no version control) -- .git is only one of two signals that
# a directory is its own project; having its own docs is the other. A
# depth-1 dir with neither .git nor any doc file is skipped (no signal at
# all), and doc files deeper than depth 1 are ignored (avoids noise from
# arbitrary internal doc folders).
#
# CLAUDE.md fallback heading: when falling back to CLAUDE.md (no
# README.md), the excerpt starts at a description-style heading (e.g.
# "What This ... Is", "Overview") if one exists, rather than at the top of
# the file, and skips bullets that read as AI behavior rules rather than a
# description -- CLAUDE.md commonly opens with rules, not a description
# (see find_description_heading_line / DIRECTIVE_BULLET_REGEX below).
# ---
# 出力内容: ネストされたリポジトリごとに、持っているドキュメントファイル
# （CLAUDE.md/README.md/README.ja.md）と、短い抜粋（README.md優先、無ければ
# CLAUDE.mdにフォールバック）を表示する -- ファイルを開かなくても各リポジトリ
# が何かをAIが把握できるようにするため。
#
# non-gitプロジェクトの扱い: WORKSPACE直下（depth 1）のディレクトリは、
# 自分自身のドキュメントを1つ以上持っていればプロジェクトとみなす（例:
# バージョン管理していないXcodeプロジェクト）-- 「独立したプロジェクトで
# ある」根拠は.gitだけでなく、「自分自身のドキュメントを持っている」ことも
# その1つとみなすため。.gitもドキュメントも無いdepth 1ディレクトリは
# （プロジェクトである根拠が無いため）除外し、depth 1より深いドキュメントは
# 内部フォルダのノイズを避けるため無視する。
#
# CLAUDE.mdフォールバック時の見出し: README.mdが無くCLAUDE.mdにフォール
# バックする場合、説明系の見出し（「What This ... Is」「Overview」等）が
# あればファイル先頭ではなくそこから抜粋を開始し、説明ではなくAI向け行動
# 規則として読める箇条書きは除外する -- CLAUDE.mdは説明ではなく規則から
# 始まることが多いため（詳細は後述の find_description_heading_line /
# DIRECTIVE_BULLET_REGEX を参照）。

WORKSPACE="${WORKSPACE:-/workspace}"
while [ "${WORKSPACE: -1}" = "/" ]; do WORKSPACE="${WORKSPACE%/}"; done
DOC_FILES=(CLAUDE.md README.md README.ja.md)
EXCERPT_LINES=5

# Extract a short excerpt from a Markdown doc, skipping structural
# boilerplate (headings, horizontal rules, raw HTML, badges, language-switch
# links, ToC list items, table rows) so the AI sees prose rather than
# front-matter.
# Blockquote markers are stripped but their text is kept, since GitHub alert
# blocks (e.g. "> [!WARNING] ... deprecated, use X instead") are often the
# single most important line in a README.
# ---
# Markdownドキュメントから短い抜粋を抽出する。見出し・水平線・生HTML・
# バッジ・言語切り替えリンク・目次のリスト項目・テーブル行といった定型的な
# 前置きを除外し、AIに地の文を見せるため。blockquoteの `>` 記号は除去するが本文は残す
# （「> [!WARNING] ...非推奨、Xを使うこと」のようなGitHub alertブロックが
# READMEの中で最も重要な一行であることが多いため）。
# Matches bullet lines that read as an AI behavior rule rather than a
# project description (e.g. "推測ですがと明示すること", "Never fabricate data").
#
# Where used: only by the CLAUDE.md fallback path (see below), not README.md.
# Why: this phrasing register is specific to AI-instruction documents --
# applying it to README.md prose risks dropping legitimate description
# lines that happen to end in the same Japanese verb form.
# ---
# プロジェクト説明ではなくAI向け行動規則として読める箇条書き行にマッチする
# （例:「推測ですがと明示すること」「Never fabricate data」）。
#
# 適用箇所: CLAUDE.mdフォールバック経路（後述）でのみ適用し、README.mdには
# 適用しない。理由: この言い回しはAI向け指示書に特有のものであり、
# README.mdの地の文に適用すると、たまたま同じ語尾で終わる正当な説明文まで
# 落としてしまう恐れがあるため。
DIRECTIVE_BULLET_REGEX='すること|してはならない|しないこと|避けること'
DIRECTIVE_BULLET_PREFIX_REGEX='^(\*\*)?(Must|Never|Always|Do not|Don.t|Should (always|never))([[:space:]]|$)'
# Matches a directive negation that appears mid-sentence rather than as the
# bullet's first word (e.g. "**Commits:** Always use X -- do NOT use Y
# directly").
#
# How: matched case-insensitively against the whole bullet body, with
# non-letter boundaries approximated on both sides so it doesn't match
# inside an unrelated word.
#
# Why a separate regex from DIRECTIVE_BULLET_PREFIX_REGEX: that one only
# checks the bullet's leading word. This one is a content-based signal
# instead, so it generalizes across nested repos with unrelated doc styles
# rather than assuming any particular project's own conventions.
# ---
# 文頭ではなく文中に現れる否定の規則表現にマッチする（例:「**Commits:**
# Xを使うこと -- 直接Yをdo NOTすること」）。
#
# 判定方法: 箇条書き本文全体に対して大文字小文字を区別せずマッチさせる。
# 無関係な単語の内部にマッチしないよう、両端をアルファベット以外の文字
# （もしくは行頭/行末）で近似的に境界判定する。
#
# DIRECTIVE_BULLET_PREFIX_REGEXと別に用意している理由: そちらは行頭の
# 単語のみを見る判定方式だが、こちらは内容ベースのシグナルである。その
# ため特定プロジェクト固有の記法を前提とせず、ネストされた他リポジトリの
# 多様なドキュメント様式に一般化できる。
DIRECTIVE_BULLET_CONTAINS_REGEX='(^|[^a-z])(do not|don'"'"'t|must not|should not|never)([^a-z]|$)'

excerpt_from_doc() {
  local file="$1" limit="$2" skip_directives="${3:-0}"
  awk -v limit="$limit" -v skip_directives="$skip_directives" \
      -v directive_re="$DIRECTIVE_BULLET_REGEX" \
      -v directive_prefix_re="$DIRECTIVE_BULLET_PREFIX_REGEX" \
      -v directive_contains_re="$DIRECTIVE_BULLET_CONTAINS_REGEX" '
    BEGIN { in_comment = 0; in_code = 0; count = 0 }
    {
      line = $0

      if (in_comment) {
        if (line ~ /-->/) { sub(/^.*-->/, "", line); in_comment = 0 }
        else next
      }
      while (match(line, /<!--.*-->/)) { sub(/<!--.*-->/, "", line) }
      if (match(line, /<!--/)) { sub(/<!--.*/, "", line); in_comment = 1 }

      gsub(/^[[:space:]]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)

      # Fenced code blocks (```) are skipped whole -- their contents are
      # code/output/diagrams, not prose, and a mid-fence cut looks broken.
      # ---
      # fenced code block（```）は丸ごと除外する -- 中身はコード/出力/図であり
      # 地の文ではないため、途中で切れると不自然な抜粋になるため。
      if (line ~ /^```/) { in_code = !in_code; next }
      if (in_code) next

      while (line ~ /^>/) {
        sub(/^>[[:space:]]?/, "", line)
        gsub(/^[[:space:]]+/, "", line)
      }

      if (line == "") next
      if (line ~ /^#+[[:space:]]/) next
      if (line ~ /^---+[[:space:]]*$/) next
      if (line ~ /^\*\*\*+[[:space:]]*$/) next
      if (line ~ /^___+[[:space:]]*$/) next
      if (line ~ /^<\/?[a-zA-Z]/) next
      if (line ~ /^\|.*\|[[:space:]]*$/) next

      # Classify on a copy with list markers and link/image tokens removed:
      # if nothing but a bullet + a single link/badge remains, the line
      # carries no prose and is skipped -- but the original `line` (with
      # the link intact) is what gets printed when it is kept.
      stripped = line
      sub(/^[-*+][[:space:]]+/, "", stripped)
      sub(/^[0-9]+\.[[:space:]]+/, "", stripped)
      gsub(/\[!\[[^]]*\]\([^)]*\)\]\([^)]*\)/, "", stripped)
      gsub(/!\[[^]]*\]\([^)]*\)/, "", stripped)
      gsub(/\[[^]]*\]\([^)]*\)/, "", stripped)
      gsub(/[[:space:]]/, "", stripped)
      if (stripped == "") next

      if (skip_directives && line ~ /^[-*+][[:space:]]+/) {
        body = line
        sub(/^[-*+][[:space:]]+/, "", body)
        # A leading bold label ("**Commits:** Always use X") pushes the
        # actual directive keyword past position 0, so prefix matching runs
        # against a label-stripped copy while the printed line keeps the
        # label intact.
        # ---
        # 太字ラベル（「**Commits:** Xを使うこと」）が先頭にあると規則語の
        # 位置が0からずれてしまうため、プレフィックス判定にはラベルを
        # 除去したコピーを使う（出力される行自体はラベル付きのまま）。
        label_stripped = body
        sub(/^\*\*[^*]*:\*\*[[:space:]]*/, "", label_stripped)
        if (body ~ directive_re) next
        if (label_stripped ~ directive_prefix_re) next
        if (tolower(body) ~ directive_contains_re) next
      }

      print line
      count++
      if (count >= limit) exit
    }
  ' "$file"
}

# Deprecation detection: look at the first EXCERPT_LINES filtered lines of a
# doc. If BOTH of the following appear somewhere in them -- not necessarily
# on the same line -- treat the repo as deprecated/archived:
#   1. a GitHub alert marker, e.g. "> [!WARNING]" (DEPRECATION_ALERT_REGEX)
#   2. a deprecation keyword, e.g. "deprecated" / "非推奨" (DEPRECATION_KEYWORD_REGEX)
# Requiring both avoids false positives: an alert marker alone (e.g. "> [!WARNING]
# requires Xcode 15") isn't a deprecation notice by itself.
#
# Effect when matched: the excerpt body is replaced with a one-line note
# instead of the doc's actual prose -- a deprecated doc's prose usually
# just points elsewhere, so showing it would spend the AI's context budget
# for no benefit. The repo is still listed by name (with its doc-file
# list), so the AI knows it exists if asked about it directly.
# ---
# 非推奨判定: ドキュメント冒頭のEXCERPT_LINES行（フィルタ後）の中に、次の
# 2つが両方含まれていれば、そのリポジトリを非推奨/アーカイブ済みとみなす
# （両者は同一行である必要はない）。
#   1. GitHub alertマーカー（例: "> [!WARNING]"、DEPRECATION_ALERT_REGEX）
#   2. 非推奨を示すキーワード（例:「deprecated」「非推奨」、DEPRECATION_KEYWORD_REGEX）
# 両方を要求するのは誤検知を防ぐため -- alertマーカーだけ（例:「> [!WARNING]
# Xcode 15が必要」）ではそれ単体では非推奨通知とみなさない。
#
# 一致した場合の動作: 抜粋本文をドキュメントの地の文の代わりに一行の注記に
# 置き換える -- 非推奨ドキュメントの地の文は結局は他所を指し示すだけなので、
# そのまま表示してもAIのコンテキスト予算を無駄に使うだけのため。リポジトリ
# 名自体（とドキュメントファイルの一覧）は引き続き表示するので、直接尋ね
# られればAIはその存在を把握できる。
DEPRECATION_ALERT_REGEX='^\[!(WARNING|CAUTION|IMPORTANT)\]'
DEPRECATION_KEYWORD_REGEX='deprecated|no longer maintained|has been split into|has been renamed to|kept for reference only|will not receive new features|非推奨|廃止|メンテナンスされていません|分割されました|統合されました|リネームされました'

is_deprecated_doc() {
  local file="$1"
  local head_text
  head_text=$(excerpt_from_doc "$file" "$EXCERPT_LINES")
  echo "$head_text" | grep -qiE "$DEPRECATION_ALERT_REGEX" \
    && echo "$head_text" | grep -qiE "$DEPRECATION_KEYWORD_REGEX"
}

# Heading that plausibly introduces a project description (e.g. "Overview",
# "What This ... Is").
#
# Used only by the CLAUDE.md fallback (no README.md present). Why:
# CLAUDE.md is an AI-instruction document whose opening section is
# commonly behavior rules, not a description (e.g. this repo's own
# CLAUDE.md has "Essential Rules" before "What This Project Is") -- so a
# plain top-of-file excerpt tends to surface rules instead of a
# description. When this heading exists, the excerpt starts right after it
# instead of at line 1.
# ---
# プロジェクト説明を導入していそうな見出し（例:「Overview」「What This ...
# Is」）。
#
# README.mdが無くCLAUDE.mdにフォールバックする場合にのみ使う。理由:
# CLAUDE.mdはAI向け指示書であり、冒頭は行動規則から始まることが多く説明
# ではない（このリポジトリ自身のCLAUDE.mdも "Essential Rules" が "What
# This Project Is" より前にある）-- そのため単純にファイル先頭から抜粋
# すると、説明ではなく規則が表示されてしまう。この見出しが見つかった場合
# は、その直後から抜粋を開始する。
DESCRIPTION_HEADING_REGEX='^#{1,4}[[:space:]]+(What (This|the) .* Is|Overview|About|概要|.*とは|.*について)[[:space:]]*$'

find_description_heading_line() {
  local file="$1"
  grep -nE "$DESCRIPTION_HEADING_REGEX" "$file" 2>/dev/null | head -1 | cut -d: -f1
}

# .git can be a regular file (not a directory) for worktrees and
# submodules, so both types must be matched to find those repos too.
# ---
# .gitはworktreeやsubmoduleの場合ディレクトリではなくファイルになりうる
# ため、それらのリポジトリも見つけられるよう両方のtypeにマッチさせる。
GIT_REPOS=$(find "$WORKSPACE" -maxdepth 8 \
    \( -name node_modules -o -name vendor -o -name dist -o -name build \
       -o -name .build -o -name DerivedData -o -name Carthage \
       -o -name .venv -o -name __pycache__ \) -prune -o \
    -name ".git" \( -type d -o -type f \) -print 2>/dev/null \
  | grep -Fxv "$WORKSPACE/.git" \
  | sed 's|/.git$||' | sort)

# Non-git top-level projects: depth-1 dirs under WORKSPACE with at least one
# doc file of their own. Doc presence is the only signal available (no .git
# marker), so a depth-1 dir without any doc file is not reported at all --
# unlike a git repo, which is reported as "(none)" since .git alone already
# marks it as a project.
NON_GIT_DOC_DIRS=$(find "$WORKSPACE" -mindepth 1 -maxdepth 1 -type d \
    \( -name node_modules -o -name vendor -o -name dist -o -name build \
       -o -name .build -o -name DerivedData -o -name Carthage \
       -o -name .venv -o -name __pycache__ \) -prune -o \
    -type d -print 2>/dev/null \
  | while IFS= read -r dir; do
      for doc in "${DOC_FILES[@]}"; do
        if [ -f "$dir/$doc" ]; then
          echo "$dir"
          break
        fi
      done
    done)

REPOS=$(printf '%s\n%s\n' "$GIT_REPOS" "$NON_GIT_DOC_DIRS" | sed '/^$/d' | sort -u)

[ -z "$REPOS" ] && exit 0

# What: identify which nested repo owns the workspace-root CLAUDE.md, so its
# CLAUDE.md-fallback excerpt can be skipped below (see the README.md-priority
# check a few lines down).
#
# Why: the workspace-root CLAUDE.md is a symlink into this repo, and it's
# already loaded as project instructions -- showing it again as a CLAUDE.md
# excerpt here would just duplicate it. Its README.md/README.ja.md aren't
# auto-loaded the same way, though, so those still get an excerpt like any
# other repo.
#
# Resolved dynamically (not hardcoded) because this is a template, and
# other users may place this repo at a different path within their
# workspace.
# ---
# 内容: ワークスペース直下のCLAUDE.mdがどのネストされたリポジトリに属す
# かを特定する -- そのリポジトリのCLAUDE.mdフォールバック抜粋を後述の
# 処理でスキップするため（数行下のREADME.md優先チェックを参照）。
#
# 理由: ワークスペース直下のCLAUDE.mdはこのリポジトリへのシンボリック
# リンクであり、既にプロジェクト指示として読み込み済みである -- ここで
# 改めてCLAUDE.mdの抜粋として表示すると重複してしまう。一方README.md /
# README.ja.mdは同様には自動読み込みされないため、他のリポジトリと同じく
# 抜粋を表示する。
#
# 動的に解決している理由: ハードコードせず動的に解決しているのは、これが
# テンプレートであり、利用者によってこのリポジトリのワークスペース内配置
# パスが異なりうるため。
SELF_REPO=""
if [ -L "$WORKSPACE/CLAUDE.md" ]; then
  resolved=$(readlink -f "$WORKSPACE/CLAUDE.md" 2>/dev/null)
  [ -n "$resolved" ] && SELF_REPO=$(git -C "$(dirname "$resolved")" rev-parse --show-toplevel 2>/dev/null)
fi

echo "Nested project docs:"
while IFS= read -r repo_path; do
  rel="${repo_path#"$WORKSPACE"/}"
  found=()
  for doc in "${DOC_FILES[@]}"; do
    [ -f "$repo_path/$doc" ] && found+=("$doc")
  done
  if [ "${#found[@]}" -eq 0 ]; then
    echo "- $rel: (none)"
    continue
  fi

  joined=$(printf ', %s' "${found[@]}")
  echo "- $rel: ${joined:2}"

  excerpt_file=""
  is_claude_fallback=0
  if [ -f "$repo_path/README.md" ]; then
    excerpt_file="$repo_path/README.md"
  elif [ "$repo_path" != "$SELF_REPO" ] && [ -f "$repo_path/CLAUDE.md" ]; then
    excerpt_file="$repo_path/CLAUDE.md"
    is_claude_fallback=1
  fi
  if [ -n "$excerpt_file" ]; then
    if is_deprecated_doc "$excerpt_file"; then
      echo "    | (deprecated/archived -- excerpt omitted, see doc for successor)"
    elif [ "$is_claude_fallback" -eq 1 ]; then
      heading_line=$(find_description_heading_line "$excerpt_file")
      if [ -n "$heading_line" ]; then
        tail -n +"$((heading_line + 1))" "$excerpt_file" \
          | excerpt_from_doc /dev/stdin "$EXCERPT_LINES" 1 | sed 's/^/    | /'
      else
        excerpt_from_doc "$excerpt_file" "$EXCERPT_LINES" 1 | sed 's/^/    | /'
      fi
    else
      excerpt_from_doc "$excerpt_file" "$EXCERPT_LINES" | sed 's/^/    | /'
    fi
  fi
done <<< "$REPOS"

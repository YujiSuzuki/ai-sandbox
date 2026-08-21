#!/bin/bash
# test-nested-repo-docs-setup.sh
# Test .sandbox/sandbox-mcp-setup/22-nested-repo-docs.sh behavior
# .sandbox/sandbox-mcp-setup/22-nested-repo-docs.sh の動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TARGET_SCRIPT="$WORKSPACE/.sandbox/sandbox-mcp-setup/22-nested-repo-docs.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

# Test helpers
pass() { echo -e "${GREEN}PASS${NC}: $1"; ((TESTS_PASSED++)) || true; }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((TESTS_FAILED++)) || true; }

# Fake workspace with an outer repo (should be ignored, same as
# 20-git-uncommitted.sh) and nested repos with varying doc files.
# 外側リポジトリ（20-git-uncommitted.sh と同様に除外対象）と、
# ドキュメントファイルの構成が異なるネストしたリポジトリを持つフェイクワークスペース。
FAKE_WORKSPACE=""

init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
}

setup() {
    FAKE_WORKSPACE=$(mktemp -d)
    init_repo "$FAKE_WORKSPACE"
    echo "# outer" > "$FAKE_WORKSPACE/CLAUDE.md"

    # Nested repo with all three doc files
    init_repo "$FAKE_WORKSPACE/full-docs-repo"
    echo "# claude" > "$FAKE_WORKSPACE/full-docs-repo/CLAUDE.md"
    echo "# readme" > "$FAKE_WORKSPACE/full-docs-repo/README.md"
    echo "# readme ja" > "$FAKE_WORKSPACE/full-docs-repo/README.ja.md"

    # Nested repo with only README.md (no CLAUDE.md)
    init_repo "$FAKE_WORKSPACE/readme-only-repo"
    echo "# readme" > "$FAKE_WORKSPACE/readme-only-repo/README.md"

    # Nested repo with no doc files at all
    init_repo "$FAKE_WORKSPACE/no-docs-repo"
    echo "code" > "$FAKE_WORKSPACE/no-docs-repo/main.go"

    # Vendored repo under an excluded directory name -- must be pruned,
    # not reported as a nested repo.
    # 除外対象ディレクトリ名の配下にあるvendoredリポジトリ -- ネストした
    # リポジトリとして報告されず、探索対象から除外されなければならない。
    init_repo "$FAKE_WORKSPACE/pkg/node_modules/some-dep"
    echo "# vendored" > "$FAKE_WORKSPACE/pkg/node_modules/some-dep/README.md"

    # Non-git top-level project (depth 1 under WORKSPACE) with a README.md --
    # must be discovered even without a .git marker (e.g. an Xcode project
    # with no version control).
    # .gitマーカーを持たないWORKSPACE直下（depth 1）のプロジェクト -- .git
    # がなくても発見されなければならない（バージョン管理していない
    # Xcodeプロジェクトなど）。
    mkdir -p "$FAKE_WORKSPACE/non-git-project"
    printf '# non-git readme\n\nA real description line for the non-git project.\n' \
      > "$FAKE_WORKSPACE/non-git-project/README.md"

    # Doc file nested two levels deep under the non-git project -- must NOT
    # be reported as its own entry; only the depth-1 doc counts.
    # non-gitプロジェクトの2階層下にあるドキュメント -- depth 1のドキュメント
    # のみが対象なので、これ自体が独立したエントリとして報告されてはならない。
    mkdir -p "$FAKE_WORKSPACE/non-git-project/docs"
    echo "# nested doc" > "$FAKE_WORKSPACE/non-git-project/docs/README.md"

    # Non-git top-level directory with no doc files at all -- must NOT be
    # reported (no .git marker and no docs means no signal this is a project).
    # ドキュメントを一切持たないnon-gitのdepth 1ディレクトリ -- .gitマーカーも
    # ドキュメントもなくプロジェクトである根拠がないため報告されてはならない。
    mkdir -p "$FAKE_WORKSPACE/non-git-no-docs"
    echo "code" > "$FAKE_WORKSPACE/non-git-no-docs/main.go"

    # A depth-1 directory with no docs of its own, whose depth-2 child has
    # docs -- must NOT surface the depth-2 child either (depth-1 only).
    # 自身はドキュメントを持たないdepth 1ディレクトリの下に、ドキュメントを
    # 持つdepth 2の子がある場合 -- その子も報告されてはならない（depth 1限定）。
    mkdir -p "$FAKE_WORKSPACE/depth1-wrapper/depth2-with-docs"
    echo "# depth2" > "$FAKE_WORKSPACE/depth1-wrapper/depth2-with-docs/README.md"

    # Nested repo whose README exercises every boilerplate pattern the
    # excerpt filter must skip, plus a GitHub alert block and a plain
    # description line that must survive.
    # 抜粋フィルタが除外すべき定型パターンを一通り含み、GitHub alert
    # ブロックと本文説明行（残るべきもの）を併せ持つREADMEを持つリポジトリ。
    init_repo "$FAKE_WORKSPACE/excerpt-repo"
    cat > "$FAKE_WORKSPACE/excerpt-repo/README.md" <<'EOF'
# Excerpt Repo

[日本語版はこちら](README.ja.md)

[![Build Status](https://img.shields.io/badge/build-passing-green)](https://example.com/ci)

> [!WARNING]
> This is the important warning line.

Real description line one.

---

## Table of Contents

- [Features](#features)

| Directory | Description |
|-----------|-------------|
| [demo/](demo/) | Example app |
EOF

    # Nested repo whose README carries a real deprecation notice (mirrors
    # mainte/old/dkmcp's actual wording) -- its excerpt must be suppressed.
    # 実際の非推奨通知（mainte/old/dkmcp の実際の文言を模したもの）を持つ
    # README -- その抜粋は省略されなければならない。
    init_repo "$FAKE_WORKSPACE/deprecated-repo"
    cat > "$FAKE_WORKSPACE/deprecated-repo/README.md" <<'EOF'
# Deprecated Repo

> [!WARNING]
> This repository is no longer maintained.
> OldTool has been renamed to **NewTool**.

Please use NewTool instead.
EOF

    # Nested repo that uses the same alert marker style for an unrelated,
    # non-deprecation warning -- must NOT be treated as deprecated (the
    # marker alone is not enough; deprecation keywords must also match).
    # 同じalertマーカーを非推奨とは無関係な警告に使うリポジトリ -- マーカー
    # だけでは非推奨と判定してはならない（キーワードも一致が必要）。
    init_repo "$FAKE_WORKSPACE/active-repo-with-warning"
    cat > "$FAKE_WORKSPACE/active-repo-with-warning/README.md" <<'EOF'
# Active Repo

> [!WARNING]
> Requires Xcode 15 or later to build.

Real description line for the active repo.
EOF

    # CLAUDE.md-only repo (no README) whose opening section is AI behavior
    # rules, with a real description under a later "What This ... Is"
    # heading -- mirrors this repo's own CLAUDE.md, where "Essential Rules"
    # precedes "What This Project Is".
    # README.mdを持たずCLAUDE.mdのみのリポジトリ。冒頭はAI向け行動規則で、
    # 実際の説明は後方の「What This ... Is」見出し以下にある -- このリポジトリ
    # 自身のCLAUDE.mdで「Essential Rules」が「What This Project Is」より
    # 前にあるのと同じ構造。
    init_repo "$FAKE_WORKSPACE/claude-only-with-overview-repo"
    cat > "$FAKE_WORKSPACE/claude-only-with-overview-repo/CLAUDE.md" <<'EOF'
# Some App

## Essential Rules

- **推測の場合は必ず「推測ですが」と明示すること**
- **Never fabricate data**

## What This App Is

This app helps users track daily habits.
It syncs across devices automatically.
EOF

    # CLAUDE.md-only repo (no README) with no description heading at all --
    # every line past the title is an AI behavior rule (mirrors Tokeruyo's
    # actual CLAUDE.md, which has no "what this app is" section).
    # README.mdを持たずCLAUDE.mdのみで、説明見出しが一切ないリポジトリ --
    # タイトル以降は全てAI向け行動規則（実際のTokeruyoのCLAUDE.mdに
    # 「このアプリは何か」の節が存在しないのと同じ構造）。
    init_repo "$FAKE_WORKSPACE/claude-only-no-overview-repo"
    cat > "$FAKE_WORKSPACE/claude-only-no-overview-repo/CLAUDE.md" <<'EOF'
# Some Tool

## Rules

- **推測ですがと明示すること**
- **してはならない、断言禁止**
- Never skip tests
- Always write tests first
EOF

    # README-only repo whose real description bullet happens to contain the
    # Japanese directive substring "すること" mid-sentence -- the
    # directive-bullet filter must NOT apply here, since it is scoped to the
    # CLAUDE.md fallback only (README prose legitimately uses this ending).
    # README.mdのみのリポジトリで、本文説明の箇条書きにたまたま日本語の
    # 行動規則的な語尾「すること」が含まれる -- 箇条書きフィルタはCLAUDE.md
    # フォールバック専用のスコープなので、ここには適用されてはならない
    # （READMEの説明文で正当にこの語尾が使われるケース）。
    init_repo "$FAKE_WORKSPACE/readme-with-suru-repo"
    cat > "$FAKE_WORKSPACE/readme-with-suru-repo/README.md" <<'EOF'
# Suru Repo

- 設定画面から通知をオンにすることができます
EOF

    # Nested repo that the workspace-root CLAUDE.md symlinks into. Its
    # CLAUDE.md excerpt must be suppressed (already loaded as project
    # instructions via the symlink), but its README.md excerpt must still
    # appear -- README.md isn't auto-loaded the same way, so skipping it
    # too would hide content the AI never sees elsewhere.
    # ワークスペース直下のCLAUDE.mdがシンボリックリンクする先のリポジトリ。
    # CLAUDE.mdの抜粋は（シンボリックリンク経由で既にプロジェクト指示として
    # 読み込み済みのため）抑制されなければならないが、README.mdの抜粋は
    # 表示されなければならない -- README.mdは同様には自動読み込みされない
    # ため、これも抑制するとAIがどこからも見られない内容になってしまう。
    init_repo "$FAKE_WORKSPACE/self-repo"
    cat > "$FAKE_WORKSPACE/self-repo/CLAUDE.md" <<'EOF'
# Self Repo

## What This Repo Is

This CLAUDE.md excerpt line must never appear in the output.
EOF
    cat > "$FAKE_WORKSPACE/self-repo/README.md" <<'EOF'
# Self Repo

A real README description line that must still be excerpted.
EOF
    rm -f "$FAKE_WORKSPACE/CLAUDE.md"
    ln -s self-repo/CLAUDE.md "$FAKE_WORKSPACE/CLAUDE.md"
}

teardown() {
    [ -n "$FAKE_WORKSPACE" ] && rm -rf "$FAKE_WORKSPACE"
}

# ============================================================
# Test: Script is executable
# ============================================================
test_script_executable() {
    echo ""
    echo "=== Testing script is executable ==="

    if [ -f "$TARGET_SCRIPT" ]; then
        pass "22-nested-repo-docs.sh exists"
    else
        fail "22-nested-repo-docs.sh does not exist"
        return
    fi

    if [ -x "$TARGET_SCRIPT" ]; then
        pass "22-nested-repo-docs.sh is executable"
    else
        fail "22-nested-repo-docs.sh should be executable"
    fi
}

# ============================================================
# Test: reports doc files per nested repo, missing files as (none)
# ============================================================
test_reports_docs_and_excludes_outer() {
    echo ""
    echo "=== Testing nested repo doc detection ==="

    local output
    if ! output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        return
    fi

    if echo "$output" | grep -q "full-docs-repo: CLAUDE.md, README.md, README.ja.md"; then
        pass "Reports all three doc files for full-docs-repo"
    else
        fail "Should report all three doc files, got: '$output'"
    fi

    if echo "$output" | grep -q "readme-only-repo: README.md"; then
        pass "Reports only README.md for readme-only-repo"
    else
        fail "Should report only README.md, got: '$output'"
    fi

    if echo "$output" | grep -q "readme-only-repo: README.md, README.ja.md\|readme-only-repo: README.md, CLAUDE.md"; then
        fail "Should not report doc files that don't exist for readme-only-repo, got: '$output'"
    else
        pass "Does not report nonexistent doc files for readme-only-repo"
    fi

    if echo "$output" | grep -q "no-docs-repo: (none)"; then
        pass "Reports (none) for no-docs-repo"
    else
        fail "Should report (none) for no-docs-repo, got: '$output'"
    fi

    # The outer repo itself must never be reported -- same rule as
    # 20-git-uncommitted.sh (VSCode already shows the outer repo's own files).
    if echo "$output" | grep -qF -- "- $FAKE_WORKSPACE:"; then
        fail "Should not report the outer repo, got: '$output'"
    else
        pass "Excludes the outer repo from nested-repo reporting"
    fi

    # A repo vendored under an excluded directory name (node_modules) must
    # be pruned from the search, not reported.
    if echo "$output" | grep -q "node_modules"; then
        fail "Should not report repos under excluded directories, got: '$output'"
    else
        pass "Excludes repos nested under excluded directory names (node_modules)"
    fi
}

# ============================================================
# Test: excerpt skips boilerplate but keeps real content
# ============================================================
test_excerpt_filters_boilerplate() {
    echo ""
    echo "=== Testing excerpt boilerplate filtering ==="

    local output
    if ! output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        return
    fi

    if echo "$output" | grep -qF "# Excerpt Repo"; then
        fail "Should skip the heading line, got: '$output'"
    else
        pass "Skips the heading line"
    fi

    if echo "$output" | grep -qF "日本語版はこちら"; then
        fail "Should skip the language-switch link line, got: '$output'"
    else
        pass "Skips the language-switch link line"
    fi

    if echo "$output" | grep -qF "img.shields.io"; then
        fail "Should skip the badge-only line, got: '$output'"
    else
        pass "Skips the badge-only line"
    fi

    if echo "$output" | grep -qF -- "---"; then
        fail "Should skip the horizontal rule, got: '$output'"
    else
        pass "Skips the horizontal rule"
    fi

    if echo "$output" | grep -qF "Table of Contents"; then
        fail "Should skip the ToC heading, got: '$output'"
    else
        pass "Skips the ToC heading"
    fi

    if echo "$output" | grep -qF "[Features](#features)"; then
        fail "Should skip the link-only ToC list item, got: '$output'"
    else
        pass "Skips the link-only ToC list item"
    fi

    if echo "$output" | grep -qF "This is the important warning line."; then
        pass "Keeps the GitHub alert body text"
    else
        fail "Should keep the GitHub alert body text, got: '$output'"
    fi

    if echo "$output" | grep -qF "Real description line one."; then
        pass "Keeps the real description line"
    else
        fail "Should keep the real description line, got: '$output'"
    fi

    if echo "$output" | grep -qF "Directory"; then
        fail "Should skip Markdown table rows, got: '$output'"
    else
        pass "Skips Markdown table rows"
    fi
}

# ============================================================
# Test: deprecated repos get their excerpt suppressed, active repos with an
# unrelated alert marker keep their excerpt
# ============================================================
test_deprecated_repo_excerpt_suppressed() {
    echo ""
    echo "=== Testing deprecated repo excerpt suppression ==="

    local output
    if ! output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        return
    fi

    # Doc-file listing line must still be reported -- only the excerpt body
    # is suppressed, not the repo's existence.
    if echo "$output" | grep -qF -- "- deprecated-repo: README.md"; then
        pass "Still lists doc files for a deprecated repo"
    else
        fail "Should still list doc files for deprecated-repo, got: '$output'"
    fi

    if echo "$output" | grep -qF "This repository is no longer maintained."; then
        fail "Should suppress the excerpt body for a deprecated repo, got: '$output'"
    else
        pass "Suppresses the excerpt body for a deprecated repo"
    fi

    if echo "$output" | grep -qF "OldTool has been renamed to"; then
        fail "Should suppress all excerpt lines for a deprecated repo, got: '$output'"
    else
        pass "Suppresses all excerpt lines for a deprecated repo"
    fi

    if echo "$output" | grep -q "deprecated-repo" && echo "$output" | grep -qi "deprecated\|archived\|非推奨"; then
        pass "Marks the deprecated repo with a short deprecation note"
    else
        fail "Should mark deprecated-repo with a short deprecation note, got: '$output'"
    fi

    # An unrelated warning (same alert marker, no deprecation keywords) must
    # not trigger suppression -- the marker alone is not sufficient.
    if echo "$output" | grep -qF "Real description line for the active repo."; then
        pass "Keeps the excerpt for an active repo that merely uses the same alert marker"
    else
        fail "Should keep excerpt for active-repo-with-warning, got: '$output'"
    fi
}

# ============================================================
# Test: non-git depth-1 projects are discovered, deeper/doc-less dirs are not
# ============================================================
test_non_git_depth1_project_discovered() {
    echo ""
    echo "=== Testing non-git depth-1 project discovery ==="

    local output
    if ! output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        return
    fi

    if echo "$output" | grep -qF -- "- non-git-project: README.md"; then
        pass "Reports a non-git depth-1 directory that has a README.md"
    else
        fail "Should report non-git depth-1 project with docs, got: '$output'"
    fi

    if echo "$output" | grep -qF "A real description line for the non-git project."; then
        pass "Includes excerpt for the non-git depth-1 project"
    else
        fail "Should include excerpt text for the non-git project, got: '$output'"
    fi

    if echo "$output" | grep -qF -- "non-git-no-docs"; then
        fail "Should not report a non-git depth-1 directory with no doc files, got: '$output'"
    else
        pass "Does not report non-git depth-1 directories with no doc files"
    fi

    if echo "$output" | grep -qF -- "non-git-project/docs"; then
        fail "Should not report doc files nested deeper than depth 1, got: '$output'"
    else
        pass "Does not report non-git doc files nested deeper than depth 1"
    fi

    if echo "$output" | grep -qF -- "depth1-wrapper"; then
        fail "Should not surface a depth-1 dir with no docs even if a deeper subdir has docs, got: '$output'"
    else
        pass "Does not surface a doc-only directory two levels deep"
    fi
}

# ============================================================
# Test: CLAUDE.md-fallback excerpt prefers a description heading and skips
# AI behavior-rule bullets, without affecting README excerpts
# ============================================================
test_claude_fallback_heuristics() {
    echo ""
    echo "=== Testing CLAUDE.md-fallback excerpt heuristics ==="

    local output
    if ! output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        return
    fi

    if echo "$output" | grep -qF "This app helps users track daily habits."; then
        pass "Starts the excerpt from the description heading when one exists"
    else
        fail "Should include the description-heading content, got: '$output'"
    fi

    if echo "$output" | grep -qF "推測ですが"; then
        fail "Should skip AI behavior-rule bullets preceding the description heading, got: '$output'"
    else
        pass "Skips AI behavior-rule bullets preceding the description heading"
    fi

    if echo "$output" | grep -qF "Never fabricate data"; then
        fail "Should skip the English directive bullet preceding the description heading, got: '$output'"
    else
        pass "Skips the English directive bullet preceding the description heading"
    fi

    if echo "$output" | grep -qF -- "- claude-only-no-overview-repo: CLAUDE.md"; then
        pass "Still lists a CLAUDE.md-only repo with no description heading"
    else
        fail "Should still list claude-only-no-overview-repo, got: '$output'"
    fi

    if echo "$output" | grep -qF "断言禁止"; then
        fail "Should skip behavior-rule bullets even with no description heading to fall back to, got: '$output'"
    else
        pass "Skips behavior-rule bullets even with no description heading to fall back to"
    fi

    if echo "$output" | grep -qF "Never skip tests"; then
        fail "Should skip the English directive bullet with no description heading, got: '$output'"
    else
        pass "Skips the English directive bullet with no description heading"
    fi

    if echo "$output" | grep -qF "通知をオンにすることができます"; then
        pass "Does not apply the directive-bullet filter to README excerpts"
    else
        fail "Should keep a README bullet that merely contains the JA directive substring, got: '$output'"
    fi
}

# ============================================================
# Test: the repo that the workspace-root CLAUDE.md symlinks into gets its
# CLAUDE.md excerpt suppressed but keeps its README.md excerpt
# ============================================================
test_self_repo_readme_still_excerpted() {
    echo ""
    echo "=== Testing self-repo (workspace-root CLAUDE.md symlink target) ==="

    local output
    if ! output=$(WORKSPACE="$FAKE_WORKSPACE" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        return
    fi

    if echo "$output" | grep -qF -- "- self-repo: CLAUDE.md, README.md"; then
        pass "Still lists doc files for the self-repo"
    else
        fail "Should still list doc files for self-repo, got: '$output'"
    fi

    if echo "$output" | grep -qF "This CLAUDE.md excerpt line must never appear"; then
        fail "Should suppress the CLAUDE.md excerpt for the self-repo, got: '$output'"
    else
        pass "Suppresses the CLAUDE.md excerpt for the self-repo"
    fi

    if echo "$output" | grep -qF "A real README description line that must still be excerpted."; then
        pass "Still shows the README.md excerpt for the self-repo"
    else
        fail "Should still show the README.md excerpt for self-repo, got: '$output'"
    fi
}

# ============================================================
# Test: workspace with no nested repos at all produces no output
# ============================================================
test_no_nested_repos_silent() {
    echo ""
    echo "=== Testing no nested repos ==="

    local bare_workspace
    bare_workspace=$(mktemp -d)
    init_repo "$bare_workspace"

    local output
    if ! output=$(WORKSPACE="$bare_workspace" bash "$TARGET_SCRIPT"); then
        fail "22-nested-repo-docs.sh exited non-zero"
        rm -rf "$bare_workspace"
        return
    fi

    if [ -z "$output" ]; then
        pass "Produces no output when there are no nested repos"
    else
        fail "Should produce no output with no nested repos, got: '$output'"
    fi

    rm -rf "$bare_workspace"
}

# ============================================================
# Main
# ============================================================
main() {
    echo "========================================"
    echo "nested-repo-docs Setup Script Tests"
    echo "========================================"

    setup
    trap teardown EXIT

    test_script_executable
    test_reports_docs_and_excludes_outer
    test_excerpt_filters_boilerplate
    test_deprecated_repo_excerpt_suppressed
    test_non_git_depth1_project_discovered
    test_claude_fallback_heuristics
    test_self_repo_readme_still_excerpted
    test_no_nested_repos_silent

    echo ""
    echo "========================================"
    echo "Test Results"
    echo "========================================"
    echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
    echo ""

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"

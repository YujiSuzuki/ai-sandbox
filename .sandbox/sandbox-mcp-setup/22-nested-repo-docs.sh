#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# Show which doc files (CLAUDE.md, README.md, README.ja.md) each nested git repo has
# ---
# ネストされたgitリポジトリごとにドキュメントファイル（CLAUDE.md, README.md, README.ja.md）の有無を表示する

WORKSPACE="${WORKSPACE:-/workspace}"
while [ "${WORKSPACE: -1}" = "/" ]; do WORKSPACE="${WORKSPACE%/}"; done
DOC_FILES=(CLAUDE.md README.md README.ja.md)

REPOS=$(find "$WORKSPACE" -maxdepth 8 \
    \( -name node_modules -o -name vendor -o -name dist -o -name build \
       -o -name .build -o -name DerivedData -o -name Carthage \
       -o -name .venv -o -name __pycache__ \) -prune -o \
    -name ".git" \( -type d -o -type f \) -print 2>/dev/null \
  | grep -Fxv "$WORKSPACE/.git" \
  | sed 's|/.git$||' | sort)

[ -z "$REPOS" ] && exit 0

echo "Nested repo docs:"
while IFS= read -r repo_path; do
  rel="${repo_path#"$WORKSPACE"/}"
  found=()
  for doc in "${DOC_FILES[@]}"; do
    [ -f "$repo_path/$doc" ] && found+=("$doc")
  done
  if [ "${#found[@]}" -eq 0 ]; then
    echo "- $rel: (none)"
  else
    joined=$(printf ', %s' "${found[@]}")
    echo "- $rel: ${joined:2}"
  fi
done <<< "$REPOS"

#!/bin/bash
# Show uncommitted changes in nested git repos (outer repo is shown by VSCode gitStatus)

WORKSPACE="${WORKSPACE:-/workspace}"

REPOS=$(find "$WORKSPACE" -maxdepth 3 -name ".git" \( -type d -o -type f \) 2>/dev/null \
  | grep -v "^$WORKSPACE/.git$" \
  | sed 's|/.git$||' | sort)

[ -z "$REPOS" ] && exit 0

ANY=false
while IFS= read -r repo_path; do
  rel="${repo_path#"$WORKSPACE"/}"
  count=$(git -C "$repo_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    echo "Uncommitted changes in nested repo: $rel ($count file(s))"
    ANY=true
  fi
done <<< "$REPOS"

$ANY || echo "All nested git repos are clean."

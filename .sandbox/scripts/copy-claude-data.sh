#!/usr/bin/env bash
# Copies Claude local data (memory, plans, optionally settings) to a destination directory.
# @advertise: true

set -euo pipefail

CLAUDE_DIR="/home/node/.claude"
MEMORY_SRC="$CLAUDE_DIR/projects/-workspace/memory"
PLANS_SRC="$CLAUDE_DIR/plans"
SETTINGS_SRC="$CLAUDE_DIR/settings.json"
PLUGINS_SRC="$CLAUDE_DIR/plugins"

WITH_SETTINGS=false
DEST=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <dest-dir>

Options:
  --with-settings    Also copy settings.json and plugins/
  -h, --help         Show this help

Copied by default:
  memory/   ($MEMORY_SRC)
  plans/    ($PLANS_SRC)

With --with-settings:
  settings.json
  plugins/

Example:
  $(basename "$0") ~/backup/claude
  $(basename "$0") --with-settings ~/backup/claude
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-settings)
            WITH_SETTINGS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            usage
            ;;
        *)
            DEST="$1"
            shift
            ;;
    esac
done

[[ -z "$DEST" ]] && { echo "Error: dest-dir is required" >&2; usage; }

show_diff_if_changed() {
    local src="$1"
    local dest="$2"
    if [[ -f "$dest" ]] && ! diff -q "$src" "$dest" > /dev/null 2>&1; then
        echo "    [diff: $dest]"
        diff --color=always -u "$dest" "$src" | sed 's/^/    /' || true
    fi
}

copy_dir() {
    local src="$1"
    local dest="$2"
    local label="$3"

    if [[ ! -d "$src" ]]; then
        echo "  skip: $label (not found: $src)"
        return
    fi

    mkdir -p "$dest"
    local count=0
    while IFS= read -r -d '' file; do
        local rel="${file#$src/}"
        local dest_file="$dest/$rel"
        mkdir -p "$(dirname "$dest_file")"
        show_diff_if_changed "$file" "$dest_file"
        cp -p "$file" "$dest_file"
        count=$((count + 1))
    done < <(find "$src" -type f -print0)
    echo "  $label: $count file(s) → $dest"
}

copy_file() {
    local src="$1"
    local dest="$2"
    local label="$3"

    if [[ ! -f "$src" ]]; then
        echo "  skip: $label (not found: $src)"
        return
    fi

    mkdir -p "$(dirname "$dest")"
    show_diff_if_changed "$src" "$dest"
    cp -p "$src" "$dest"
    echo "  $label → $dest"
}

mkdir -p "$DEST"

copy_dir "$MEMORY_SRC" "$DEST/memory" "memory"
copy_dir "$PLANS_SRC"  "$DEST/plans"  "plans"

if [[ "$WITH_SETTINGS" == true ]]; then
    copy_file "$SETTINGS_SRC" "$DEST/settings.json" "settings.json"
    copy_dir  "$PLUGINS_SRC"  "$DEST/plugins"       "plugins"
fi

echo "Done → $DEST"

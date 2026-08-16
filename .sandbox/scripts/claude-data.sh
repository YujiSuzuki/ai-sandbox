#!/usr/bin/env bash
# Lists Claude local data (memory, plans, optionally settings) by default; copies with --copy.
# @advertise: true
# ---
# Claude のローカルデータ（memory、plans、任意で settings）をデフォルトで一覧表示し、--copy 指定時のみコピーする。

set -euo pipefail

CLAUDE_DIR="/home/node/.claude"
MEMORY_SRC="$CLAUDE_DIR/projects/-workspace/memory"
PLANS_SRC="$CLAUDE_DIR/plans"
SETTINGS_SRC="$CLAUDE_DIR/settings.json"
PLUGINS_SRC="$CLAUDE_DIR/plugins"

WITH_SETTINGS=false
COPY=false
DEST=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--with-settings]
       $(basename "$0") --copy <dest-dir> [--with-settings]

Options:
  --copy <dest-dir>  Copy source files to dest-dir instead of listing them
  --with-settings    Also list/copy settings.json and plugins/
  -h, --help         Show this help

Listed/copied by default:
  memory/   ($MEMORY_SRC)
  plans/    ($PLANS_SRC)

With --with-settings:
  settings.json
  plugins/

Example:
  $(basename "$0")
  $(basename "$0") --with-settings
  $(basename "$0") --copy ~/backup/claude
  $(basename "$0") --copy ~/backup/claude --with-settings
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --copy)
            COPY=true
            shift
            [[ $# -eq 0 || "$1" == -* || -z "$1" ]] && { echo "Error: --copy requires a dest-dir argument" >&2; usage; }
            DEST="$1"
            shift
            ;;
        --with-settings)
            WITH_SETTINGS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            usage
            ;;
    esac
done

list_path() {
    local path="$1"
    if [[ -d "$path" ]]; then
        find "$path" -type f | sort
    elif [[ -f "$path" ]]; then
        echo "$path"
    fi
}

if [[ "$COPY" == false ]]; then
    list_path "$MEMORY_SRC"
    list_path "$PLANS_SRC"
    if [[ "$WITH_SETTINGS" == true ]]; then
        list_path "$SETTINGS_SRC"
        list_path "$PLUGINS_SRC"
    fi
    exit 0
fi

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

#!/bin/bash
# _secret-tag.sh
# Shared helpers for detecting/extracting "# @secret"-tagged tmpfs entries
# in docker-compose.yml (the convention that replaced the old bare ":ro"
# suffix, since tmpfs has no read-only concept in Compose's short syntax
# and a bare path could plausibly serve some other purpose).
#
# Five remaining bash scripts (check-secret-sync.sh, compare-secret-config.sh,
# sync-compose-secrets.sh, sync-secrets.sh, triage-undeclared-secrets.sh) all
# need to agree on exactly what counts as a tagged entry, so the
# matching/extraction logic lives here once instead of being re-implemented
# per script. Python-migrated scripts (validate-secrets.py,
# check-undeclared-secrets.py) use the equivalent _secret_tag.py instead.
#
# Usage: source this file, then call secret_tag_* functions.
#
#   source "${WORKSPACE:-/workspace}/.sandbox/scripts/_secret-tag.sh"
# ---
# docker-compose.yml 内の "# @secret" タグ付き tmpfs エントリを検出・抽出する
# 共通ヘルパー（旧来の裸の ":ro" サフィックス方式を置き換えた規約。tmpfs には
# Compose の短縮構文上、読み取り専用の概念が無く、裸のパスは秘匿目的以外にも
# 使われ得るため）。
#
# 残り5本のbashスクリプト（check-secret-sync.sh, compare-secret-config.sh,
# sync-compose-secrets.sh, sync-secrets.sh, triage-undeclared-secrets.sh）は
# すべて「タグ付きエントリ」の定義について一致している必要があるため、
# 判定・抽出ロジックをスクリプトごとに個別実装せず、ここに集約している。
# Python移行済みのスクリプト（validate-secrets.py, check-undeclared-secrets.py）
# は同等の _secret_tag.py を使う。
#
# 使用法: このファイルを source してから secret_tag_* 関数を呼ぶ。

# Optional tmpfs option suffix (e.g. ":ro", ":rw,noexec,nosuid,size=1g")
# immediately before the tag, plus the tag itself. Defined once so the
# exact-match regex, the prefix-match regex, and secret_tag_extract_path's
# stripping logic can never drift apart on what "options" means.
# タグの直前に置ける任意の tmpfs オプション接尾辞（例: ":ro",
# ":rw,noexec,nosuid,size=1g"）とタグ本体。exact-match用正規表現・
# prefix-match用正規表現・secret_tag_extract_path の除去ロジックが
# 「オプション」の定義でずれないよう、ここで一度だけ定義する。
SECRET_TAG_SUFFIX_RE='(:[a-zA-Z0-9_,=%]+)?[[:space:]]*#[[:space:]]*@secret([[:space:]]|$)'

# secret_tag_exact_regex <escaped_exact_path>
# Echoes a grep -E / bash [[ =~ ]] compatible regex matching a tmpfs
# short-syntax entry for EXACTLY this path (already regex-escaped by the
# caller), optionally followed by tmpfs options, then the "# @secret" tag.
# Use this when checking whether one specific, already-known path is
# hidden (walking up ancestor directories).
secret_tag_exact_regex() {
    echo "^[[:space:]]*-[[:space:]]*${1}${SECRET_TAG_SUFFIX_RE}"
}

# secret_tag_prefix_regex <escaped_path_prefix>
# Echoes a regex matching a tagged tmpfs entry whose path starts with the
# given prefix (already regex-escaped), with an arbitrary path remainder
# in between (e.g. prefix = $WORKSPACE_RE, matching any secret dir under
# the workspace). Use this when scanning a whole file for tagged entries
# without knowing the exact path up front; recover the clean path
# afterwards with secret_tag_extract_path.
secret_tag_prefix_regex() {
    echo "^[[:space:]]*-[[:space:]]*${1}[^[:space:]#]*${SECRET_TAG_SUFFIX_RE}"
}

# secret_tag_extract_path <line>
# Strip the leading "- ", trailing "# ..." comment, and trailing
# ":<options>" tmpfs option suffix, leaving just the mount path. Safe to
# call on any tmpfs short-syntax line, tagged or not.
secret_tag_extract_path() {
    printf '%s' "$1" \
        | sed -E 's/^[[:space:]]*-[[:space:]]*//' \
        | sed -E 's/[[:space:]]*#.*$//' \
        | sed -E 's/:[a-zA-Z0-9_,=%]+[[:space:]]*$//'
}

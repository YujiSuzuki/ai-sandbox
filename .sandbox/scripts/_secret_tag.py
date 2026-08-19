#!/usr/bin/env python3
# _secret_tag.py
# Shared helpers for detecting/extracting "# @secret"-tagged tmpfs entries
# in docker-compose.yml (the convention that replaced the old bare ":ro"
# suffix, since tmpfs has no read-only concept in Compose's short syntax
# and a bare path could plausibly serve some other purpose).
#
# Named with an underscore (not a hyphen like its bash sibling
# _secret-tag.sh) because Python's `import`/`from ... import` statements
# require a valid identifier -- a hyphenated filename can't be imported that
# way. The Python-migrated secret-sync scripts all need to agree on exactly
# what counts as a tagged entry, so the matching/extraction logic lives here
# once instead of being re-implemented per script -- the Python counterpart
# of _secret-tag.sh, which plays the same role for the bash scripts that
# haven't been migrated yet.
#
# Usage: import from this file, e.g.
#   from _secret_tag import secret_tag_exact_regex, secret_tag_prefix_regex, secret_tag_extract_path
# ---
# docker-compose.yml 内の "# @secret" タグ付き tmpfs エントリを検出・抽出する
# 共通ヘルパー（旧来の裸の ":ro" サフィックス方式を置き換えた規約。tmpfs には
# Compose の短縮構文上、読み取り専用の概念が無く、裸のパスは秘匿目的以外にも
# 使われ得るため）。
#
# bashの姉妹ファイル _secret-tag.sh とは異なりハイフンではなくアンダースコアを
# 使っている: Pythonの `import`/`from ... import` 文は有効な識別子を要求するため、
# ハイフン入りのファイル名はそのままではimportできない。Python移行済みの
# secret-sync系スクリプトはすべて「タグ付きエントリ」の定義について一致している
# 必要があるため、判定・抽出ロジックをスクリプトごとに個別実装せず、ここに
# 集約している -- _secret-tag.sh のPython版であり、まだ移行していない
# bashスクリプト側では引き続き _secret-tag.sh が同じ役割を果たす。
#
# 使用法: このファイルからimportする。例:
#   from _secret_tag import secret_tag_exact_regex, secret_tag_prefix_regex, secret_tag_extract_path

import re

# Optional tmpfs option suffix (e.g. ":ro", ":rw,noexec,nosuid,size=1g")
# immediately before the tag, plus the tag itself. Defined once so the
# exact-match regex, the prefix-match regex, and secret_tag_extract_path's
# stripping logic can never drift apart on what "options" means.
# タグの直前に置ける任意の tmpfs オプション接尾辞（例: ":ro",
# ":rw,noexec,nosuid,size=1g"）とタグ本体。exact-match用正規表現・
# prefix-match用正規表現・secret_tag_extract_path の除去ロジックが
# 「オプション」の定義でずれないよう、ここで一度だけ定義する。
_SECRET_TAG_SUFFIX_RE = r"(:[a-zA-Z0-9_,=%]+)?\s*#\s*@secret(\s|$)"


def secret_tag_exact_regex(escaped_exact_path: str) -> str:
    """Regex string matching a tmpfs short-syntax entry for EXACTLY this path
    (caller must already have regex-escaped it, e.g. via re.escape()),
    optionally followed by tmpfs options, then the "# @secret" tag. Use this
    when checking whether one specific, already-known path is hidden
    (walking up ancestor directories).

    指定したパスに完全一致するtmpfs短縮構文エントリ（任意のtmpfsオプション、
    続けて"# @secret"タグを許容）にマッチする正規表現文字列を返す。呼び出し側は
    あらかじめ re.escape() 等でパスをエスケープしておくこと。特定の既知の
    パス1つが隠蔽されているかを確認する（親ディレクトリを遡る）場合に使う。
    """
    return r"^\s*-\s*" + escaped_exact_path + _SECRET_TAG_SUFFIX_RE


def secret_tag_prefix_regex(escaped_path_prefix: str) -> str:
    """Regex string matching a tagged tmpfs entry whose path starts with the
    given prefix (caller must already have regex-escaped it), with an
    arbitrary path remainder in between. Use this when scanning a whole file
    for tagged entries without knowing the exact path up front; recover the
    clean path afterwards with secret_tag_extract_path.

    指定したプレフィックスで始まるタグ付きtmpfsエントリにマッチする正規表現
    文字列を返す（プレフィックスの後に任意のパスの続きを許容）。呼び出し側は
    あらかじめエスケープしておくこと。事前に正確なパスが分からない状態で
    ファイル全体をタグ付きエントリについて走査する場合に使う。マッチ後の
    クリーンなパスは secret_tag_extract_path で取り出す。
    """
    return r"^\s*-\s*" + escaped_path_prefix + r"[^\s#]*" + _SECRET_TAG_SUFFIX_RE


def secret_tag_extract_path(line: str) -> str:
    """Strip the leading "- ", trailing "# ..." comment, and trailing
    ":<options>" tmpfs option suffix, leaving just the mount path. Safe to
    call on any tmpfs short-syntax line, tagged or not.

    先頭の "- "、末尾の "# ..." コメント、末尾の ":<options>" という tmpfs
    オプション接尾辞を取り除き、マウントパスのみを残す。タグの有無を問わず、
    任意のtmpfs短縮構文の行に対して安全に呼び出せる。
    """
    line = re.sub(r"^\s*-\s*", "", line)
    line = re.sub(r"\s*#.*$", "", line)
    line = re.sub(r":[a-zA-Z0-9_,=%]+\s*$", "", line)
    return line

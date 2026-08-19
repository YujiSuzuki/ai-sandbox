#!/usr/bin/env python3
# check-undeclared-secrets.py
# Warn about files/directories that look like secrets by naming convention
# but are not hidden from AI via docker-compose.yml (Docker volume mount).
# That is the only mechanism that actually removes file content from AI's
# view; .claude/settings.json (permissions.deny) only blocks the Read tool
# and leaves the file itself visible, so it is NOT treated as "declared"
# here -- a path covered solely by permissions.deny still shows up as
# undeclared, annotated with a note that settings.json already covers it.
#
# validate-secrets.py and check-secret-sync.py only verify configuration
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
# validate-secrets.py と check-secret-sync.py は「既に存在する設定」を
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

import fnmatch
import json
import os
import re
import sys
from pathlib import Path

from _python_common import is_lang_ja, load_startup_config, matches_sync_ignore, print_footer, print_title
from _secret_tag import secret_tag_exact_regex

# ─── Host OS guard / ホストOSガード ─────────────────────────────

if not os.environ.get("SANDBOX_ENV") and not os.path.isfile("/.dockerenv"):
    if is_lang_ja():
        print("❌ このスクリプトはホストOSでは実行できません。")
        print()
        print("以下のいずれかの環境で実行してください：")
        print("  • AI Sandbox のターミナル")
        print("  • cli_sandbox/ai_sandbox.sh")
    else:
        print("❌ This script cannot be run on the host OS.")
        print()
        print("Please run in one of these environments:")
        print("  • AI Sandbox terminal")
        print("  • cli_sandbox/ai_sandbox.sh")
    sys.exit(1)

WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))

# Determine which docker-compose.yml to use based on environment
# 環境に応じて使用する docker-compose.yml を決定
sandbox_env = os.environ.get("SANDBOX_ENV", "")
if sandbox_env.startswith("cli_"):
    COMPOSE_FILE = WORKSPACE / "cli_sandbox" / "docker-compose.yml"
else:
    COMPOSE_FILE = WORKSPACE / ".devcontainer" / "docker-compose.yml"

CLAUDE_SETTINGS = WORKSPACE / ".claude" / "settings.json"


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "🕵️  未宣言シークレットのスキャン（手動確認用）",
            "DISCLAIMER": "名前パターンによる検出です。1件ずつ内容を確認してください。",
            "NONE_FOUND": "疑わしいファイルは見つかりませんでした。",
            "HEADER": "⚠️  以下は秘密っぽい名前ですが、docker-compose.yml には未宣言です:",
            "ACTION": "対処方法:",
            "ACTION1": "  .sandbox/scripts/triage-undeclared-secrets.sh を実行し、",
            "ACTION2": "  docker-compose.yml に追記、または、.sandbox/config/sync-ignore に記載してください",
            "CLAUDE_ONLY_NOTE": "（.claude/settings.json では既にカバー済み。ただしdocker-compose.ymlのようにファイル内容自体を隠すものではありません）",
            "IGNORED_HEADER": "無視されたファイル (sync-ignore パターンにマッチ):",
            "CHECKED_SUMMARY": "チェック対象: %d 件 / docker-compose宣言済み: %d 件 / うち settings.json のみでカバー(未宣言扱い): %d 件 / 無視: %d 件",
        }
    return {
        "TITLE": "🕵️  Undeclared Secrets Scan (manual check)",
        "DISCLAIMER": "This is a name-pattern detection -- review each one before acting.",
        "NONE_FOUND": "No suspicious files found.",
        "HEADER": "⚠️  These look like secrets by name, but are NOT declared in docker-compose.yml:",
        "ACTION": "Action:",
        "ACTION1": "  Run .sandbox/scripts/triage-undeclared-secrets.sh, then",
        "ACTION2": "  add it to docker-compose.yml, or list it in .sandbox/config/sync-ignore",
        "CLAUDE_ONLY_NOTE": "(already covered by .claude/settings.json -- but that doesn't hide the file's content the way docker-compose.yml does)",
        "IGNORED_HEADER": "Ignored files (matched sync-ignore patterns):",
        "CHECKED_SUMMARY": "Checked: %d / Declared in docker-compose.yml: %d / Of those still undeclared, settings.json-only: %d / Ignored: %d",
    }


# ─── Candidate scan / 候補スキャン ───────────────────────────────

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
_SECRET_FILE_PATTERNS = (
    ".env*", "*.key", "*.pem", "*.p12", "*.cer", "*.mobileprovision",
    "GoogleService-Info.plist", "Secrets.swift", "*.xcconfig",
)

# Directories pruned from the scan: heavy/vendored/generated trees that
# would only add noise or slow the search down.
# スキャン対象から除外するディレクトリ: 重い/vendor/生成物系のツリーで、
# ノイズになるか探索を遅くするだけのもの。
_PRUNE_DIRS = {
    "node_modules", ".git", "vendor", "Pods", "dist", "build", ".build",
    "DerivedData", "Carthage", ".venv", "__pycache__",
}


def find_secret_like_candidates(workspace: Path) -> list:
    """Walk workspace once, pruning heavy/vendored trees, collecting both
    secret-like files and "secrets"-named directories in a single pass.

    ワークスペースを1回だけ走査し、重い/vendor系ツリーを除外しつつ、
    秘密っぽいファイルと"secrets"という名前のディレクトリを1回のパスで集める。
    """
    results = []
    for root, dirs, files in os.walk(workspace):
        dirs[:] = [d for d in dirs if d not in _PRUNE_DIRS]
        for d in dirs:
            if d == "secrets":
                results.append(os.path.join(root, d))
        for f in files:
            if any(fnmatch.fnmatchcase(f, pat) for pat in _SECRET_FILE_PATTERNS):
                results.append(os.path.join(root, f))
    return results


# Compose file content is read once and cached here (as a plain list of
# lines), so is_path_hidden_by_compose below can match against it without
# re-reading the file for every candidate path times every ancestor
# directory it has.
# composeファイルの内容を1回だけ読み込みここにキャッシュしておく（単純な行の
# リスト）。これにより下の is_path_hidden_by_compose は、候補パス×祖先
# ディレクトリの数だけファイルを再読込せずに済む。
def _load_compose_lines(compose_file: Path) -> list:
    if not compose_file.is_file():
        return []
    return compose_file.read_text().splitlines()


def is_path_hidden_by_compose(path: str, compose_lines: list, workspace: Path) -> bool:
    """Check if a path is hidden via docker-compose.yml (/dev/null file
    mount, or tmpfs mount on the path itself or an ancestor directory).

    docker-compose.yml で隠蔽されているかチェック（/dev/nullマウント、
    またはそのパス自身か祖先ディレクトリへのtmpfsマウント）。
    """
    if not compose_lines:
        return False

    escaped_path = re.escape(path)
    devnull_re = re.compile(r"^\s*-\s*/dev/null:" + escaped_path + r"(:ro)?$")
    for line in compose_lines:
        if devnull_re.search(line):
            return True

    check_path = path
    workspace_str = str(workspace)
    while check_path != workspace_str and check_path != "/" and check_path:
        escaped_check_path = re.escape(check_path)
        # A tmpfs: entry only hides a path when tagged with a trailing
        # "# @secret" comment; see _secret_tag.py for the shared matching
        # regex used by all Python-migrated secret-sync scripts.
        # tmpfs: エントリは末尾に "# @secret" タグが付いている場合のみ隠蔽と
        # みなす。共通のマッチング正規表現は _secret_tag.py を参照
        # （Python移行済みの secret-sync 系スクリプトすべてで共有）。
        tmpfs_re = re.compile(secret_tag_exact_regex(escaped_check_path))
        for line in compose_lines:
            if tmpfs_re.search(line):
                return True
        parent = os.path.dirname(check_path)
        if parent == check_path:
            break
        check_path = parent

    return False


# ─── .claude/settings.json deny patterns / denyパターン ──────────

def extract_claude_deny_patterns(claude_settings: Path) -> list:
    """Extract Read() deny patterns from the (merged) workspace
    .claude/settings.json.

    （マージ済みの）workspace .claude/settings.json から Read() deny
    パターンを抽出する。
    """
    if not claude_settings.is_file():
        return []
    try:
        data = json.loads(claude_settings.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    deny = (data.get("permissions") or {}).get("deny") or []
    patterns = []
    for item in deny:
        if not isinstance(item, str):
            continue
        m = re.match(r"^Read\(([^)]+)\)$", item)
        if m:
            patterns.append(m.group(1))
    return sorted(set(patterns))


def is_path_denied_by_claude_settings(path: str, workspace: Path, deny_patterns: list) -> bool:
    """Check if a path matches any Read() deny pattern.

    パスがいずれかの Read() deny パターンにマッチするかチェック。
    """
    prefix = str(workspace) + "/"
    rel_path = path[len(prefix):] if path.startswith(prefix) else path
    filename = os.path.basename(path)

    for pattern in deny_patterns:
        if not pattern:
            continue

        if pattern.endswith("/"):
            dir_pattern = pattern[:-1]
            if dir_pattern.startswith("**/"):
                # Strip only the literal leading "**/" (3 chars) -- a naive
                # rstrip/lstrip-style "longest match" removal here would
                # over-broaden a multi-segment suffix like "**/api/secrets"
                # down to just "secrets".
                # 先頭の "**/" (3文字) のみをリテラルに除去する -- 素朴な
                # 最長一致除去だと "**/api/secrets" のような複数セグメントの
                # サフィックスが単なる "secrets" に潰れてしまう。
                dir_suffix = dir_pattern[3:]
                # Match the directory itself (at any depth) AND everything
                # beneath it -- a directory-style deny pattern must hide the
                # whole subtree, mirroring is_path_hidden_by_compose's
                # ancestor walk for tmpfs mounts above.
                # ディレクトリ自身（任意の深さ）とその配下すべてにマッチさせる
                # -- ディレクトリ指定のdenyパターンはサブツリー全体を隠す必要が
                # あり、上の is_path_hidden_by_compose のtmpfsマウント祖先探索と
                # 同じ考え方。
                if (fnmatch.fnmatchcase(rel_path, dir_suffix)
                        or fnmatch.fnmatchcase(rel_path, "*/" + dir_suffix)
                        or fnmatch.fnmatchcase(rel_path, dir_suffix + "/*")
                        or fnmatch.fnmatchcase(rel_path, "*/" + dir_suffix + "/*")):
                    return True
            elif rel_path == dir_pattern or rel_path.startswith(dir_pattern + "/"):
                return True
            continue

        if pattern.startswith("**/"):
            suffix = pattern[3:]
            if "/" in suffix:
                if fnmatch.fnmatchcase(rel_path, suffix) or fnmatch.fnmatchcase(rel_path, "*/" + suffix):
                    return True
            elif fnmatch.fnmatchcase(filename, suffix):
                return True
        elif "*" in pattern:
            if fnmatch.fnmatchcase(rel_path, pattern):
                return True
        elif rel_path == pattern:
            return True

    return False


# ─── JSON helpers / JSONヘルパー ─────────────────────────────────

def to_rel_paths(paths: list, workspace: Path) -> list:
    prefix = str(workspace) + "/"
    return sorted(p[len(prefix):] if p.startswith(prefix) else p for p in paths)


# ─── Main / メイン処理 ──────────────────────────────────────────

def main() -> None:
    fmt = "text"
    if len(sys.argv) > 1 and sys.argv[1] == "--format":
        fmt = sys.argv[2] if len(sys.argv) > 2 else "text"

    candidates = sorted(set(find_secret_like_candidates(WORKSPACE)))
    compose_lines = _load_compose_lines(COMPOSE_FILE)
    deny_patterns = extract_claude_deny_patterns(CLAUDE_SETTINGS)

    undeclared = []
    claude_only = []
    ignored = []
    declared_count = 0

    for path in candidates:
        if matches_sync_ignore(path):
            ignored.append(path)
            continue

        if is_path_hidden_by_compose(path, compose_lines, WORKSPACE):
            declared_count += 1
            continue

        undeclared.append(path)
        if is_path_denied_by_claude_settings(path, WORKSPACE, deny_patterns):
            claude_only.append(path)

    total_checked = len(candidates)

    undeclared_rel = to_rel_paths(undeclared, WORKSPACE)
    claude_only_rel_set = set(to_rel_paths(claude_only, WORKSPACE))
    ignored_rel = to_rel_paths(ignored, WORKSPACE)

    if fmt == "json":
        print(json.dumps({
            "undeclared": undeclared_rel,
            "claude_only": sorted(claude_only_rel_set),
            "ignored": ignored_rel,
            "declared_count": declared_count,
            "total_checked": total_checked,
        }))
        sys.exit(0)

    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    verbosity = load_startup_config()["verbosity"]

    print_title(msgs["TITLE"], verbosity)
    print(msgs["DISCLAIMER"])
    print()

    if not undeclared_rel:
        print(msgs["NONE_FOUND"])
    else:
        print(msgs["HEADER"])
        print()
        for rel_path in undeclared_rel:
            if rel_path in claude_only_rel_set:
                print(f"   📄 {rel_path}  {msgs['CLAUDE_ONLY_NOTE']}")
            else:
                print(f"   📄 {rel_path}")
        print()
        print(msgs["ACTION"])
        print(msgs["ACTION1"])
        print(msgs["ACTION2"])

    if ignored_rel:
        print()
        print(msgs["IGNORED_HEADER"])
        for rel_path in ignored_rel:
            print(f"   📄 {rel_path}")

    print()
    print(msgs["CHECKED_SUMMARY"] % (total_checked, declared_count, len(claude_only_rel_set), len(ignored_rel)))
    print_footer(verbosity)

    sys.exit(0)


if __name__ == "__main__":
    main()

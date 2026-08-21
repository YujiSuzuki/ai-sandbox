#!/usr/bin/env python3
# check-secret-sync.py
# Check if files blocked in AI settings are also hidden in docker-compose.yml
#
# This script runs at AI Sandbox startup and warns if there are files that should
# be hidden from AI but are not configured in docker-compose.yml volume mounts.
#
# Supported AI settings files:
#   - .claude/settings.json  (Claude Code)
#   - .aiexclude             (Gemini Code Assist)
#   - .geminiignore          (Gemini CLI)
#
# .gitignore is intentionally NOT supported because it contains many non-secret patterns
# (node_modules/, dist/, *.log, .DS_Store) that would create noise in the sync check.
# AI exclusion files should explicitly list only secrets, keeping intent clear.
#
# Container-only: the docker-compose.yml hidden-file declarations it checks
# against always target the fixed in-container path /workspace/<path>, not
# wherever the repo happens to live on the host, so this comparison is only
# meaningful when $WORKSPACE is actually /workspace (i.e. running inside the
# container where that path is the live mount root).
# @env: container
# ---
# AI設定でブロックされたファイルが docker-compose.yml でも隠蔽されているかチェック
# このスクリプトは AI Sandbox 起動時に実行され、AI から隠すべきファイルが
# docker-compose.yml のボリュームマウントに設定されていない場合に警告します。
#
# 対応するAI設定ファイル:
#   - .claude/settings.json  (Claude Code)
#   - .aiexclude             (Gemini Code Assist)
#   - .geminiignore          (Gemini CLI)
#
# 注意: .gitignore は意図的にサポートしていません。
#
# 理由:
#   .gitignore には秘匿情報以外のパターン（node_modules/, dist/, *.log 等）が
#   多く含まれ、同期チェックでノイズになります。AI除外ファイルには秘匿情報のみを
#   明示的に記載することで、意図が明確になりメンテナンスも容易になります。
#
# コンテナ専用: 照合対象の docker-compose.yml の隠蔽宣言は常にコンテナ内の
# 固定パス /workspace/<path> を指しており、リポジトリがホスト上のどこに
# あるかとは無関係。そのため $WORKSPACE が実際に /workspace であるとき
# （＝コンテナ内で、そのパスが実マウントのルートであるとき）のみ、
# この照合は意味を持つ。

import fnmatch
import glob as globmod
import json
import os
import re
import sys
from pathlib import Path

from _python_common import is_lang_ja, is_quiet, is_summary, load_startup_config, matches_sync_ignore, print_default, print_footer, print_title
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
WORKSPACE_STR = str(WORKSPACE)

# Determine which docker-compose.yml to use based on environment
# 環境に応じて使用する docker-compose.yml を決定
sandbox_env = os.environ.get("SANDBOX_ENV", "")
if sandbox_env.startswith("cli_"):
    COMPOSE_FILE = WORKSPACE / "cli_sandbox" / "docker-compose.yml"
else:
    COMPOSE_FILE = WORKSPACE / ".devcontainer" / "docker-compose.yml"

CLAUDE_SETTINGS = WORKSPACE / ".claude" / "settings.json"

# Directories to ignore when searching for files matching a deny pattern
# (find_matching_files). Note find_gemini_ignore_files below uses a
# DIFFERENT, narrower set (node_modules/.git only, no .sandbox) -- this
# mismatch exists in the bash original and is preserved here rather than
# "fixed", to keep behavior identical.
# deny パターンに一致するファイルを検索する際に除外するディレクトリ
# （find_matching_files）。下の find_gemini_ignore_files は異なる、より
# 狭い集合（node_modules/.gitのみ、.sandboxなし）を使う -- この不一致は
# bash版に元々あるもので、挙動を変えないためそのまま維持している。
_FIND_MATCHING_PRUNE_DIRS = {"node_modules", ".git", ".sandbox"}
_GEMINI_FIND_PRUNE_DIRS = {"node_modules", ".git"}


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "🔄 シークレット設定同期チェック",
            "NO_SETTINGS": "✓ シークレット同期: Claude 設定ファイルが見つかりません",
            "NO_COMPOSE": "✓ シークレット同期: docker-compose.yml が見つかりません",
            "ALL_SYNCED": "✅ すべての秘匿ファイルが docker-compose.yml に設定されています",
            "MISSING_HEADER": "⚠️  以下のファイルが docker-compose.yml に未設定です:",
            "MISSING_FOOTER": "これらのファイルはいずれかの AI設定でブロックされていますが、",
            "MISSING_FOOTER2": "docker-compose.yml のボリュームマウントに設定されていません。",
            "MISSING_FOOTER3": "AI Sandbox 内では AI がこれらのファイルを読める可能性があります。",
            "ACTION": "対処方法:",
            "ACTION1": "  手動で docker-compose.yml を編集する（ホストOS側で）",
            "ACTION2": "  または: .sandbox/scripts/sync-secrets.py を実行（シェル環境で）",
            "ACTION3": "  秘匿不要なら: .sandbox/config/sync-ignore にパターンを追加",
            "NO_DENY": "✓ シークレット同期: AI設定にファイルパターンがありません",
            "NO_FILES": "✓ シークレット同期: 該当するファイルが見つかりませんでした",
            "QUIET_MISSING": "⚠️  %d 個のファイルが docker-compose.yml に未設定です",
            "SUMMARY_OK": "✓ シークレット同期: 全件設定済み（%d 件チェック、%d 件無視）",
            "IGNORED_HEADER": "無視されたファイル (sync-ignore パターンにマッチ):",
        }
    return {
        "TITLE": "🔄 Secret Config Sync Check",
        "NO_SETTINGS": "✓ Secret sync: Claude settings file not found",
        "NO_COMPOSE": "✓ Secret sync: docker-compose.yml not found",
        "ALL_SYNCED": "✅ All secret files are configured in docker-compose.yml",
        "MISSING_HEADER": "⚠️  The following files are NOT configured in docker-compose.yml:",
        "MISSING_FOOTER": "These files are blocked in one or more AI settings but",
        "MISSING_FOOTER2": "not configured in docker-compose.yml volume mounts.",
        "MISSING_FOOTER3": "AI may be able to read these files inside AI Sandbox.",
        "ACTION": "Action required:",
        "ACTION1": "  Manually edit docker-compose.yml (on host OS)",
        "ACTION2": "  Or run: .sandbox/scripts/sync-secrets.py (in shell environment)",
        "ACTION3": "  If not secret: add pattern to .sandbox/config/sync-ignore",
        "NO_DENY": "✓ Secret sync: No file patterns in AI settings",
        "NO_FILES": "✓ Secret sync: No matching files found",
        "QUIET_MISSING": "⚠️  %d files missing from docker-compose.yml",
        "SUMMARY_OK": "✓ Secret sync: all configured (%d checked, %d ignored)",
        "IGNORED_HEADER": "Ignored files (matched sync-ignore patterns):",
    }


# ─── Extraction / 抽出 ──────────────────────────────────────────

def extract_claude_patterns(settings_file: Path) -> list:
    """Extract Read() patterns from .claude/settings.json.

    .claude/settings.json から Read() パターンを抽出
    """
    if not settings_file.is_file():
        return []
    try:
        data = json.loads(settings_file.read_text())
        deny = data["permissions"]["deny"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError):
        return []
    if not isinstance(deny, list):
        return []
    patterns = []
    for item in deny:
        if not isinstance(item, str):
            continue
        m = re.match(r"^Read\(([^)]+)\)$", item)
        if m:
            patterns.append(m.group(1))
    return sorted(set(patterns))


def extract_aiexclude_patterns(aiexclude_file: Path) -> list:
    """Extract patterns from .aiexclude-style files (Gemini Code Assist /
    Gemini CLI). gitignore-style patterns, filter out comments and empty
    lines.

    .aiexclude / .geminiignore ファイルからパターンを抽出。gitignore形式の
    パターン、コメントと空行を除外。
    """
    if not aiexclude_file.is_file():
        return []
    patterns = []
    for line in aiexclude_file.read_text().splitlines():
        if line.startswith("#"):
            continue
        if line.strip() == "":
            continue
        patterns.append(line)
    return sorted(set(patterns))


def find_gemini_ignore_files(workspace: Path) -> list:
    """Find all Gemini ignore files in workspace (.aiexclude, .geminiignore).

    ワークスペース内のすべての Gemini 除外ファイルを検索
    """
    results = []
    for root, dirs, files in os.walk(workspace):
        dirs[:] = [d for d in dirs if d not in _GEMINI_FIND_PRUNE_DIRS]
        for f in files:
            if f in (".aiexclude", ".geminiignore"):
                results.append(os.path.join(root, f))
    return results


# ─── Pattern-to-files matching / パターン→ファイルのマッチング ───

def _walk_files(root: Path) -> list:
    """All files under root (recursively), pruning the same dirs
    find_matching_files' bash `find` calls would via its ignore options.

    root配下の全ファイル（再帰的）。find_matching_files のbash `find`呼び出しが
    ignoreオプション経由で除外していたのと同じディレクトリを除外する。
    """
    results = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in _FIND_MATCHING_PRUNE_DIRS]
        for f in files:
            results.append(os.path.join(dirpath, f))
    return results


def _find_dirs_matching_suffix(workspace: Path, suffix: str) -> list:
    """All directories anywhere under workspace whose path relative to
    workspace equals `suffix` or ends with "/" + suffix -- i.e. a match at
    any depth that respects path-segment boundaries (a single- or
    multi-segment suffix like "secrets" or "app/secrets" both work).

    workspace配下のディレクトリのうち、workspace相対パスが`suffix`と完全
    一致するか、"/" + `suffix` で終わるものすべて -- パスの区切りを尊重した
    任意の深さでのマッチ（"secrets" のような単一セグメントでも
    "app/secrets" のような複数セグメントのサフィックスでも動作する）。
    """
    results = []
    workspace_str = str(workspace)
    for dirpath, dirs, _files in os.walk(workspace):
        dirs[:] = [d for d in dirs if d not in _FIND_MATCHING_PRUNE_DIRS]
        for d in dirs:
            full = os.path.join(dirpath, d)
            rel = full[len(workspace_str) + 1:]
            if rel == suffix or rel.endswith("/" + suffix):
                results.append(full)
    return results


def find_matching_files(pattern: str, workspace: Path) -> list:
    """Find files matching a deny pattern, scoping a specific (non-"**/"-
    prefixed) path pattern to its literal location rather than matching by
    basename anywhere in the workspace.

    Convention: a "**/" prefix means "at any depth"; anything else is a
    literal path (or glob) relative to $WORKSPACE. Without this scoping, a
    specific pattern like "demo-app/.env" would match any ".env" file
    anywhere in the workspace instead of just demo-app/.env, and a
    trailing-slash directory pattern like "secrets/" would need to be
    handled by the same unscoped logic and end up matching nothing at all.

    deny パターンに一致するファイルを検索する。"**/"接頭辞を伴わない特定の
    パスパターンを、ワークスペース内のどこでもベース名一致させるのではなく、
    その文字通りの場所にスコープする。

    規約: "**/"接頭辞は「任意の深さで」を意味する。それ以外は $WORKSPACE
    からのリテラルなパス（またはglob）として扱う。このスコープが無いと、
    "demo-app/.env"のような特定パターンがdemo-app/.envだけでなくワークスペース
    中のどの".env"ファイルにもマッチしてしまい、"secrets/"のような末尾スラッシュ
    のディレクトリパターンも同じ無スコープロジックに巻き込まれてゼロ件マッチに
    なってしまう。
    """
    # Directory patterns (trailing slash) / ディレクトリパターン（末尾スラッシュ）
    if pattern.endswith("/"):
        dir_pattern = pattern[:-1]
        if dir_pattern.startswith("**/"):
            suffix = dir_pattern[3:]
            results = []
            for d in _find_dirs_matching_suffix(workspace, suffix):
                results.extend(_walk_files(Path(d)))
            return results
        full_dir = workspace / dir_pattern
        if full_dir.is_dir():
            return _walk_files(full_dir)
        return []

    # Directory-recursive-glob suffix, e.g. "secrets/**" or "**/secrets/**"
    # ディレクトリ再帰glob接尾辞（例: "secrets/**", "**/secrets/**"）
    if pattern.endswith("/**"):
        dir_part = pattern[: -len("/**")]
        if dir_part.startswith("**/"):
            suffix = dir_part[3:]
            results = []
            for d in _find_dirs_matching_suffix(workspace, suffix):
                results.extend(_walk_files(Path(d)))
            return results
        full_dir = workspace / dir_part
        if full_dir.is_dir():
            return _walk_files(full_dir)
        return []

    # Recursive file glob, e.g. "**/*.env" or "**/sub/*.key"
    # 再帰ファイルglob（例: "**/*.env", "**/sub/*.key"）
    if pattern.startswith("**/"):
        suffix = pattern[3:]
        results = []
        for dirpath, dirs, files in os.walk(workspace):
            dirs[:] = [d for d in dirs if d not in _FIND_MATCHING_PRUNE_DIRS]
            for f in files:
                full = os.path.join(dirpath, f)
                rel = full[len(str(workspace)) + 1:]
                if fnmatch.fnmatchcase(rel, suffix) or fnmatch.fnmatchcase(rel, "*/" + suffix):
                    results.append(full)
        return results

    # Specific path pattern relative to $WORKSPACE, e.g. "demo-app/.env", or
    # a root-level glob like "*.key" (glob.glob doesn't cross "/" boundaries,
    # so this only ever matches at the exact directory level named).
    # $WORKSPACE からの具体的パスパターン（例: "demo-app/.env"）、または
    # ルートレベルのglob（例: "*.key"。glob.globは"/"境界を越えないため、
    # 指定した階層でのみマッチする）。
    full_path = workspace / pattern
    if "*" in pattern:
        return sorted(globmod.glob(str(full_path)))
    if full_path.is_file():
        return [str(full_path)]
    if full_path.is_dir():
        return _walk_files(full_path)
    return []


def is_file_in_compose(file_path: str, compose_file: Path, workspace: Path) -> bool:
    """Check if a file is configured in docker-compose.yml.

    ファイルが docker-compose.yml に設定されているかチェック
    """
    escaped_file_path = re.escape(file_path)
    devnull_re = re.compile(r"^\s*-\s*/dev/null:" + escaped_file_path + r"(:ro)?$")
    try:
        compose_lines = compose_file.read_text().splitlines()
    except OSError:
        compose_lines = []
    for line in compose_lines:
        if devnull_re.search(line):
            return True

    # Check tmpfs mounts (for directories). Only matches a tmpfs entry
    # tagged with a trailing "# @secret" comment -- see _secret_tag.py for
    # the shared matching regex used by the Python-migrated secret-sync
    # scripts, so this check always agrees with validate-secrets.py /
    # compare-secret-config.py / check-undeclared-secrets.py on what counts
    # as a tagged entry.
    # tmpfs マウントをチェック（ディレクトリ用）。末尾に "# @secret" タグが
    # 付いているエントリのみを対象とする。共通のマッチング正規表現は
    # _secret_tag.py を参照（Python移行済みのsecret-sync系スクリプトで共有し、
    # validate-secrets.py / compare-secret-config.py / check-undeclared-secrets.py
    # 等と判定が常に一致するようにする）。
    workspace_str = str(workspace)
    dir_path = os.path.dirname(file_path)
    while dir_path != workspace_str and dir_path != "/":
        escaped_dir_path = re.escape(dir_path)
        tmpfs_re = re.compile(secret_tag_exact_regex(escaped_dir_path))
        for line in compose_lines:
            if tmpfs_re.search(line):
                return True
        dir_path = os.path.dirname(dir_path)

    return False


# ─── Main / メイン処理 ──────────────────────────────────────────

def main() -> None:
    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    verbosity = load_startup_config()["verbosity"]

    # Check if settings file exists
    # 設定ファイルの存在確認
    if not CLAUDE_SETTINGS.is_file():
        print_default(msgs['NO_SETTINGS'], verbosity)
        sys.exit(0)

    # Check if compose file exists
    # compose ファイルの存在確認
    if not COMPOSE_FILE.is_file():
        print_default(msgs['NO_COMPOSE'], verbosity)
        sys.exit(0)

    # Get deny patterns from Claude settings
    # Claude 設定から deny パターンを取得
    claude_patterns = extract_claude_patterns(CLAUDE_SETTINGS)

    # Get patterns from all Gemini ignore files (.aiexclude, .geminiignore)
    # すべての Gemini 除外ファイルからパターンを取得
    gemini_patterns = []
    for ignore_file in find_gemini_ignore_files(WORKSPACE):
        gemini_patterns.extend(extract_aiexclude_patterns(Path(ignore_file)))

    # Combine all patterns
    # すべてのパターンを結合
    patterns = sorted(set(claude_patterns) | set(gemini_patterns))

    if not patterns:
        print_default(msgs['NO_DENY'], verbosity)
        sys.exit(0)

    # Find all files matching deny patterns
    # deny パターンに一致するすべてのファイルを検索
    all_matching = set()
    for pattern in patterns:
        all_matching.update(find_matching_files(pattern, WORKSPACE))
    all_matching_files = sorted(all_matching)

    if not all_matching_files:
        print_default(msgs['NO_FILES'], verbosity)
        sys.exit(0)

    # Check which files are NOT in docker-compose.yml
    # Also filter out files matching sync-ignore patterns
    # docker-compose.yml に設定されていないファイルを確認
    # sync-ignore パターンにマッチするファイルも除外
    missing_files = []
    ignored_files = []
    for file in all_matching_files:
        if matches_sync_ignore(file):
            ignored_files.append(file)
            continue
        if not is_file_in_compose(file, COMPOSE_FILE, WORKSPACE):
            missing_files.append(file)

    def rel(f: str) -> str:
        prefix = WORKSPACE_STR + "/"
        return f[len(prefix):] if f.startswith(prefix) else f

    # ============================================================
    # Quiet mode: only show if missing files / クワイエットモード: 未設定ファイルがある場合のみ表示
    # ============================================================
    if is_quiet(verbosity):
        if missing_files:
            print(msgs["QUIET_MISSING"] % len(missing_files))
            for file in missing_files:
                print(f"   📄 {rel(file)}")
        sys.exit(0)

    # ============================================================
    # Summary mode: problem explanation + action required / サマリーモード: 問題の説明と対応が必要な内容を表示
    # ============================================================
    if is_summary(verbosity):
        if missing_files:
            print()
            print(msgs["MISSING_HEADER"])
            print()
            for file in missing_files:
                print(f"   📄 {rel(file)}")
            print()
            print(msgs["MISSING_FOOTER"])
            print(msgs["MISSING_FOOTER2"])
            print(msgs["MISSING_FOOTER3"])
            print()
            print(msgs["ACTION"])
            print(msgs["ACTION1"])
            print(msgs["ACTION2"])
            print(msgs["ACTION3"])
            print()
        else:
            print(msgs["SUMMARY_OK"] % (len(all_matching_files), len(ignored_files)))
        sys.exit(0)

    # ============================================================
    # Verbose mode: full output / 詳細モード: 全出力を表示
    # ============================================================
    print_title(msgs["TITLE"], verbosity)

    # Report results
    # 結果を報告
    if not missing_files:
        print(msgs["ALL_SYNCED"])
        if ignored_files:
            print()
            print(msgs["IGNORED_HEADER"])
            for file in ignored_files:
                print(f"   📄 {rel(file)}")
    else:
        print(msgs["MISSING_HEADER"])
        print()
        for file in missing_files:
            print(f"   📄 {rel(file)}")
        print()
        print(msgs["MISSING_FOOTER"])
        print(msgs["MISSING_FOOTER2"])
        print(msgs["MISSING_FOOTER3"])
        print()
        print(msgs["ACTION"])
        print(msgs["ACTION1"])
        print(msgs["ACTION2"])
        print(msgs["ACTION3"])

        if ignored_files:
            print()
            print(msgs["IGNORED_HEADER"])
            for file in ignored_files:
                print(f"   📄 {rel(file)}")

    print_footer(verbosity)
    sys.exit(0)


if __name__ == "__main__":
    main()

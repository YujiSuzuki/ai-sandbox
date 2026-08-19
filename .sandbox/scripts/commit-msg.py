#!/usr/bin/env python3
# commit-msg.py
# Generate commit message draft from staged changes for AI-assisted refinement, then commit
# @advertise: true
#
# Usage:
#   .sandbox/scripts/commit-msg.py [options]
#
# Options:
#   --msg-file <file>  Use refined message file to commit
#   --log [n]          Show recent n commit messages for style reference (default: 10)
#   --style <style>    Subject style: "verb" (Add ...) or "cc" (feat: ...) (default: verb)
#   --repo <path>      Target git repository (default: current directory)
#   --amend            Amend the previous commit (use with --msg-file)
#   --help, -h         Show this help
#
# Environment:
#   COMMIT_MSG_STYLE   Default style ("verb" or "cc"). Overridden by --style flag.
#
# AI Workflow:
#   1. Run commit-msg.py to generate a draft.
#   2. Run commit-msg.py --log to check the tone and structure of your commit message.
#   3. Refine the draft in CommitMsg-draft.md to match the project's style
#      NOTE: When --repo is used, CommitMsg-draft.md is written INSIDE the repo directory
#            (e.g., --repo /path/to/repo  =>  /path/to/repo/CommitMsg-draft.md)
#            Edit that file, NOT a file in the current working directory.
#      NOTE: Ground every bullet in `git diff --cached` for that file, not in your own
#            editing-session memory. For files with status A (new), describe what the
#            code does now -- do NOT use before/after language ("fix", "not just X",
#            "changed from Y") unless that prior state is an actual commit in `git log`.
#            A reader of `git log`/`git blame` has no visibility into your pre-commit
#            editing history, only into the repository's.
#   4. Show the draft to the user for approval
#      IMPORTANT: ALL placeholders (<変更内容を記述> / <describe change> etc.) MUST be
#                 replaced with real text. Do NOT proceed to step 5 with placeholder text.
#   5. Run commit-msg.py --msg-file CommitMsg-draft.md to commit
#      WARNING: When --repo is used, --msg-file must be an ABSOLUTE path.
#               --repo causes `cd <repo>`, so a relative path resolves inside the repo,
#               not in your current working directory.
#               WRONG: --msg-file CommitMsg-draft.md --repo /path/to/repo
#               RIGHT: --msg-file /path/to/repo/CommitMsg-draft.md --repo /path/to/repo
#
# Examples:
#   .sandbox/scripts/commit-msg.py                              # Generate draft
#   .sandbox/scripts/commit-msg.py --style cc                   # Conventional Commits style
#   .sandbox/scripts/commit-msg.py --log                        # Show recent commits
#   .sandbox/scripts/commit-msg.py --msg-file CommitMsg-draft.md  # Commit
#   .sandbox/scripts/commit-msg.py --repo /path/to/other-repo   # Target another repo
#   .sandbox/scripts/commit-msg.py --msg-file /abs/path/CommitMsg-draft.md --repo /path/to/other-repo  # Commit to other repo (absolute path required)
# ---
# ステージ済み変更からコミットメッセージのドラフトを生成し、AI と推敲してからコミットする
#
# 使用法:
#   .sandbox/scripts/commit-msg.py [options]
#
# オプション:
#   --msg-file <file>  推敲済みメッセージファイルを指定してコミット
#   --log [n]          直近 n 件のコミットメッセージをスタイル参考用に表示（デフォルト: 10）
#   --style <style>    サブジェクトのスタイル: "verb" (Add ...) or "cc" (feat: ...) (デフォルト: verb)
#   --repo <path>      対象の git リポジトリ（デフォルト: カレントディレクトリ）
#   --amend            直前のコミットを修正（--msg-file と併用）
#   --help, -h         ヘルプ表示
#
# AI ワークフロー:
#   1. commit-msg.py を実行してドラフトを生成
#   2. commit-msg.py --log でコミットメッセージのトーンや構成を確認する
#   3. CommitMsg-draft.md のドラフトをプロジェクトのスタイルに合わせて推敲する
#      注意: --repo を指定した場合、CommitMsg-draft.md はそのリポジトリ内に生成される
#            （例: --repo /path/to/repo  =>  /path/to/repo/CommitMsg-draft.md）
#            カレントディレクトリではなく、そのファイルを編集すること。
#      注意: 各箇条書きは、そのファイルの `git diff --cached` を根拠にすること。自分の
#            編集セッション中の記憶を根拠にしないこと。status が A（新規）のファイルは
#            「今のコードが何をするか」を書き、before/after表現（"修正"、"〜だけでなく"、
#            "〜から変更"）は、その以前の状態が `git log` 上の実際のコミットとして
#            存在する場合以外は使わないこと。`git log`/`git blame` を見る人には、
#            コミット前のあなたの編集履歴は見えず、リポジトリの履歴しか見えない。
#   4. ユーザーにドラフトを提示して承認を得る
#      重要: <変更内容を記述> などのプレースホルダーを実際の内容に置き換えること。
#            プレースホルダーが残ったままでステップ5に進んではならない。
#   5. commit-msg.py --msg-file CommitMsg-draft.md でコミット実行
#      注意: --repo を指定する場合、--msg-file は必ず絶対パスにすること。
#            --repo 指定時にスクリプト内で `cd <repo>` が実行されるため、
#            相対パスはリポジトリルート基準で解決され、意図しないファイルを読む。
#            NG: --msg-file CommitMsg-draft.md --repo /path/to/other-repo
#            OK: --msg-file /path/to/other-repo/CommitMsg-draft.md --repo /path/to/other-repo
#
# 環境変数:
#   COMMIT_MSG_STYLE   デフォルトスタイル ("verb" or "cc")。--style フラグで上書き可能。

import os
import re
import subprocess
import sys
import tempfile
from collections import Counter

from _python_common import is_lang_ja

# ─── Colors & helpers / カラー出力・ヘルパー関数 ────────────────

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"


def info(text: str) -> None:
    print(f"{CYAN}ℹ️  {text}{NC}")


def ok(text: str) -> None:
    print(f"{GREEN}✅ {text}{NC}")


def warn(text: str) -> None:
    print(f"{YELLOW}⚠️  {text}{NC}")


def err(text: str) -> None:
    print(f"{RED}❌ {text}{NC}", file=sys.stderr)


def die(text: str) -> None:
    err(text)
    sys.exit(1)


# ─── Language detection / 言語検出 ─────────────────────────────

def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "TITLE": "📝 コミットメッセージ ドラフト",
            "NO_STAGED": "ステージ済みの変更がありません。先に 'git add <files>' を実行してください。",
            "STAGED_FILES": "ステージ済みファイル数:",
            "MSG_NOT_FOUND": "メッセージファイルが見つかりません:",
            "MSG_EMPTY": "メッセージファイルが空です:",
            "ANALYSIS": "📊 変更分析",
            "DETECTED": "検出カテゴリ:",
            "STYLE_LABEL": "スタイル:",
            "RECENT": "📜 直近のコミット（スタイル参考用）",
            "DRAFT": "📋 ドラフト",
            "WROTE": "を出力しました。",
            "NEXT_STEPS": "次のステップ:",
            "STEP1": "1. プロジェクトのコミットスタイルを確認:",
            "STEP2": "2. ドラフトをスタイルに合わせて推敲",
            "STEP2_NOTE": "→ git diff --cached の実差分を根拠にすること。新規ファイル(A)にbefore/after表現（修正、〜だけでなく等）は使わない",
            "STEP3": "3. 推敲が完了したらコミット実行:",
            "RECENT_TITLE": "📜 直近 %s 件のコミット",
            "NO_COMMITS": "コミットが見つかりません。",
            "COMMIT_TITLE": "📋 コミットメッセージ",
            "STAGED_LABEL": "ステージ済みファイル:",
            "CONFIRM": "コミットしますか？",
            "CANCELLED": "キャンセルしました。",
            "COMMITTED": "コミット成功！",
            "COMMIT_FAILED": "git commit に失敗しました。",
            "EXTRACT_FAILED": "コミットメッセージを抽出できません:",
            "DRAFT_SUBJECT_HINT": "<変更内容を記述>",
            "DRAFT_BODY_HINT": "<変更の詳細を記述>",
        }
    return {
        "TITLE": "📝 Commit Message Draft",
        "NO_STAGED": "No staged changes. Run 'git add <files>' first.",
        "STAGED_FILES": "Staged files:",
        "MSG_NOT_FOUND": "Message file not found:",
        "MSG_EMPTY": "Message file is empty:",
        "ANALYSIS": "📊 Change Analysis",
        "DETECTED": "Detected categories:",
        "STYLE_LABEL": "Style:",
        "RECENT": "📜 Recent commits (for style reference)",
        "DRAFT": "📋 Draft",
        "WROTE": "written.",
        "NEXT_STEPS": "Next steps:",
        "STEP1": "1. Check the project's commit style:",
        "STEP2": "2. Refine the draft to match the style",
        "STEP2_NOTE": "→ Ground it in git diff --cached, not session memory. Don't use before/after language (\"fix\", \"not just X\") for new (A) files",
        "STEP3": "3. When refined, commit:",
        "RECENT_TITLE": "📜 Recent %s commits",
        "NO_COMMITS": "No commits found.",
        "COMMIT_TITLE": "📋 Commit Message",
        "STAGED_LABEL": "Staged files:",
        "CONFIRM": "Commit?",
        "CANCELLED": "Cancelled.",
        "COMMITTED": "Committed successfully!",
        "COMMIT_FAILED": "git commit failed.",
        "EXTRACT_FAILED": "Could not extract commit message from:",
        "DRAFT_SUBJECT_HINT": "<describe change>",
        "DRAFT_BODY_HINT": "<describe details>",
    }


# ─── Git helpers / git ヘルパー ─────────────────────────────────

def git_output(args: list) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    return result.stdout


def git_log_inherit(count: int) -> bool:
    """Runs `git log` with output inherited directly to our own stdout (not
    captured), matching the original bash script's uncaptured invocation --
    this way git's own tty detection decides whether to emit %C(...) color
    codes, same as it would running directly in the shell.

    出力をキャプチャせず自分自身の標準出力にそのまま流す `git log` 実行。
    元のbashスクリプトが未キャプチャで呼んでいたのと同じにすることで、
    %C(...)の色付けをするかどうかの判定をgit自身のtty検出に委ねる（シェルで
    直接実行した場合と同じ挙動になる）。
    """
    result = subprocess.run(
        ["git", "log", "-n", str(count), "--format=  %C(dim)%h%C(reset) %s%n%w(0,4,4)%+b"],
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def git_log_last_summary_inherit() -> None:
    subprocess.run(
        ["git", "log", "-1", "--format=  %C(dim)%h%C(reset) %s"],
        stderr=subprocess.DEVNULL,
    )


# ─── Help / ヘルプ ─────────────────────────────────────────────

def show_help() -> None:
    print("""Usage: .sandbox/scripts/commit-msg.py [options]

Options:
  --msg-file <file>  Use refined message file to commit
  --log [n]          Show recent n commit messages for style reference (default: 10)
  --style <style>    Subject style: "verb" (Add ...) or "cc" (feat: ...)
  --repo <path>      Target git repository (default: current directory)
  --amend            Amend the previous commit (use with --msg-file)
  --help, -h         Show this help

Environment:
  COMMIT_MSG_STYLE   Default style (default: verb). Overridden by --style.

Styles:
  verb  - Imperative verb start: "Add feature", "Fix bug", "Update docs"
  cc    - Conventional Commits: "feat: add feature", "fix: resolve bug"

Workflow:
  1. git add <files>                                          # Stage changes
  2. .sandbox/scripts/commit-msg.py                           # Generate draft
  3. .sandbox/scripts/commit-msg.py --log                     # Check style
  4. Refine CommitMsg-draft.md with AI                        # Collaborate
  5. .sandbox/scripts/commit-msg.py --msg-file CommitMsg-draft.md  # Commit

Multi-repo example:
  .sandbox/scripts/commit-msg.py --repo /path/to/other-repo
  .sandbox/scripts/commit-msg.py --repo /path/to/other-repo --msg-file CommitMsg-draft.md""")
    sys.exit(0)


# ─── Argument parsing / 引数のパース ────────────────────────────

def parse_args(argv: list) -> dict:
    opts = {
        "msg_file": "",
        "show_log": False,
        "log_count": 10,
        "amend": False,
        "repo": "",
        "style": os.environ.get("COMMIT_MSG_STYLE", "verb"),
    }

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--msg-file":
            if i + 1 >= len(argv) or argv[i + 1] == "":
                die("--msg-file requires a file path")
            opts["msg_file"] = argv[i + 1]
            i += 2
        elif arg == "--log":
            opts["show_log"] = True
            if i + 1 < len(argv) and argv[i + 1].isdigit():
                opts["log_count"] = int(argv[i + 1])
                i += 1
            i += 1
        elif arg == "--style":
            if i + 1 >= len(argv) or argv[i + 1] == "":
                die("--style requires 'verb' or 'cc'")
            style = argv[i + 1]
            if style not in ("verb", "cc"):
                die(f"Unknown style: {style} (use 'verb' or 'cc')")
            opts["style"] = style
            i += 2
        elif arg == "--repo":
            if i + 1 >= len(argv) or argv[i + 1] == "":
                die("--repo requires a directory path")
            opts["repo"] = argv[i + 1]
            i += 2
        elif arg == "--amend":
            opts["amend"] = True
            i += 1
        elif arg in ("--help", "-h"):
            show_help()
        elif arg.startswith("-"):
            die(f"Unknown option: {arg}")
        else:
            die(f"Unexpected argument: {arg}")

    return opts


# ─── Analyze staged changes / ステージ済み変更の分析 ───────────

def analyze_changes() -> str:
    files_added = files_modified = files_deleted = files_renamed = 0
    lines_added = lines_removed = 0
    file_list = []

    for line in git_output(["diff", "--cached", "--name-status"]).splitlines():
        parts = line.split("\t")
        status = parts[0]
        file = parts[1] if len(parts) > 1 else ""
        rest = parts[2] if len(parts) > 2 else ""
        if status == "A":
            files_added += 1
        elif status == "M":
            files_modified += 1
        elif status == "D":
            files_deleted += 1
        elif status.startswith("R"):
            files_renamed += 1
        file_list.append(rest or file)

    for line in git_output(["diff", "--cached", "--numstat"]).splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) < 2:
            continue
        added, removed = fields[0], fields[1]
        if added == "-":
            continue
        lines_added += int(added)
        lines_removed += int(removed)

    ext_counter = Counter(name.rsplit(".", 1)[-1] if "." in name else name for name in file_list)
    ext_counts = sorted(ext_counter.items(), key=lambda kv: (-kv[1], kv[0]))[:5]

    out = ["### Staged Changes Summary", ""]
    out.append("| Type | Count |")
    out.append("|------|-------|")
    if files_added > 0:
        out.append(f"| Added | {files_added} |")
    if files_modified > 0:
        out.append(f"| Modified | {files_modified} |")
    if files_deleted > 0:
        out.append(f"| Deleted | {files_deleted} |")
    if files_renamed > 0:
        out.append(f"| Renamed | {files_renamed} |")
    out.append("")
    out.append(f"**Lines:** +{lines_added} / -{lines_removed}")
    out.append("")

    out.append("### Files")
    out.append("")
    for line in git_output(["diff", "--cached", "--name-status"]).splitlines():
        parts = line.split("\t")
        status = parts[0]
        file = parts[1] if len(parts) > 1 else ""
        rest = parts[2] if len(parts) > 2 else ""
        icon = {"A": "+", "M": "~", "D": "-"}.get(status, "→" if status.startswith("R") else "?")
        if rest:
            out.append(f"  {icon} {file} → {rest}")
        else:
            out.append(f"  {icon} {file}")
    out.append("")

    if ext_counts:
        out.append("### Top File Types")
        out.append("")
        for ext, count in ext_counts:
            out.append(f"  {count}x .{ext}")
        out.append("")

    return "\n".join(out)


# ─── Classify staged changes / ステージ済み変更の分類 ──────────

def classify_changes() -> list:
    status_list = git_output(["diff", "--cached", "--name-status"])
    file_list = git_output(["diff", "--cached", "--name-only"])

    categories = []

    if re.search(r"(README|CLAUDE\.md|GEMINI\.md|\.md$|docs/)", file_list, re.IGNORECASE | re.MULTILINE):
        categories.append("docs")
    if re.search(r"(_test\.go|\.test\.|test-|spec\.|__tests__)", file_list, re.IGNORECASE | re.MULTILINE):
        categories.append("test")
    if re.search(r"(\.yaml$|\.yml$|\.json$|\.toml$|\.conf$|Makefile|Dockerfile|docker-compose)", file_list, re.IGNORECASE | re.MULTILINE):
        categories.append("config")
    if re.search(r"^A", status_list, re.MULTILINE):
        categories.append("add")
    if re.search(r"^D", status_list, re.MULTILINE):
        categories.append("remove")
    if re.search(r"^R", status_list, re.MULTILINE):
        categories.append("rename")

    diff_content = git_output(["diff", "--cached", "--unified=0"])
    if re.search(r"(fix|bug|patch|hotfix|correct|resolve)", diff_content, re.IGNORECASE):
        categories.append("fix")
    if re.search(r"(refactor|cleanup|reorganize|simplify|extract|inline)", diff_content, re.IGNORECASE):
        categories.append("refactor")

    if not categories:
        categories.append("update")

    return sorted(set(categories))


# ─── Generate draft / ドラフト生成 ───────────────────────────────

def generate_draft(msgs: dict, style: str, draft_file: str, repo: str) -> str:
    categories = classify_changes()

    names = [name for name in git_output(["diff", "--cached", "--name-only"]).splitlines() if name]
    scope_counter = Counter(name.rsplit("/", 1)[0] if "/" in name else name for name in names)
    common_scope = ""
    if scope_counter:
        common_scope = sorted(scope_counter.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]

    bullet_hints = ""
    for line in git_output(["diff", "--cached", "--name-status"]).splitlines():
        parts = line.split("\t")
        status = parts[0]
        file = parts[1] if len(parts) > 1 else ""
        rest = parts[2] if len(parts) > 2 else ""
        target = rest or file
        if status == "A":
            bullet_hints += f"- Add {target}\n"
        elif status == "D":
            bullet_hints += f"- Remove {target}\n"
        elif status.startswith("R"):
            bullet_hints += f"- Rename {file} to {rest}\n"
        elif status == "M":
            bullet_hints += f"- Update {target}\n"

    if style == "cc":
        prefix_map = {
            "add": "feat", "fix": "fix", "docs": "docs", "test": "test",
            "refactor": "refactor", "config": "chore", "remove": "chore",
            "rename": "refactor",
        }
        prefix_suggestions = [prefix_map.get(cat, "feat") for cat in categories]

        seen = []
        for p in prefix_suggestions:
            if p not in seen:
                seen.append(p)
        unique_prefixes = ", ".join(seen)

        primary_prefix = prefix_suggestions[0]
        scope_part = ""
        if common_scope:
            scope_name = common_scope.rsplit("/", 1)[-1]
            if scope_name != primary_prefix:
                scope_part = f"({scope_name})"

        subject_hint = f"{primary_prefix}{scope_part}: {msgs['DRAFT_SUBJECT_HINT']}"
        style_comment = (
            f"<!-- Style: cc (Conventional Commits) | Prefixes: {unique_prefixes} -->\n"
            "<!-- Format: <type>(<scope>): <description>  (scope is optional) -->"
        )
    else:
        verb_map = {
            "add": ["Add"], "fix": ["Fix"], "docs": ["Update", "Add"],
            "test": ["Add", "Fix"], "refactor": ["Refactor", "Simplify"],
            "config": ["Update", "Configure"], "remove": ["Remove"], "rename": ["Rename"],
        }
        verb_suggestions = []
        for cat in categories:
            verb_suggestions.extend(verb_map.get(cat, ["Update", "Improve"]))

        seen = []
        for v in verb_suggestions:
            if v not in seen:
                seen.append(v)
        unique_verbs = ", ".join(seen)
        primary_verb = verb_suggestions[0]

        if len(names) == 1:
            basename_file = os.path.basename(names[0])
            subject_hint = f"{primary_verb} {msgs['DRAFT_SUBJECT_HINT']} in {basename_file}"
        else:
            scope_suffix = f" in {common_scope}" if common_scope else ""
            subject_hint = f"{primary_verb} {msgs['DRAFT_SUBJECT_HINT']}{scope_suffix}"

        style_comment = f"<!-- Style: verb (imperative) | Verbs: {unique_verbs} -->"

    scope_hint = common_scope or "project root"

    # rstrip: mirrors bash's `DRAFT=$(generate_draft)`, where command
    # substitution strips all trailing newlines before the single newline
    # that `echo "$DRAFT"` / the file write re-adds.
    # rstrip: bashの `DRAFT=$(generate_draft)` ではコマンド置換が末尾の改行を
    # すべて取り除き、`echo "$DRAFT"` やファイル書き込みが改行を1つだけ
    # 付け直す、という挙動を再現している。
    return f"""# Commit Message Draft

<!-- Generated by commit-msg.py -->
<!-- Lines starting with # or <!-- are stripped when committing -->
{style_comment}
<!-- Scope hint: {scope_hint} -->
<!-- To commit: .sandbox/scripts/commit-msg.py --msg-file {draft_file} -->

{subject_hint}

{bullet_hints}
{msgs['DRAFT_SUBJECT_HINT']}

{msgs['DRAFT_BODY_HINT']}""".rstrip("\n")


# ─── Parse message file / メッセージファイルの解析 ──────────────

def parse_message(path: str) -> str:
    with open(path) as f:
        raw_lines = f.read().split("\n")

    lines = []
    for line in raw_lines:
        if line.startswith("<!--"):
            continue
        if re.match(r"^##? ", line):
            continue
        lines.append(line)

    start = 0
    while start < len(lines) and lines[start].strip() == "":
        start += 1
    end = len(lines) - 1
    while end >= 0 and lines[end].strip() == "":
        end -= 1
    if start > end:
        return ""
    return "\n".join(lines[start:end + 1])


# ─── Main / メイン ────────────────────────────────────────────

def main() -> None:
    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    opts = parse_args(sys.argv[1:])
    draft_file = "CommitMsg-draft.md"

    if opts["repo"]:
        if not os.path.isdir(opts["repo"]):
            die(f"Repository directory not found: {opts['repo']}")
        os.chdir(opts["repo"])

    if opts["show_log"]:
        print()
        print(f"{BOLD}{msgs['RECENT_TITLE'] % opts['log_count']}{NC}")
        print("──────────────────────────────────────")
        print()
        if not git_log_inherit(opts["log_count"]):
            warn(msgs["NO_COMMITS"])
        print("──────────────────────────────────────")
        print()
        sys.exit(0)

    print()
    print(f"{BOLD}{msgs['TITLE']}{NC}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print()

    if not opts["msg_file"]:
        print()
        print(f"{BOLD}{msgs['RECENT_TITLE'] % opts['log_count']}{NC}")
        print("──────────────────────────────────────")
        print()
        if not git_log_inherit(opts["log_count"]):
            warn(msgs["NO_COMMITS"])
        print("──────────────────────────────────────")
        print()

        staged_count = len([f for f in git_output(["diff", "--cached", "--name-only"]).splitlines() if f])
        if staged_count == 0:
            die(msgs["NO_STAGED"])
        ok(f"{msgs['STAGED_FILES']} {staged_count}")
        print()

    if opts["msg_file"]:
        if not os.path.isfile(opts["msg_file"]):
            die(f"{msgs['MSG_NOT_FOUND']} {opts['msg_file']}")
        if os.path.getsize(opts["msg_file"]) == 0:
            die(f"{msgs['MSG_EMPTY']} {opts['msg_file']}")

    if not opts["msg_file"]:
        print(f"{BOLD}{msgs['ANALYSIS']}{NC}")
        print("──────────────────────────────────────")
        print()
        print(analyze_changes())
        print("──────────────────────────────────────")
        print()

        categories = classify_changes()
        print(f"{DIM}{msgs['DETECTED']} {', '.join(categories)}{NC}")
        print(f"{DIM}{msgs['STYLE_LABEL']} {opts['style']}{NC}")
        print()

        print(f"{BOLD}{msgs['RECENT']}{NC}")
        print("──────────────────────────────────────")
        print()
        git_log_inherit(5)
        print()
        print("──────────────────────────────────────")
        print()

        draft = generate_draft(msgs, opts["style"], draft_file, opts["repo"])

        print(f"{BOLD}{msgs['DRAFT']}{NC}")
        print("──────────────────────────────────────")
        print()
        print(draft)
        print("──────────────────────────────────────")

        with open(draft_file, "w") as f:
            f.write(draft + "\n")

        print()
        ok(f"{draft_file} {msgs['WROTE']}")
        print()
        repo_flag = f" --repo {os.getcwd()}" if opts["repo"] else ""

        print(f"  {BOLD}{msgs['NEXT_STEPS']}{NC}")
        print(f"    {msgs['STEP1']}")
        print(f"      {CYAN}.sandbox/scripts/commit-msg.py --log{repo_flag}{NC}")
        print(f"    {msgs['STEP2']}")
        print(f"      {DIM}{msgs['STEP2_NOTE']}{NC}")
        print(f"    {msgs['STEP3']}")
        print(f"      {CYAN}.sandbox/scripts/commit-msg.py --msg-file {draft_file}{repo_flag}{NC}")
        print()
        sys.exit(0)

    # ─── Commit mode (--msg-file) / コミット実行モード ──────────────

    commit_msg = parse_message(opts["msg_file"])

    if not commit_msg:
        die(f"{msgs['EXTRACT_FAILED']} {opts['msg_file']}")

    if "<変更内容を記述>" in commit_msg:
        die("プレースホルダーが残っています。CommitMsg-draft.md を推敲してから再実行してください。")
    if "<describe change>" in commit_msg:
        die("Placeholder text remains. Refine CommitMsg-draft.md before committing.")

    print(f"{BOLD}{msgs['COMMIT_TITLE']}{NC}")
    print("──────────────────────────────────────")
    print()
    print(commit_msg)
    print()
    print("──────────────────────────────────────")

    staged = git_output(["diff", "--cached", "--name-status"])
    if staged.strip():
        print()
        print(f"{DIM}{msgs['STAGED_LABEL']}{NC}")
        for line in staged.splitlines():
            parts = line.split("\t")
            status = parts[0]
            file = parts[1] if len(parts) > 1 else ""
            rest = parts[2] if len(parts) > 2 else ""
            if rest:
                print(f"  {DIM}{status}  {file} → {rest}{NC}")
            else:
                print(f"  {DIM}{status}  {file}{NC}")

    print()
    amend_label = " (amend)" if opts["amend"] else ""
    try:
        confirm = input(f"{YELLOW}{msgs['CONFIRM']}{amend_label} [y/N]: {NC}")
    except EOFError:
        # Closed/non-interactive stdin: treat as "no" rather than raising,
        # matching the guard github-release.py's own confirmation already has.
        # 非対話的でstdinが閉じている場合は「no」として扱う（github-release.py
        # 側の確認プロンプトに既にある防御と同じ扱いにする）。
        confirm = ""
    if confirm not in ("y", "Y"):
        info(msgs["CANCELLED"])
        sys.exit(0)

    fd, temp_msg = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "w") as f:
            f.write(commit_msg + "\n")

        commit_args = ["commit", "-F", temp_msg]
        if opts["amend"]:
            commit_args.append("--amend")
        result = subprocess.run(["git", *commit_args])
    finally:
        os.unlink(temp_msg)

    if result.returncode != 0:
        die(msgs["COMMIT_FAILED"])

    print()
    ok(msgs["COMMITTED"])
    print()

    git_log_last_summary_inherit()
    print()


if __name__ == "__main__":
    main()

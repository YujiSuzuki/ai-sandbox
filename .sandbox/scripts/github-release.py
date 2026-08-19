#!/usr/bin/env python3
# github-release.py
# Generate release notes draft for AI-assisted refinement, then publish
# @advertise: true
#
# Usage:
#   .sandbox/scripts/github-release.py <version> [options]
#
# Arguments:
#   <version>     Release version (e.g. v0.4.0). Must be semver with v prefix.
#
# Options:
#   --notes-file <file>  Use refined release notes file to create tag + GitHub Release
#   --prev               Show the latest GitHub Release notes for reference
#   --repo <path>        Target git repository (default: current directory)
#   --help, -h           Show this help
#
# AI Workflow:
#   1. Run github-release.py <version> to generate draft (auto-categorizes commits)
#   2. Run github-release.py --prev to check the previous release tone
#   3. Refine the draft in ReleaseNotes-draft.md to match the project's tone
#      NOTE: When --repo is used, ReleaseNotes-draft.md is written INSIDE the repo directory
#            (e.g., --repo /path/to/repo  =>  /path/to/repo/ReleaseNotes-draft.md)
#            Edit that file, NOT a file in the current working directory.
#      NOTE: The draft lists one entry per commit (mechanical `git log` output). If the
#            same feature/fix was touched by multiple commits within this release (e.g.
#            Add X -> Fix X -> Adjust X), consolidate them into a single net-effect entry.
#            Release notes describe the change since the PREVIOUS release, not the
#            in-between commit history.
#   4. Show the draft to the user for approval
#   5. Run github-release.py <version> --notes-file ReleaseNotes-draft.md to publish
#      NOTE: Relative paths are resolved from your current working directory, not the repo.
#            Both relative and absolute paths work correctly.
#
# Examples:
#   .sandbox/scripts/github-release.py v0.4.0                              # Generate draft
#   .sandbox/scripts/github-release.py --prev                               # Show previous release
#   .sandbox/scripts/github-release.py v0.4.0 --notes-file notes.md        # Publish release
#   .sandbox/scripts/github-release.py v0.4.0 --repo /path/to/other-repo   # Target another repo
#   .sandbox/scripts/github-release.py v0.4.0 --repo /path/to/other-repo --notes-file notes.md
# ---
# リリースノートのドラフトを生成し、AI と推敲してからリリースする
#
# 使用法:
#   .sandbox/scripts/github-release.py <version> [options]
#
# 引数:
#   <version>     リリースバージョン（例: v0.4.0）。v付き semver 形式。
#
# オプション:
#   --notes-file <file>  推敲済みリリースノートを指定してタグ + GitHub Release を作成
#   --prev               直近の GitHub Release のリリースノートを表示
#   --repo <path>        対象の git リポジトリ（デフォルト: カレントディレクトリ）
#   --help, -h           ヘルプ表示
#
# AI ワークフロー:
#   1. github-release.py <version> を実行してドラフトを生成（コミットを自動分類）
#   2. github-release.py --prev で直近リリースのトーンを確認する
#   3. ReleaseNotes-draft.md のドラフトをプロジェクトのトーンに合わせて推敲する
#      注意: --repo を指定した場合、ReleaseNotes-draft.md はそのリポジトリ内に生成される
#            （例: --repo /path/to/repo  =>  /path/to/repo/ReleaseNotes-draft.md）
#            カレントディレクトリではなく、そのファイルを編集すること。
#      注意: ドラフトは `git log` の出力そのままでコミット単位の1行になっている。
#            同じ機能・修正が今回のリリース内で複数コミットにまたがる場合
#            （例: Add X -> Fix X -> Adjust X）は、正味の変更点として1つにまとめること。
#            リリースノートに書くのは「前回リリースからの差分」であり、
#            リリース内の変遷（コミット履歴）ではない。
#   4. ユーザーにドラフトを提示して承認を得る
#   5. github-release.py <version> --notes-file ReleaseNotes-draft.md でリリース実行
#      注意: 相対パスはカレントディレクトリ基準で解決される（リポジトリ内ではない）。
#            相対パス・絶対パスどちらでも正しく動作する。

import json
import os
import re
import shutil
import subprocess
import sys

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
            "RELEASE_TITLE": "🚀 リリース:",
            "VERSION_FORMAT": "バージョンは v付き semver 形式で指定してください（例: v0.4.0）。指定値:",
            "NOT_MAIN": "'main' ブランチで実行してください。現在のブランチ:",
            "NOT_CLEAN": "ワーキングツリーがクリーンではありません。先にコミットまたは stash してください。",
            "NOTES_NOT_FOUND": "ノートファイルが見つかりません:",
            "NOTES_EMPTY": "ノートファイルが空です:",
            "TAG_EXISTS": "タグ %s はすでに存在します。",
            "NO_PREV_TAG": "前回のタグが見つかりません。最初のタグは手動で作成してください。",
            "PREFLIGHT": "事前チェック通過",
            "NO_COMMITS": "前回のタグ %s 以降のコミットがありません。リリースするものがありません。",
            "DRAFT_TITLE": "📋 リリースノート ドラフト",
            "WROTE": "を出力しました。",
            "CONSOLIDATE_HINT": "ヒント: 各項目はコミット単位。同じ機能・修正が今回のリリース内で複数コミットにまたがる場合は、正味の変更点として1つにまとめること（書くのは前回リリースからの差分。リリース内の変遷は書かない）。",
            "NEXT_STEPS": "次のステップ:",
            "STEP1": "1. 前回のリリースノートのトーンを確認:",
            "STEP2": "2. ドラフトをトーンに合わせて推敲",
            "STEP3": "3. 推敲が完了したらリリース実行:",
            "NOTES_TITLE": "📋 リリースノート",
            "CONFIRM_TAG": "タグ %s を作成して push しますか？",
            "CANCELLED": "キャンセルしました。",
            "TAG_CREATED": "タグ %s を作成しました",
            "TAG_PUSHED": "タグ %s を origin に push しました",
            "GH_CREATED": "GitHub Release を作成しました",
            "GH_FAILED": "gh release create に失敗しました（GitHub 未認証の可能性があります。gh auth status で確認してください）。",
            "GH_NOT_FOUND": "gh CLI が見つかりません。",
            "GH_NOT_FOUND_PREFLIGHT": "gh CLI が見つかりません。タグの作成・push は行えますが、GitHub Release の作成は手動になります。",
            "GH_NOT_AUTHENTICATED": "gh CLI は認証されていません（gh auth login で認証できます）。タグの作成・push は行えますが、GitHub Release の作成は手動になります。",
            "MANUAL_RELEASE": "手動でリリースを作成してください:",
            "PASTE_NOTES": "リリースノートを貼り付けてください:",
            "RELEASE_COMPLETE": "リリース %s 完了！ 🎉",
            "LATEST_RELEASE": "📌 最新リリース:",
            "NO_RELEASES": "リリースが見つかりません。",
            "VERSION_REQUIRED": "バージョン引数が必要です。使用法: github-release.py <version> [--notes-file <file>]",
            "REQUIRES_GH": "gh CLI または curl が必要です。",
            "PREV_MANUAL_HINT": "以下の URL で直接確認できます:",
            "NO_REPO": "git remote から GitHub リポジトリを検出できません。",
        }
    return {
        "RELEASE_TITLE": "🚀 Release:",
        "VERSION_FORMAT": "Version must be semver with v prefix (e.g. v0.4.0). Got:",
        "NOT_MAIN": "Must be on 'main' branch. Currently on:",
        "NOT_CLEAN": "Working tree is not clean. Commit or stash changes first.",
        "NOTES_NOT_FOUND": "Notes file not found:",
        "NOTES_EMPTY": "Notes file is empty:",
        "TAG_EXISTS": "Tag %s already exists.",
        "NO_PREV_TAG": "No previous tag found. Create the first tag manually.",
        "PREFLIGHT": "Pre-flight checks passed",
        "NO_COMMITS": "No commits since %s. Nothing to release.",
        "DRAFT_TITLE": "📋 Release Notes Draft",
        "WROTE": "written.",
        "CONSOLIDATE_HINT": "Tip: entries are one-per-commit. If the same feature/fix was touched by multiple commits within this release, consolidate them into a single net-effect entry (describe the change since the previous release, not the in-between commit history).",
        "NEXT_STEPS": "Next steps:",
        "STEP1": "1. Check the previous release tone:",
        "STEP2": "2. Refine the draft to match the tone",
        "STEP3": "3. When refined, publish the release:",
        "NOTES_TITLE": "📋 Release Notes",
        "CONFIRM_TAG": "Create tag %s and push?",
        "CANCELLED": "Cancelled.",
        "TAG_CREATED": "Tag %s created",
        "TAG_PUSHED": "Tag %s pushed to origin",
        "GH_CREATED": "GitHub Release created",
        "GH_FAILED": "gh release create failed (this may be due to a GitHub authentication issue — check with 'gh auth status').",
        "GH_NOT_FOUND": "gh CLI not found.",
        "GH_NOT_FOUND_PREFLIGHT": "gh CLI not found. Tag creation and push will still work, but GitHub Release creation will require manual steps.",
        "GH_NOT_AUTHENTICATED": "gh CLI is not authenticated (run 'gh auth login'). Tag creation and push will still work, but GitHub Release creation will require manual steps.",
        "MANUAL_RELEASE": "Create the release manually:",
        "PASTE_NOTES": "Paste the release notes from:",
        "RELEASE_COMPLETE": "Release %s complete! 🎉",
        "LATEST_RELEASE": "📌 Latest Release:",
        "NO_RELEASES": "No releases found.",
        "VERSION_REQUIRED": "Version argument required. Usage: github-release.py <version> [--notes-file <file>]",
        "REQUIRES_GH": "Requires gh CLI or curl.",
        "PREV_MANUAL_HINT": "You can check directly at:",
        "NO_REPO": "Could not detect GitHub repository from git remote.",
    }


# ─── Git remote helpers / git remote ヘルパー ───────────────────

def git_output(args: list) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    return result.stdout


def get_github_repo() -> str:
    remote_url = git_output(["remote", "get-url", "origin"]).strip()
    repo = re.sub(r"^.*github\.com[:/]", "", remote_url)
    repo = re.sub(r"\.git$", "", repo)
    return repo


def get_github_web_url() -> str:
    remote_url = git_output(["remote", "get-url", "origin"]).strip()
    url = re.sub(r"^git@github\.com:", "https://github.com/", remote_url)
    url = re.sub(r"\.git$", "", url)
    return url


# ─── Help / ヘルプ ─────────────────────────────────────────────

def show_help() -> None:
    print("""Usage: .sandbox/scripts/github-release.py <version> [options]

Arguments:
  <version>     Release version (e.g. v0.4.0)

Options:
  --notes-file <file>  Use refined release notes to create tag + GitHub Release
  --prev               Show the latest GitHub Release notes for reference
  --repo <path>        Target git repository (default: current directory)
  --help, -h           Show this help

Workflow:
  1. github-release.py v0.4.0                          # Generate draft
  2. github-release.py --prev                          # Check previous release
  3. Refine ReleaseNotes-draft.md with AI              # Collaborate
  4. github-release.py v0.4.0 --notes-file ReleaseNotes-draft.md  # Publish

Multi-repo example:
  .sandbox/scripts/github-release.py v0.4.0 --repo /path/to/other-repo
  .sandbox/scripts/github-release.py v0.4.0 --repo /path/to/other-repo --notes-file /abs/path/notes.md""")
    sys.exit(0)


# ─── Argument parsing / 引数のパース ────────────────────────────

def parse_args(argv: list) -> dict:
    opts = {"version": "", "notes_file": "", "show_prev": False, "repo": ""}

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--notes-file":
            if i + 1 >= len(argv) or argv[i + 1] == "":
                die("--notes-file requires a file path")
            opts["notes_file"] = argv[i + 1]
            i += 2
        elif arg == "--prev":
            opts["show_prev"] = True
            i += 1
        elif arg == "--repo":
            if i + 1 >= len(argv) or argv[i + 1] == "":
                die("--repo requires a directory path")
            opts["repo"] = argv[i + 1]
            i += 2
        elif arg in ("--help", "-h"):
            show_help()
        elif arg.startswith("-"):
            die(f"Unknown option: {arg}")
        else:
            if opts["version"]:
                die(f"Unexpected argument: {arg}")
            opts["version"] = arg
            i += 1
            continue

    return opts


# ─── Generate release notes / リリースノート生成 ────────────────

def generate_notes(version: str, prev_tag: str, first_release: bool) -> str:
    features, fixes, docs, other = [], [], [], []

    if first_release:
        log_lines = git_output(["log", "HEAD", "--oneline", "--no-merges"]).splitlines()
    else:
        log_lines = git_output(["log", f"{prev_tag}..HEAD", "--oneline", "--no-merges"]).splitlines()

    for line in log_lines:
        hash_, _, msg = line.partition(" ")
        entry = f"- {msg} ({hash_})"

        if re.search(r"(README|docs|Docs|CLAUDE\.md|GEMINI\.md|documentation)", msg):
            docs.append(entry)
        elif re.match(r"(Fix|Resolve|Correct)", msg):
            fixes.append(entry)
        elif re.match(r"(Add|Implement|Support|Enable)", msg):
            features.append(entry)
        else:
            other.append(entry)

    out = ["## What's Changed", ""]

    if features:
        out.append("### Features")
        out.extend(features)
        out.append("")

    if fixes:
        out.append("### Fixes")
        out.extend(fixes)
        out.append("")

    if docs:
        out.append("### Documentation")
        out.extend(docs)
        out.append("")

    if other:
        out.append("### Other")
        out.extend(other)
        out.append("")

    web_url = get_github_web_url()
    if web_url:
        if first_release:
            out.append(f"**Full Changelog**: {web_url}/commits/{version}")
        else:
            out.append(f"**Full Changelog**: {web_url}/compare/{prev_tag}...{version}")

    return "\n".join(out).rstrip("\n")


# ─── Mode: --prev / 直近リリース表示モード ───────────────────────

def show_prev_release(msgs: dict) -> None:
    print()

    if shutil.which("gh"):
        result = subprocess.run(
            ["gh", "release", "view", "--json", "tagName,name,body"],
            capture_output=True, text=True,
        )
        latest = None
        if result.returncode == 0 and result.stdout.strip():
            try:
                latest = json.loads(result.stdout)
            except json.JSONDecodeError:
                latest = None
        if latest:
            print(f"{BOLD}{msgs['LATEST_RELEASE']} {latest['tagName']} — {latest['name']}{NC}")
            print("──────────────────────────────────────")
            print()
            print(latest["body"])
            print()
            print("──────────────────────────────────────")
        else:
            warn(msgs["NO_RELEASES"])
    elif shutil.which("curl"):
        gh_repo = get_github_repo()
        if gh_repo:
            result = subprocess.run(
                ["curl", "-s", f"https://api.github.com/repos/{gh_repo}/releases"],
                capture_output=True, text=True,
            )
            releases = None
            if result.returncode == 0 and result.stdout.strip():
                try:
                    releases = json.loads(result.stdout)
                except json.JSONDecodeError:
                    releases = None
            latest = releases[0] if isinstance(releases, list) and releases else None
            if latest:
                print(f"{BOLD}{msgs['LATEST_RELEASE']} {latest['tag_name']} — {latest['name']}{NC}")
                print("──────────────────────────────────────")
                print()
                print(latest["body"])
                print()
                print("──────────────────────────────────────")
            else:
                warn(msgs["NO_RELEASES"])
        else:
            die(msgs["NO_REPO"])
    else:
        warn(msgs["REQUIRES_GH"])
        web_url = get_github_web_url()
        if web_url:
            print()
            print(f"  {msgs['PREV_MANUAL_HINT']}")
            print(f"  {CYAN}{web_url}/releases{NC}")
        print()
        sys.exit(1)

    print()
    sys.exit(0)


# ─── Publish support / リリース実行の補助 ────────────────────────

def show_manual_release_url(msgs: dict, version: str, notes_file: str) -> None:
    web_url = get_github_web_url()

    info(msgs["MANUAL_RELEASE"])
    print()
    print(f"  {CYAN}{web_url}/releases/new?tag={version}{NC}")
    print()
    print(f"  {msgs['PASTE_NOTES']} {notes_file}")


# ─── Main / メイン ────────────────────────────────────────────

def main() -> None:
    lang_ja = is_lang_ja()
    msgs = get_messages(lang_ja)
    opts = parse_args(sys.argv[1:])

    if opts["repo"]:
        if not os.path.isdir(opts["repo"]):
            die(f"Repository directory not found: {opts['repo']}")
        # Resolve NOTES_FILE to an absolute path before chdir: a relative path
        # would otherwise resolve inside REPO after chdir, not in the caller's
        # working directory.
        # chdir前にNOTES_FILEを絶対パスへ解決しておく: そうしないと相対パスは
        # chdir後、呼び出し元のカレントディレクトリではなくREPO基準で解決されてしまう。
        if opts["notes_file"] and not os.path.isabs(opts["notes_file"]):
            opts["notes_file"] = os.path.abspath(opts["notes_file"])
        os.chdir(opts["repo"])

    if opts["show_prev"]:
        show_prev_release(msgs)
        return

    if not opts["version"]:
        die(msgs["VERSION_REQUIRED"])

    print()
    print(f"{BOLD}{msgs['RELEASE_TITLE']} {opts['version']}{NC}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print()

    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", opts["version"]):
        die(f"{msgs['VERSION_FORMAT']} {opts['version']}")

    branch = git_output(["branch", "--show-current"]).strip()
    if branch != "main":
        die(f"{msgs['NOT_MAIN']} {branch}")

    if opts["notes_file"]:
        status_result = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True)
        if status_result.stdout.strip():
            die(msgs["NOT_CLEAN"])

    if opts["notes_file"]:
        if not os.path.isfile(opts["notes_file"]):
            die(f"{msgs['NOTES_NOT_FOUND']} {opts['notes_file']}")
        if os.path.getsize(opts["notes_file"]) == 0:
            die(f"{msgs['NOTES_EMPTY']} {opts['notes_file']}")

    tag_check = subprocess.run(["git", "rev-parse", opts["version"]], capture_output=True, text=True)
    if tag_check.returncode == 0:
        die(msgs["TAG_EXISTS"] % opts["version"])

    prev_tag_result = subprocess.run(["git", "describe", "--tags", "--abbrev=0"], capture_output=True, text=True)
    prev_tag = prev_tag_result.stdout.strip() if prev_tag_result.returncode == 0 else ""
    first_release = prev_tag == ""

    ok(msgs["PREFLIGHT"])
    if first_release:
        print(f"  {DIM}Branch: {branch} | Previous: (none — first release) | Target: {opts['version']}{NC}")
    else:
        print(f"  {DIM}Branch: {branch} | Previous: {prev_tag} | Target: {opts['version']}{NC}")
    print()

    if opts["notes_file"]:
        if not shutil.which("gh"):
            warn(msgs["GH_NOT_FOUND_PREFLIGHT"])
            print()
        else:
            auth_result = subprocess.run(["gh", "auth", "status"], capture_output=True)
            if auth_result.returncode != 0:
                warn(msgs["GH_NOT_AUTHENTICATED"])
                print()

    if not first_release and not git_output(["log", f"{prev_tag}..HEAD", "--oneline", "--no-merges"]).strip():
        die(msgs["NO_COMMITS"] % prev_tag)

    notes = generate_notes(opts["version"], prev_tag, first_release)

    if not opts["notes_file"]:
        print(f"{BOLD}{msgs['DRAFT_TITLE']}{NC}")
        print("──────────────────────────────────────")
        print()
        print(notes)
        print()
        print("──────────────────────────────────────")

        draft_file = "ReleaseNotes-draft.md"
        with open(draft_file, "w") as f:
            f.write(notes + "\n")

        print()
        ok(f"{draft_file} {msgs['WROTE']}")
        warn(msgs["CONSOLIDATE_HINT"])
        print()
        repo_flag = f" --repo {os.getcwd()}" if opts["repo"] else ""

        draft_file_hint = os.path.join(os.getcwd(), draft_file) if opts["repo"] else draft_file

        print(f"  {BOLD}{msgs['NEXT_STEPS']}{NC}")
        print(f"    {msgs['STEP1']}")
        print(f"      {CYAN}.sandbox/scripts/github-release.py --prev{repo_flag}{NC}")
        print(f"    {msgs['STEP2']}")
        print(f"    {msgs['STEP3']}")
        print(f"      {CYAN}.sandbox/scripts/github-release.py {opts['version']} --notes-file {draft_file_hint}{repo_flag}{NC}")
        print()
        return

    # ─── Publish mode (--notes-file) / リリース実行モード ───────────

    with open(opts["notes_file"]) as f:
        # rstrip: mirrors bash's `NOTES=$(cat "$NOTES_FILE")`, where command
        # substitution strips all trailing newlines from the file's content.
        # rstrip: bashの `NOTES=$(cat "$NOTES_FILE")` はコマンド置換により
        # ファイル内容の末尾の改行をすべて取り除く、という挙動を再現している。
        notes = f.read().rstrip("\n")

    print(f"{BOLD}{msgs['NOTES_TITLE']}{NC}")
    print("──────────────────────────────────────")
    print()
    print(notes)
    print()
    print("──────────────────────────────────────")

    print()
    confirm_msg = msgs["CONFIRM_TAG"] % opts["version"]
    try:
        confirm = input(f"{YELLOW}{confirm_msg} [y/N]: {NC}")
    except EOFError:
        # Closed/non-interactive stdin: treat as "no" instead of crashing right
        # after the notes were printed.
        # 非対話的でstdinが閉じている場合は「no」として扱う（ノート表示直後に
        # クラッシュさせない）。
        confirm = ""
    if confirm not in ("y", "Y"):
        info(msgs["CANCELLED"])
        return

    subprocess.run(["git", "tag", "-a", opts["version"], "-m", notes])
    ok(msgs["TAG_CREATED"] % opts["version"])

    subprocess.run(["git", "push", "origin", opts["version"]])
    ok(msgs["TAG_PUSHED"] % opts["version"])

    print()

    if shutil.which("gh"):
        create_result = subprocess.run(
            ["gh", "release", "create", opts["version"], "--title", opts["version"], "--notes-file", opts["notes_file"]]
        )
        if create_result.returncode == 0:
            ok(msgs["GH_CREATED"])
            print()
            url_result = subprocess.run(
                ["gh", "release", "view", opts["version"], "--json", "url", "-q", ".url"],
                capture_output=True, text=True,
            )
            release_url = url_result.stdout.strip() if url_result.returncode == 0 else ""
            if release_url:
                print(f"  {CYAN}{release_url}{NC}")
        else:
            warn(msgs["GH_FAILED"])
            print()
            show_manual_release_url(msgs, opts["version"], opts["notes_file"])
    else:
        info(msgs["GH_NOT_FOUND"])
        show_manual_release_url(msgs, opts["version"], opts["notes_file"])

    print()
    ok(msgs["RELEASE_COMPLETE"] % opts["version"])
    print()


if __name__ == "__main__":
    main()

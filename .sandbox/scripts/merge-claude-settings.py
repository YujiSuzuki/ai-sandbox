#!/usr/bin/env python3
# merge-claude-settings.py
# Merge .claude/settings.json from subprojects into workspace root
#
# Merge logic (4 cases):
#   1) No workspace settings -> Create by merging all subproject permissions
#   2) Settings exist, no changes -> Re-merge from subprojects and update backup
#   3) Settings exist with manual changes -> Disable auto-merge, preserve manual edits
#   4) Settings exist without backup -> Assume manual creation, skip merge
#
# Two intentional deviations from the bash original:
# - jq is no longer required. The bash original's merge_permissions() shelled
#   out to jq for every JSON read/merge/write; this port uses Python's
#   stdlib json module for the same operations, so the "jq missing -> warn
#   and skip" branch is gone entirely (matches the precedent set by
#   triage-undeclared-secrets.py's own jq removal).
# - Case 2's re-merge FIXES a bash bug rather than preserving it: jq's `*`
#   operator only overwrote permissions keys that the freshly recomputed
#   merge actually produced (non-empty "deny"/"allow"), so a key that went
#   from populated to empty across a re-merge was never deleted -- it stuck
#   at its last non-empty value until some future merge happened to
#   overwrite it with something non-empty again. _merge_onto() below
#   explicitly clears a key that the fresh recompute no longer produces,
#   instead of leaving it untouched.
#
# Also note: this script resolves ITS OWN workspace root via $WORKSPACE_ROOT
# (matching the bash original), which is a different env var from the
# $WORKSPACE that _python_common.py's load_startup_config() reads for
# startup.conf/STARTUP_VERBOSITY. That split exists in the bash original too
# (_startup_common.sh hardcodes $WORKSPACE for its own config path,
# independent of this script's $WORKSPACE_ROOT) and is preserved as-is.
# ---
# サブプロジェクトの .claude/settings.json を workspace 直下にマージ
#
# マージロジック（4パターン）:
#   1) workspace の設定なし -> 全サブプロジェクトの permissions をマージして作成
#   2) 設定あり、変更なし -> サブプロジェクトから再マージしてバックアップ更新
#   3) 設定あり、手動変更あり -> 自動マージを無効化し、手動編集を保護
#   4) 設定あり、バックアップなし -> 手動作成とみなしマージをスキップ
#
# bash版からの意図的な差分が2つある:
# - jq が不要になった。bash版の merge_permissions() はJSONの読み込み・マージ・
#   書き込みのたびに jq を呼んでいたが、この移植ではPython標準ライブラリの
#   json モジュールで同じ処理を行うため、「jq が無ければ警告してスキップ」の
#   分岐は丸ごと無くなっている（triage-undeclared-secrets.py で既に行った
#   jq依存の除去と同じ方針）。
# - ケース2の再マージは、bashのバグをそのまま再現せず修正している: jqの `*`
#   演算子は、新たに計算し直したマージ結果に実際に含まれるキー（空でない
#   "deny"/"allow"）だけを上書きしていたため、あるキーが「値あり」から「空」に
#   変わっても削除されず、次に空でない値で上書きされるまで最後の値のまま
#   残り続けていた。下記の _merge_onto() は、新たな計算結果に含まれなくなった
#   キーを明示的に削除するようにしている。
#
# なお、このスクリプト自身のworkspace rootは $WORKSPACE_ROOT で解決する
# （bash版と同じ）。これは _python_common.py の load_startup_config() が
# startup.conf/STARTUP_VERBOSITY のために読む $WORKSPACE とは別の環境変数
# である。この使い分けはbash版にも元々存在し（_startup_common.sh は
# このスクリプトの $WORKSPACE_ROOT とは独立に、自身の設定パスを常に
# $WORKSPACE で決めている）、そのまま維持している。

import json
import os
import shutil
import sys
from pathlib import Path

from _python_common import is_quiet, is_verbose, load_startup_config, print_default, print_detail, print_warning

_PRUNE_DIR_NAMES = {
    "node_modules", ".git", "vendor", "Pods", "dist", "build",
    ".build", "DerivedData", "Carthage", ".venv", "__pycache__",
}
_MAX_DEPTH = 8


def _workspace_root() -> Path:
    return Path(os.environ.get("WORKSPACE_ROOT", "/workspace"))


def get_messages(lang_ja: bool) -> dict:
    if lang_ja:
        return {
            "NO_SETTINGS": "workspace の .claude/settings.json が見つかりません。",
            "NO_PROJECT": "マージするプロジェクト設定がありません。",
            "CREATED": "プロジェクトの permissions をマージして workspace 設定を作成しました。",
            "BACKUP": "  バックアップ保存先:",
            "NO_BACKUP": "workspace の .claude/settings.json がバックアップなしで存在します。",
            "SKIP_MERGE": "手動作成とみなし、マージをスキップします。",
            "REMERGED": "プロジェクトの permissions を再マージしました（手動変更なし）。",
            "CHANGES_DETECTED": "workspace の .claude/settings.json に手動変更が検出されました",
            "FOUND_IN": "以下のプロジェクトに設定があります：",
            "MERGE_MANUALLY": "必要に応じて手動でマージしてください。",
            "PRESERVED": "手動変更を保護するため、自動マージを無効にしました。",
            "REENABLE": "自動マージを再開するには: {path} を削除してコンテナを再起動してください。",
        }
    return {
        "NO_SETTINGS": "No workspace .claude/settings.json found.",
        "NO_PROJECT": "No project settings to merge.",
        "CREATED": "Created workspace settings by merging project permissions.",
        "BACKUP": "  Backup saved to:",
        "NO_BACKUP": "Workspace .claude/settings.json exists without backup.",
        "SKIP_MERGE": "Assuming manually created. Skipping merge.",
        "REMERGED": "Re-merged project permissions (no manual changes detected).",
        "CHANGES_DETECTED": "Manual changes detected in workspace .claude/settings.json",
        "FOUND_IN": "Project settings found in:",
        "MERGE_MANUALLY": "Please merge manually if needed.",
        "PRESERVED": "Your manual changes are preserved. Auto-merge has been disabled to avoid overwriting them.",
        "REENABLE": "To re-enable auto-merge: delete {path} and restart the container.",
    }


GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
NC = "\033[0m"


def find_project_settings(workspace_root: Path) -> list:
    """Finds every subproject .claude/settings.json under workspace_root, up
    to maxdepth 8 (matches a template checked out under a subdirectory with
    projects added/migrated into it afterwards, e.g.
    <workspace>/mainte/ai-sandbox-demo/demo-apps-ios/.claude/settings.json
    at depth 5), pruning known heavy/irrelevant directories, excluding the
    workspace root's own settings.json.

    ワークスペース直下のサブプロジェクトの .claude/settings.json を
    maxdepth 8まで検索する（テンプレートがサブディレクトリ配下にあり、
    後からプロジェクトを追加/移行する構成 -- 例:
    <workspace>/mainte/ai-sandbox-demo/demo-apps-ios/.claude/settings.json
    は深さ5 -- に対応できる余裕を持たせている）。既知の重い/無関係な
    ディレクトリはプルーンし、workspace自身の settings.json は除外する。
    """
    workspace_settings = workspace_root / ".claude" / "settings.json"
    results = []

    for dirpath, dirnames, filenames in os.walk(workspace_root):
        rel = Path(dirpath).relative_to(workspace_root)
        depth = 0 if rel == Path(".") else len(rel.parts)

        dirnames[:] = sorted(d for d in dirnames if d not in _PRUNE_DIR_NAMES)
        if depth >= _MAX_DEPTH:
            dirnames[:] = []

        if Path(dirpath).name == ".claude" and "settings.json" in filenames and depth + 1 <= _MAX_DEPTH:
            candidate = Path(dirpath) / "settings.json"
            if candidate != workspace_settings:
                results.append(candidate)

    return sorted(results, key=str)


def merge_permissions(workspace_root: Path):
    """Scans every subproject settings.json and returns the merged
    permissions dict (only "deny"/"allow" keys present when non-empty,
    values sorted+deduplicated to match jq's `unique`), or None if there's
    nothing to merge (no project settings found, or none had any usable
    permissions).

    全サブプロジェクトの settings.json を走査し、マージ済みpermissions辞書
    （"deny"/"allow" は非空の場合のみ含む。値はjqの`unique`に合わせて
    ソート+重複排除）を返す。マージ対象が無ければ（プロジェクト設定が
    見つからない、またはどれも使えるpermissionsを持たない）None を返す。
    """
    project_settings = find_project_settings(workspace_root)
    if not project_settings:
        return None

    deny = set()
    allow = set()
    for settings_file in project_settings:
        try:
            data = json.loads(settings_file.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        perms = data.get("permissions") if isinstance(data, dict) else None
        if not isinstance(perms, dict) or not perms:
            continue
        new_deny = perms.get("deny")
        if isinstance(new_deny, list):
            deny.update(str(item) for item in new_deny)
        new_allow = perms.get("allow")
        if isinstance(new_allow, list):
            allow.update(str(item) for item in new_allow)

    permissions = {}
    if deny:
        permissions["deny"] = sorted(deny)
    if allow:
        permissions["allow"] = sorted(allow)

    return permissions if permissions else None


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def _merge_onto(existing_permissions: dict, new_permissions: dict) -> dict:
    """Replaces the "deny"/"allow" leaves with the freshly recomputed
    values. new_permissions only contains a "deny"/"allow" key when
    merge_permissions() found at least one non-empty pattern for it this
    round (it always performs a full scan, so a missing key here is a
    reliable signal that the recomputed value is empty) -- so a key present
    in existing_permissions but absent from new_permissions is explicitly
    cleared, not left stuck at its previous value. Any other key already in
    existing_permissions passes through untouched.

    "deny"/"allow" の葉を、新たに計算し直した値で置き換える。new_permissions
    に "deny"/"allow" キーが存在するのは、merge_permissions() が今回のスキャンで
    非空のパターンを1つ以上見つけた場合のみ（毎回必ずフルスキャンするため、
    キーが無いことは「今回の再計算結果が空である」ことの確実なシグナルになる）。
    そのため existing_permissions にあって new_permissions に無いキーは、
    以前の値のまま残さず明示的に削除する。それ以外のキーはそのまま通す。
    """
    merged = dict(existing_permissions)
    for key in ("deny", "allow"):
        if key in new_permissions:
            merged[key] = new_permissions[key]
        else:
            merged.pop(key, None)
    return merged


def main() -> None:
    lang_ja = os.environ.get("LANG", "").startswith("ja_JP") or os.environ.get("LC_ALL", "").startswith("ja_JP")
    msgs = get_messages(lang_ja)

    config = load_startup_config()
    verbosity = config["verbosity"]

    workspace_root = _workspace_root()
    workspace_settings = workspace_root / ".claude" / "settings.json"
    home = os.environ.get("HOME") or str(Path.home())
    backup_file_path = Path(home) / ".claude-settings-backup.json"

    if not workspace_settings.is_file():
        # Case 1: No workspace settings - create by merging
        print_detail(msgs["NO_SETTINGS"], verbosity)

        merged_permissions = merge_permissions(workspace_root)
        if merged_permissions is None:
            print_detail(msgs["NO_PROJECT"], verbosity)
            sys.exit(0)

        _write_json(workspace_settings, {"permissions": merged_permissions})
        shutil.copy(workspace_settings, backup_file_path)

        source_count = len(find_project_settings(workspace_root))
        if is_verbose(verbosity):
            print(f"{GREEN}{msgs['CREATED']}{NC}")
            print(f"{msgs['BACKUP']} {backup_file_path}")
        else:
            print_default(f"✓ Claude settings: created ({source_count} sources)", verbosity)
        sys.exit(0)

    # Workspace settings exists
    if not backup_file_path.is_file():
        # Case 4: Settings exist but no backup - assume manually created
        if is_verbose(verbosity):
            print(f"{YELLOW}{msgs['NO_BACKUP']}{NC}")
            print(f"{YELLOW}{msgs['SKIP_MERGE']}{NC}")
        else:
            print_default("✓ Claude settings: manual (skip merge)", verbosity)
        sys.exit(0)

    # Both workspace settings and backup exist - check for changes.
    # Only the .permissions subtree is compared: this script owns permissions
    # merging exclusively, so other top-level keys (e.g. hooks added by other
    # startup steps) must never trigger a false "manual changes" detection.
    # .permissionsサブツリーのみを比較する: このスクリプトはpermissionsのマージのみを
    # 担当するため、他のトップレベルキー（他の起動ステップが追加するhooksなど）が
    # 誤って「手動変更」と判定されてはならない。
    try:
        workspace_data = json.loads(workspace_settings.read_text())
        backup_data = json.loads(backup_file_path.read_text())
        unchanged = workspace_data.get("permissions") == backup_data.get("permissions")
    except (OSError, json.JSONDecodeError):
        unchanged = False
        workspace_data = None

    if unchanged:
        # Case 2: No permissions changes - re-merge and update backup
        merged_permissions = merge_permissions(workspace_root)
        if merged_permissions is None:
            sys.exit(0)

        # Merge onto the existing file, preserving any other top-level keys
        # already present while overwriting .permissions with the freshly
        # recomputed set (a key the recompute no longer produces is cleared,
        # not left stuck -- see _merge_onto()'s docstring).
        # 既存ファイルにマージする。他のトップレベルキーは保持しつつ、
        # .permissionsだけを最新の値で上書きする（再計算結果に含まれなくなった
        # キーは、残さず削除される -- 詳細は _merge_onto() のdocstringを参照）。
        existing_permissions = workspace_data.get("permissions") if isinstance(workspace_data.get("permissions"), dict) else {}
        workspace_data["permissions"] = _merge_onto(existing_permissions, merged_permissions)
        _write_json(workspace_settings, workspace_data)
        shutil.copy(workspace_settings, backup_file_path)

        source_count = len(find_project_settings(workspace_root))
        if is_verbose(verbosity):
            print(f"{GREEN}{msgs['REMERGED']}{NC}")
        else:
            print_default(f"✓ Claude settings: merged ({source_count} sources)", verbosity)
    else:
        # Case 3: Changes detected - don't merge, prompt manual merge
        # Remove backup to disable auto-merge (protect manual changes)
        backup_file_path.unlink(missing_ok=True)

        reenable = msgs["REENABLE"].format(path=workspace_settings)

        separator = "═" * 63
        if is_verbose(verbosity):
            print(f"{YELLOW}{separator}{NC}")
            print(f"{YELLOW}{msgs['CHANGES_DETECTED']}{NC}")
            print(f"{YELLOW}{separator}{NC}")
            print()
            print(msgs["FOUND_IN"])
            for f in find_project_settings(workspace_root):
                print(f"  - {f}")
            print()
            print(f"{YELLOW}{msgs['MERGE_MANUALLY']}{NC}")
            print()
            print(msgs["PRESERVED"])
            print(reenable)
        elif is_quiet(verbosity):
            print_warning(f"Claude settings: {msgs['CHANGES_DETECTED']}")
            print(f"   {msgs['MERGE_MANUALLY']}")
        else:
            print()
            print_warning(msgs["CHANGES_DETECTED"])
            print()
            print(msgs["FOUND_IN"])
            for f in find_project_settings(workspace_root):
                print(f"  - {f}")
            print()
            print(msgs["MERGE_MANUALLY"])
            print()
            print(msgs["PRESERVED"])
            print(reenable)
            print()


if __name__ == "__main__":
    main()

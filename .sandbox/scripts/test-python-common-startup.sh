#!/bin/bash
# test-python-common-startup.sh
# Test script for the _startup_common.sh-derived functions in
# _python_common.py: load_startup_config, is_quiet/is_verbose/is_summary,
# print_title/print_footer/print_default/print_detail/print_warning/print_error,
# load_sync_ignore_patterns/matches_sync_ignore/add_sync_ignore_pattern,
# backup_file/cleanup_backups, and the update-check helpers (debug_log,
# read_state_timestamp, get_last_notified_version, is_first_run,
# should_check, update_state, build_api_url, extract_tag_from_json,
# fetch_latest_release).
#
# _python_common.py に移植した _startup_common.sh 由来の関数
# （load_startup_config、is_quiet/is_verbose/is_summary、
# print_title/print_footer/print_default/print_detail/print_warning/print_error、
# load_sync_ignore_patterns/matches_sync_ignore/add_sync_ignore_pattern、
# backup_file/cleanup_backups、および更新チェックヘルパー一式
# debug_log/read_state_timestamp/get_last_notified_version/is_first_run/
# should_check/update_state/build_api_url/extract_tag_from_json/
# fetch_latest_release）のテストスクリプト。
#
# Usage: ./test-python-common-startup.sh
# 使用方法: ./test-python-common-startup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/_python_common.py"

if [ ! -f "$LIB" ]; then
    echo "❌ Library not found: $LIB"
    exit 1
fi

# The actual assertions run inside Python (these are Python functions with
# file-system side effects, not something bash [[ =~ ]] can exercise), but
# this stays a test-*.sh file so run-all-tests.sh's glob discovers and runs
# it like every other test here.
# 実際のアサーションはPython側で行う（ファイルシステムに副作用を持つPython
# 関数であり、bashの[[ =~ ]]で検証できるものではない）。ただしファイル自体は
# test-*.sh のままにしてあり、run-all-tests.sh のglobが他のテストと同様に
# 発見・実行できるようにしている。
PYTHONPATH="$SCRIPT_DIR" python3 - <<'PYEOF'
import io
import json
import os
import shutil
import sys
import tempfile
import time
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from _python_common import (
    add_sync_ignore_pattern,
    backup_file,
    build_api_url,
    cleanup_backups,
    debug_log,
    extract_tag_from_json,
    fetch_latest_release,
    get_last_notified_version,
    is_first_run,
    is_quiet,
    is_summary,
    is_verbose,
    load_startup_config,
    load_sync_ignore_patterns,
    matches_sync_ignore,
    parse_simple_conf,
    print_default,
    print_detail,
    print_error,
    print_footer,
    print_title,
    print_warning,
    read_state_timestamp,
    should_check,
    update_state,
)

RED = "\033[0;31m"
GREEN = "\033[0;32m"
NC = "\033[0m"

passed = 0
failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"{GREEN}✅ {msg}{NC}")


def bad(msg):
    global failed
    failed += 1
    print(f"{RED}❌ {msg}{NC}")


class TempWorkspace:
    """Isolates WORKSPACE-relative reads/writes (config, sync-ignore,
    backups) per test, mirroring how the bash-vs-python comparison during
    development used a fresh $WORKSPACE per case.

    テストごとにWORKSPACE相対の読み書き（config、sync-ignore、backups）を
    分離する。開発時のbash-vs-python比較で毎回新しい$WORKSPACEを使ったのと
    同じ考え方。
    """

    def __enter__(self):
        self.dir = tempfile.mkdtemp()
        self._prev = os.environ.get("WORKSPACE")
        os.environ["WORKSPACE"] = self.dir
        return self.dir

    def __exit__(self, *exc):
        if self._prev is None:
            os.environ.pop("WORKSPACE", None)
        else:
            os.environ["WORKSPACE"] = self._prev
        shutil.rmtree(self.dir, ignore_errors=True)


print()
print("=" * 62)
print("  _python_common.py startup-helpers Test Suite")
print("=" * 62)

# Test 1: load_startup_config defaults when no config file exists
print()
print("=== Test: load_startup_config defaults when no config file exists ===")
with TempWorkspace():
    cfg = load_startup_config()
    if (cfg["readme_url"], cfg["readme_url_ja"], cfg["verbosity"], cfg["backup_keep_count"]) == (
        "README.md", "README.ja.md", "verbose", "0",
    ):
        ok("Defaults match bash's fallback values")
    else:
        bad(f"Unexpected defaults: {cfg}")

# Test 2: load_startup_config reads config file values
print()
print("=== Test: load_startup_config reads config file values ===")
with TempWorkspace() as ws:
    config_dir = os.path.join(ws, ".sandbox", "config")
    os.makedirs(config_dir)
    with open(os.path.join(config_dir, "startup.conf"), "w") as f:
        f.write('README_URL="CUSTOM.md"\nSTARTUP_VERBOSITY="summary"\nBACKUP_KEEP_COUNT=5\n')
    cfg = load_startup_config()
    if cfg["readme_url"] == "CUSTOM.md" and cfg["verbosity"] == "summary" and cfg["backup_keep_count"] == "5":
        ok("Config file values are read correctly")
    else:
        bad(f"Config file values not applied: {cfg}")

# Test 3: environment variable overrides config file
print()
print("=== Test: environment variable overrides config file ===")
with TempWorkspace() as ws:
    config_dir = os.path.join(ws, ".sandbox", "config")
    os.makedirs(config_dir)
    with open(os.path.join(config_dir, "startup.conf"), "w") as f:
        f.write('STARTUP_VERBOSITY="verbose"\n')
    os.environ["STARTUP_VERBOSITY"] = "quiet"
    try:
        cfg = load_startup_config()
        if cfg["verbosity"] == "quiet":
            ok("STARTUP_VERBOSITY env var wins over the config file's value")
        else:
            bad(f"Expected env var to win, got verbosity={cfg['verbosity']!r}")
    finally:
        del os.environ["STARTUP_VERBOSITY"]

# Test 4: is_quiet/is_verbose/is_summary classify each level correctly
print()
print("=== Test: is_quiet/is_verbose/is_summary classify each level correctly ===")
checks = [
    ("quiet", is_quiet, True), ("quiet", is_verbose, False), ("quiet", is_summary, False),
    ("verbose", is_quiet, False), ("verbose", is_verbose, True), ("verbose", is_summary, False),
    ("summary", is_quiet, False), ("summary", is_verbose, False), ("summary", is_summary, True),
]
if all(fn(level) == expected for level, fn, expected in checks):
    ok("All 9 level/function combinations classify correctly")
else:
    bad("At least one verbosity classification is wrong")

# Test 5: print_title suppressed in quiet, includes trailing blank line only in verbose
print()
print("=== Test: print_title respects verbosity (quiet suppresses, verbose adds trailing blank) ===")
buf = io.StringIO()
with redirect_stdout(buf):
    print_title("Hello", "quiet")
quiet_out = buf.getvalue()
buf = io.StringIO()
with redirect_stdout(buf):
    print_title("Hello", "verbose")
verbose_out = buf.getvalue()
buf = io.StringIO()
with redirect_stdout(buf):
    print_title("Hello", "summary")
summary_out = buf.getvalue()
if quiet_out == "" and verbose_out.endswith("\n\n") and not summary_out.endswith("\n\n") and "Hello" in verbose_out:
    ok("print_title verbosity behavior matches bash (quiet=silent, verbose=trailing blank, summary=no trailing blank)")
else:
    bad(f"print_title mismatch: quiet={quiet_out!r} verbose={verbose_out!r} summary={summary_out!r}")

# Test 6: print_footer suppressed in quiet
print()
print("=== Test: print_footer suppressed in quiet, printed otherwise ===")
buf = io.StringIO()
with redirect_stdout(buf):
    print_footer("quiet")
quiet_out = buf.getvalue()
buf = io.StringIO()
with redirect_stdout(buf):
    print_footer("summary")
summary_out = buf.getvalue()
if quiet_out == "" and summary_out != "":
    ok("print_footer suppressed only in quiet mode")
else:
    bad(f"print_footer mismatch: quiet={quiet_out!r} summary={summary_out!r}")

# Test 7: print_default suppressed in quiet, printed otherwise
print()
print("=== Test: print_default suppressed in quiet, printed otherwise ===")
buf = io.StringIO()
with redirect_stdout(buf):
    print_default("body text", "quiet")
quiet_out = buf.getvalue()
buf = io.StringIO()
with redirect_stdout(buf):
    print_default("body text", "verbose")
verbose_out = buf.getvalue()
if quiet_out == "" and verbose_out == "body text\n":
    ok("print_default suppressed only in quiet mode")
else:
    bad(f"print_default mismatch: quiet={quiet_out!r} verbose={verbose_out!r}")

# Test 7b: print_detail printed only in verbose, not quiet/summary/default
print()
print("=== Test: print_detail printed only in verbose ===")
outs = {}
for v in ("quiet", "summary", "default", "verbose"):
    buf = io.StringIO()
    with redirect_stdout(buf):
        print_detail("extra detail", v)
    outs[v] = buf.getvalue()
if outs["quiet"] == "" and outs["summary"] == "" and outs["default"] == "" and outs["verbose"] == "extra detail\n":
    ok("print_detail printed only in verbose mode")
else:
    bad(f"print_detail mismatch: {outs!r}")

# Test 7c: print_warning always prints, with the emoji prefix, regardless of verbosity
print()
print("=== Test: print_warning always prints with emoji prefix ===")
buf = io.StringIO()
with redirect_stdout(buf):
    print_warning("careful")
warn_out = buf.getvalue()
if warn_out == "⚠️  careful\n":
    ok("print_warning writes the expected message")
else:
    bad(f"print_warning mismatch: {warn_out!r}")

# Test 8: print_error always prints, to stderr, regardless of verbosity
print()
print("=== Test: print_error always prints to stderr regardless of verbosity ===")
buf = io.StringIO()
with redirect_stderr(buf):
    print_error("boom")
err_out = buf.getvalue()
if err_out == "❌ boom\n":
    ok("print_error writes the expected message to stderr")
else:
    bad(f"print_error mismatch: {err_out!r}")

# Test 9: load_sync_ignore_patterns excludes comments and blank lines
print()
print("=== Test: load_sync_ignore_patterns excludes comments and blank lines ===")
with TempWorkspace() as ws:
    config_dir = os.path.join(ws, ".sandbox", "config")
    os.makedirs(config_dir)
    with open(os.path.join(config_dir, "sync-ignore"), "w") as f:
        f.write("# a comment\napi/.env.example\n\n   \n**/*.sample\n")
    patterns = load_sync_ignore_patterns()
    if patterns == ["api/.env.example", "**/*.sample"]:
        ok(f"Comments/blanks excluded: {patterns}")
    else:
        bad(f"Unexpected patterns: {patterns}")

# Test 9b: load_sync_ignore_patterns returns [] when the file doesn't exist
print()
print("=== Test: load_sync_ignore_patterns returns [] when the file is missing ===")
with TempWorkspace():
    if load_sync_ignore_patterns() == []:
        ok("Missing sync-ignore file yields an empty list, not an error")
    else:
        bad("Missing sync-ignore file should yield []")

# Test 10: matches_sync_ignore covers exact / **/<suffix> / <dir>/** / glob forms
print()
print("=== Test: matches_sync_ignore covers exact / **/suffix / dir/** / glob pattern forms ===")
with TempWorkspace() as ws:
    config_dir = os.path.join(ws, ".sandbox", "config")
    os.makedirs(config_dir)
    with open(os.path.join(config_dir, "sync-ignore"), "w") as f:
        f.write("api/.env.example\n**/*.sample\nsecrets/**\nmobile/config-*.yaml\n")

    cases = [
        (f"{ws}/api/.env.example", True),
        (f"{ws}/foo/bar.sample", True),
        (f"{ws}/secrets/deep/nested/file", True),
        (f"{ws}/mobile/config-prod.yaml", True),
        (f"{ws}/mobile/other.yaml", False),
        (f"{ws}/notignored.txt", False),
    ]
    results = {path: matches_sync_ignore(path) for path, _ in cases}
    if all(results[path] == expected for path, expected in cases):
        ok("All 6 matches_sync_ignore cases match the expected bash behavior")
    else:
        bad(f"Mismatch: {results}")

# Test 11: add_sync_ignore_pattern is idempotent
print()
print("=== Test: add_sync_ignore_pattern is idempotent ===")
with TempWorkspace() as ws:
    add_sync_ignore_pattern("new/pattern.txt")
    add_sync_ignore_pattern("new/pattern.txt")
    content = open(os.path.join(ws, ".sandbox", "config", "sync-ignore")).read()
    if content == "new/pattern.txt\n":
        ok("Second call did not duplicate the line")
    else:
        bad(f"Expected a single line, got: {content!r}")

# Test 12: backup_file names and copies correctly
print()
print("=== Test: backup_file creates a correctly-named copy ===")
with TempWorkspace() as ws:
    target = os.path.join(ws, "target.yml")
    with open(target, "w") as f:
        f.write("content")
    backup_path = backup_file(target, "mylabel")
    basename = os.path.basename(backup_path)
    if (
        basename.startswith("mylabel.target.yml.")
        and basename[len("mylabel.target.yml."):].isdigit()
        and open(backup_path).read() == "content"
    ):
        ok(f"Backup created with expected naming and content: {basename}")
    else:
        bad(f"Unexpected backup path: {backup_path}")

# Test 13: cleanup_backups keeps only the N most recent
print()
print("=== Test: cleanup_backups keeps only the N most recent ===")
with TempWorkspace() as ws:
    target = os.path.join(ws, "target.yml")
    with open(target, "w") as f:
        f.write("content")
    backup_dir = os.path.join(ws, ".sandbox", "backups")
    os.makedirs(backup_dir, exist_ok=True)
    # Write backups directly with explicit, strictly increasing mtimes
    # instead of sleeping between real backup_file() calls, so this test
    # doesn't need multi-second wall-clock delays to get a deterministic order.
    # 実際に backup_file() を呼んで数秒スリープする代わりに、明示的に単調増加
    # するmtimeでバックアップを直接書き込み、決定的な順序を壁時計時間の
    # 待機なしで得る。
    paths = []
    for i in range(4):
        p = os.path.join(backup_dir, f"label.target.yml.{i:020d}")
        with open(p, "w") as f:
            f.write("x")
        os.utime(p, (i, i))
        paths.append(p)
    cleanup_backups("label.target.yml.*", 2)
    remaining = sorted(os.listdir(backup_dir))
    if remaining == [os.path.basename(paths[2]), os.path.basename(paths[3])]:
        ok(f"Only the 2 most recent backups remain: {remaining}")
    else:
        bad(f"Unexpected remaining backups: {remaining}")

# Test 13b: cleanup_backups with keep<=0 is a no-op (unlimited)
print()
print("=== Test: cleanup_backups with keep<=0 does not delete anything ===")
with TempWorkspace() as ws:
    backup_dir = os.path.join(ws, ".sandbox", "backups")
    os.makedirs(backup_dir, exist_ok=True)
    p = os.path.join(backup_dir, "label.target.yml.1")
    with open(p, "w") as f:
        f.write("x")
    cleanup_backups("label.target.yml.*", 0)
    if os.listdir(backup_dir) == ["label.target.yml.1"]:
        ok("keep=0 left the backup untouched (unlimited)")
    else:
        bad("keep=0 should not delete anything")

# Test 13c: parse_simple_conf parses KEY="value" lines, ignores comments/blanks
print()
print("=== Test: parse_simple_conf parses quoted/unquoted values, skips comments/blanks ===")
with TempWorkspace() as ws:
    conf_path = Path(ws) / "some.conf"
    conf_path.write_text('# a comment\nFOO="bar"\nBAZ=qux\n\nEMPTY=""\n')
    values = parse_simple_conf(conf_path)
    if values == {"FOO": "bar", "BAZ": "qux", "EMPTY": ""}:
        ok(f"parse_simple_conf parsed: {values}")
    else:
        bad(f"parse_simple_conf mismatch: {values}")

    if parse_simple_conf(Path(ws) / "missing.conf") == {}:
        ok("parse_simple_conf returns {} for a missing file")
    else:
        bad("parse_simple_conf should return {} for a missing file")

# ─── Update-check helpers ───────────────────────────────────

# Test 14: read_state_timestamp / get_last_notified_version / is_first_run
print()
print("=== Test: read_state_timestamp/get_last_notified_version/is_first_run ===")
with TempWorkspace() as ws:
    state_file = Path(ws) / "state"
    if is_first_run(state_file) and read_state_timestamp(state_file) == 0 and get_last_notified_version(state_file) == "":
        ok("Missing state file: is_first_run=True, timestamp=0, version=''")
    else:
        bad("Missing state file should yield first_run=True, timestamp=0, version=''")

    state_file.write_text("1738300000:v0.2.0\n")
    if (not is_first_run(state_file)) and read_state_timestamp(state_file) == 1738300000 and get_last_notified_version(state_file) == "v0.2.0":
        ok("Populated state file parsed correctly")
    else:
        bad(f"Unexpected parse: first_run={is_first_run(state_file)}, ts={read_state_timestamp(state_file)}, ver={get_last_notified_version(state_file)!r}")

    state_file.write_text("1738300000:v0.3.0-beta.1\n")
    if get_last_notified_version(state_file) == "v0.3.0-beta.1":
        ok("Pre-release suffix (extra dots/hyphens) preserved in version")
    else:
        bad(f"Pre-release suffix mishandled: {get_last_notified_version(state_file)!r}")

    state_file.write_text("not-a-number:v9.9.9\n")
    if read_state_timestamp(state_file) == 0:
        ok("Malformed timestamp falls back to 0 rather than raising")
    else:
        bad(f"Malformed timestamp should yield 0, got {read_state_timestamp(state_file)}")

# Test 15: update_state writes the "<timestamp>:<version>" format, readable back
print()
print("=== Test: update_state writes a format read_state_timestamp/get_last_notified_version can parse ===")
with TempWorkspace() as ws:
    state_file = Path(ws) / "nested" / "state"
    update_state(state_file, "v1.0.0")
    if get_last_notified_version(state_file) == "v1.0.0" and read_state_timestamp(state_file) > 0:
        ok("update_state wrote a version/timestamp pair round-tripping through the readers")
    else:
        bad(f"update_state round-trip failed: ts={read_state_timestamp(state_file)}, ver={get_last_notified_version(state_file)!r}")

# Test 16: should_check interval logic
print()
print("=== Test: should_check interval logic ===")
with TempWorkspace() as ws:
    state_file = Path(ws) / "state"
    if should_check(state_file, 24):
        ok("No state file -> should_check True regardless of interval")
    else:
        bad("No state file should always check")

    state_file.write_text(f"{int(time.time())}:v0.1.0\n")
    if should_check(state_file, 0):
        ok("interval=0 -> always check even with a fresh timestamp")
    else:
        bad("interval=0 should always check")

    if not should_check(state_file, 24):
        ok("Fresh timestamp + interval=24 -> should_check False")
    else:
        bad("Fresh timestamp should not need a check yet")

    state_file.write_text(f"{int(time.time()) - 100000}:v0.1.0\n")
    if should_check(state_file, 24):
        ok("Old timestamp (>24h elapsed) -> should_check True")
    else:
        bad("Old timestamp should trigger a check")

    state_file.write_text(f"{int(time.time())}:v0.1.0\n")
    if not should_check(state_file, "abc") and not should_check(state_file, ""):
        ok("Non-numeric/empty interval falls back to 24 (fresh timestamp -> no check)")
    else:
        bad("Invalid interval should fall back to 24, not always-check")

# Test 17: build_api_url per channel
print()
print("=== Test: build_api_url per channel ===")
cases = [
    ("all", "https://api.github.com/repos/owner/repo/releases?per_page=1"),
    ("stable", "https://api.github.com/repos/owner/repo/releases/latest"),
    ("unknown", "https://api.github.com/repos/owner/repo/releases?per_page=1"),
]
if all(build_api_url("owner/repo", channel) == expected for channel, expected in cases):
    ok("build_api_url returns the right endpoint for all/stable/unknown channels")
else:
    bad(f"build_api_url mismatch: {[build_api_url('owner/repo', c) for c, _ in cases]}")

# Test 18: extract_tag_from_json for both response shapes
print()
print("=== Test: extract_tag_from_json for array (all) and object (stable) responses ===")
array_resp = [{"tag_name": "v0.2.0-beta.1", "prerelease": True}]
object_resp = {"tag_name": "v1.0.0", "prerelease": False}
if (
    extract_tag_from_json(array_resp, "all") == "v0.2.0-beta.1"
    and extract_tag_from_json(object_resp, "stable") == "v1.0.0"
    and extract_tag_from_json([], "all") == ""
    and extract_tag_from_json({"name": "No Tag"}, "stable") == ""
):
    ok("extract_tag_from_json handles array/object/empty/missing-tag cases")
else:
    bad("extract_tag_from_json mismatch on one of the array/object/empty/missing cases")

# Test 19: debug_log only prints when enabled, always to stderr
print()
print("=== Test: debug_log only prints when enabled ===")
buf = io.StringIO()
with redirect_stderr(buf):
    debug_log("hello", False)
disabled_out = buf.getvalue()
buf = io.StringIO()
with redirect_stderr(buf):
    debug_log("hello", True)
enabled_out = buf.getvalue()
if disabled_out == "" and enabled_out == "[debug] hello\n":
    ok("debug_log silent when disabled, '[debug] ...' on stderr when enabled")
else:
    bad(f"debug_log mismatch: disabled={disabled_out!r} enabled={enabled_out!r}")

# Test 20: fetch_latest_release against a local HTTP server (success, non-200, unreachable)
print()
print("=== Test: fetch_latest_release (local HTTP server) ===")
import http.server
import socketserver
import threading


class _Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.endswith("/releases/latest"):
            body = json.dumps({"tag_name": "v9.9.9"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        elif "no-releases" in self.path:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"[]")
        else:
            self.send_response(404)
            self.end_headers()


with socketserver.TCPServer(("127.0.0.1", 0), _Handler) as httpd:
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        import unittest.mock

        base = f"127.0.0.1:{port}/repos"
        with unittest.mock.patch("_python_common.build_api_url", side_effect=lambda repo, channel: f"http://{base}/{repo}/releases/latest" if channel == "stable" else f"http://{base}/{repo}/no-releases"):
            ok_result = fetch_latest_release("owner/repo", "stable")
            empty_result = fetch_latest_release("owner/repo", "all")
        if ok_result == "v9.9.9":
            ok("fetch_latest_release parses a successful 200 response")
        else:
            bad(f"fetch_latest_release should return 'v9.9.9', got {ok_result!r}")
        if empty_result == "":
            ok("fetch_latest_release returns '' (not None) for a success with no releases")
        else:
            bad(f"fetch_latest_release should return '', got {empty_result!r}")
    finally:
        httpd.shutdown()
    thread.join(timeout=2)

unreachable_result = fetch_latest_release("owner/repo", "all", timeout=0.5)
if unreachable_result is None:
    ok("fetch_latest_release returns None on connection failure")
else:
    bad(f"fetch_latest_release should return None on failure, got {unreachable_result!r}")

print()
print("=" * 62)
print(f"  Results: {passed} passed, {failed} failed")
print("=" * 62)
print()

sys.exit(1 if failed else 0)
PYEOF

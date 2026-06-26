# host-tools

[日本語版はこちら](README.ja.md)

Scripts in this directory are executed on the host OS via HostMCP's `run_host_tool`.

## ⚠️ Run after adding or modifying scripts

```bash
hostmcp tools sync
```

Run this on the **host OS** — changes won't take effect in HostMCP until you do.

### Why is this needed?

This directory is inside the container (staging area).
Scripts are only executed from the approved copy at `~/.hostmcp/host-tools/<project-id>/`.

```
1. Place scripts in .sandbox/host-tools/   ← AI and developers can edit here
2. Run hostmcp tools sync                    ← Review and approve changes on host OS
3. Approved copy goes to ~/.hostmcp/host-tools/<project-id>/  ← Only this is executed
```

Changes are detected via SHA256 hash, so **re-approval is required after every edit**.

Details: [docs/host-access.md](../../docs/host-access.md)

---

## Scripts

| File | Purpose | Platform |
|------|---------|----------|
| `xcode-build.sh` | Xcode build (syntax check) | macOS only |
| `xcode-test.sh` | Xcode test runner | macOS only |
| `xcode-archive.sh` | Xcode archive (for TestFlight / App Store submission) | macOS only |
| `copy-credentials.sh` | Copy credentials | Cross-platform |
| `mac-memory.sh` | macOS memory usage report | macOS only |

---

## xcode-build.sh / xcode-test.sh / xcode-archive.sh

> **macOS only.** Requires Xcode installed on the host OS.

Auto-detects `.xcodeproj` and runs the build/test/archive.

```bash
# Auto-detect (searches within 2 levels of WORKSPACE_DIR)
./xcode-build.sh

# Specify project explicitly
./xcode-build.sh --project /path/to/MyApp.xcodeproj

# Specify scheme (default: base name of .xcodeproj)
./xcode-build.sh --scheme MyAppDebug
```

### `--only` option in xcode-test.sh

`--only` takes a **Swift `struct` name**, not a file name.

```bash
# ✅ Specify by struct name
./xcode-test.sh --only MyFeatureTests

# ❌ Specify by file name → 0 tests run
./xcode-test.sh --only MyFeature   # file name
```

Use `--test-target` to specify a test target explicitly.

```bash
# Default: <Scheme>Tests/MyFeatureTests
./xcode-test.sh --only MyFeatureTests

# Specify a different target
./xcode-test.sh --test-target MyAppIntegrationTests --only MyFeatureTests
```

UI tests are skipped by default. Pass `--no-skip-ui-tests` to include them.

### Checking build errors

After running `xcode-build.sh`, any errors are saved to:

```
<workspace>/tmp/xcode-build-errors.txt
```

Readable from inside the container with the Read tool.

---

## copy-credentials.sh

Copies credentials to the appropriate location. Works cross-platform.

---

## mac-memory.sh

> **macOS only.** Reports memory usage on macOS.

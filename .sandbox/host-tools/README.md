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
| `run-host-setup-tests.sh` | Run all (or one, via `--test-script`) `.sandbox/host-setup/test-*.sh` files | Cross-platform |
| `docker-compose-up.sh` | Start containers from any docker-compose file | Cross-platform |
| `docker-compose-down.sh` | Stop containers from any docker-compose file | Cross-platform |
| `docker-compose-build.sh` | Build images from any docker-compose file | Cross-platform |

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

## run-host-setup-tests.sh

Runs `.sandbox/host-setup/test-*.sh` on the host OS — all of them by default, or a single
one via `--test-script <name>`. This exists because those test suites exercise real
network calls, a real `go`/`curl`, and real shell rc files, so they refuse to run inside
the AI Sandbox container itself.

```bash
./run-host-setup-tests.sh
./run-host-setup-tests.sh --test-script test-install-hostmcp.sh
```

Full output per suite is also saved to:

```
<workspace>/.sandbox/tmp/<test-script-name>-output.log
```

Readable from inside the container with the Read tool.

---

## copy-credentials.sh

Exports or imports the home directory (credentials, settings, history) between DevContainer projects, based on `docker-compose.yml`. Works cross-platform.

```bash
# Export the current workspace's home directory to a backup path
./copy-credentials.sh --export /path/to/workspace ~/backup

# Import it back into another workspace
./copy-credentials.sh --import ~/backup /path/to/other-workspace
```

---

## mac-memory.sh

> **macOS only.** Reports memory usage on macOS.

---

## docker-compose-up.sh / docker-compose-down.sh / docker-compose-build.sh

Generic wrappers around `docker compose up -d` / `down` / `build`, executed on the host OS.
These are sample scripts — a working starting point, not a full solution for every project.
Adapted from the demo scripts in `ai-sandbox-demo/.sandbox/host-tools/` (`demo-up.sh` /
`demo-down.sh` / `demo-build.sh`), which hardcode the demo's compose file path.

```bash
# Start containers
./docker-compose-up.sh /path/to/docker-compose.yml

# Stop containers
./docker-compose-down.sh /path/to/docker-compose.yml

# Build images
./docker-compose-build.sh /path/to/docker-compose.yml

# Extra docker compose flags after --
./docker-compose-up.sh ./docker-compose.yml -- --build
./docker-compose-down.sh ./docker-compose.yml -- --volumes
./docker-compose-build.sh ./docker-compose.yml -- --no-cache
```

Since these run through HostMCP's `run_host_tool`, you can start/stop/build containers
from inside the AI Sandbox even without Docker socket access — no need to ask the user
to run `docker compose` manually. Copy and adapt these scripts if your project needs
project-specific defaults (fixed compose file path, extra env vars, service names in
log messages, etc.).

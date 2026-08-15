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

If a script declares its own timeout (`# @timeout: <seconds>` in its header — see `xcode-test.sh`), `hostmcp tools sync` always shows that declaration before asking for approval, so review it there before typing `y`.

Details: [docs/host-access.md](../../docs/host-access.md)

---

## Scripts

| File | Purpose | Platform |
|------|---------|----------|
| `xcode-build.sh` | Xcode build (syntax check) | macOS only |
| `xcode-test.sh` | Xcode test runner | macOS only |
| `xcode-archive.sh` | Xcode archive (for TestFlight / App Store submission) | macOS only |
| `xcode-install-app.sh` | Build and copy the resulting .app to a fixed directory (default: `~/.hostmcp/Applications`) | macOS only |
| `copy-credentials.sh` | Copy credentials | Cross-platform |
| `mac-memory.sh` | macOS memory usage report | macOS only |
| `run-host-setup-tests.sh` | Run all (or one, via `--test-script`) `.sandbox/host-setup/test-*.sh` files | Cross-platform |
| `docker-compose-up.sh` | Start containers from any docker-compose file | Cross-platform |
| `docker-compose-down.sh` | Stop containers from any docker-compose file | Cross-platform |
| `docker-compose-build.sh` | Build images from any docker-compose file | Cross-platform |
| `docker-compose-config.sh` | Validate/render the merged config of one or more docker-compose files (read-only) | Cross-platform |
| `xcodegen-generate.sh` | Generate an `.xcodeproj` from an XcodeGen `project.yml` spec | macOS only |
| `check-gvisor.sh` | Check whether gVisor (runsc) is usable as a Docker runtime (read-only) | Cross-platform |

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

Recommended: wrap tests in an outer struct named after the file, with inner nested structs. This keeps the struct name matching the file name (so `--only` works as expected) while still letting you group related tests:

```swift
// FeatureTests.swift
struct FeatureTests {
    struct Loading { /* @Test funcs */ }
    struct Saving { /* @Test funcs */ }
}
```

UI tests are skipped by default. Pass `--no-skip-ui-tests` to include them.

### Checking build errors

After running `xcode-build.sh`, any errors are saved to:

```
<workspace>/tmp/xcode-build-errors.txt
```

Readable from inside the container with the Read tool.

---

## xcode-install-app.sh

> **macOS only.** Requires Xcode installed on the host OS.

Builds the app and copies the resulting `.app` from Xcode's DerivedData (an
unpredictable, hashed path) to a fixed directory — `~/.hostmcp/Applications` by default. This gives
the container a stable, known path to reference instead of having to locate
DerivedData's hashed build folder.

> **How overwriting works**: `--dest-dir` can only resolve to a path under `$HOME` (enforced
> by the script — anything outside is rejected). Within that directory, only the subfolder
> matching the built app's name (e.g. `MyApp.app`) is synced with `rsync --delete` (removing
> anything not present in the fresh build), so reinstalling the same app never leaves a mix
> of old and new files behind — other apps sharing the same `--dest-dir` are untouched. Note
> that if a project's built app name changes between installs, the old, differently-named
> folder is left behind rather than removed.

```bash
# Build and install to ~/.hostmcp/Applications
./xcode-install-app.sh --project /path/to/MyApp.xcodeproj

# Install to a custom directory
./xcode-install-app.sh --scheme MyApp --dest-dir ~/.local/App
```

This only affects where the *installed copy* lives — it doesn't change where Xcode
itself builds (DerivedData), so building the same project from the Xcode GUI later
still works exactly as normal.

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

---

## docker-compose-config.sh

Read-only diagnostic: renders the merged config of one or more docker-compose files via
`docker compose config`. Makes no changes — no images built, no containers started. Use
it to validate compose YAML (e.g. an override file meant to be merged with a base
`docker-compose.yml`) without needing the user to run `docker compose` manually.

```bash
# Validate a single file
./docker-compose-config.sh /path/to/docker-compose.yml

# Validate an override merged on top of a base file (order matters, same as -f -f)
./docker-compose-config.sh ./docker-compose.yml ./docker-compose.override.yml

# Extra docker compose flags after --
./docker-compose-config.sh ./docker-compose.yml -- --services
```

---

## xcodegen-generate.sh

> **macOS only.** Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) on the host: `brew install xcodegen`.

Generates an `.xcodeproj` from an XcodeGen `project.yml` spec.

```bash
# Generate next to the spec file
./xcodegen-generate.sh /path/to/project.yml

# Extra xcodegen flags after --
./xcodegen-generate.sh ./project.yml -- --use-cache
```

The `.xcodeproj` is written into the same directory as the spec file.

---

## check-gvisor.sh

A read-only diagnostic that checks whether gVisor (`runsc`) is usable as a Docker
runtime on the host OS. Makes no changes.

```bash
./check-gvisor.sh
```

What it checks:
- Whether the Docker daemon is reachable
- Whether `runsc` is already registered as a Docker runtime (`docker info`'s `Runtimes`)
- Whether a `runsc` binary is found on the host PATH
- OS-specific (Linux / macOS) next-step guidance

On macOS, Docker Desktop / OrbStack already run containers inside their own Linux VM,
and that VM boundary provides a layer of isolation on its own, so adding gVisor on top
is generally unnecessary (see [docs/comparison.md](../../docs/comparison.md#where-this-project-sits-among-isolation-technologies)
for details).

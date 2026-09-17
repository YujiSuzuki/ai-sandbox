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

**`@timeout` is not the only timeout layer.** It only raises how long HostMCP lets the script run on the host OS before force-killing it. Calling the script via MCP's `run_host_tool` is a separate layer with its own default wait (60s unless `MCP_TOOL_TIMEOUT` is set) — it can report an apparent failure even though the host-side script keeps running past 60s. When a script's `@timeout` exceeds that MCP default, either pass `client_timeout_seconds` to `run_host_tool`, or fall back to `hostmcp client --timeout <seconds> ...` (matching the script's own `@timeout`) via Bash. See `xcode-test.sh`'s header for a worked example of both layers together.

Details: [docs/host-access.md](../../docs/host-access.md)

---

## Scripts

| File | Purpose | Platform |
|------|---------|----------|
| `xcode-build.sh` | Xcode build (syntax check) | macOS only |
| `xcode-test.sh` | Xcode test runner | macOS only |
| `xcode-archive.sh` | Xcode archive (for TestFlight / App Store submission) | macOS only |
| `xcode-install-app.sh` | Build and copy the resulting .app to a fixed directory (default: `~/.hostmcp/Applications`) | macOS only |
| `mac-memory.sh` | macOS memory usage report | macOS only |
| `run-host-setup-tests.sh` | Run all (or one, via `--test-script`) `.sandbox/host-setup/test-*.sh` files | Cross-platform |
| `docker-compose-up.sh` | Start containers from any docker-compose file | Cross-platform |
| `docker-compose-down.sh` | Stop containers from any docker-compose file | Cross-platform |
| `docker-compose-build.sh` | Build images from any docker-compose file | Cross-platform |
| `docker-compose-config.sh` | Validate/render the merged config of one or more docker-compose files (read-only) | Cross-platform |
| `xcodegen-generate.sh` | Generate an `.xcodeproj` from an XcodeGen `project.yml` spec | macOS only |
| `check-gvisor.sh` | Check whether gVisor (runsc) is usable as a Docker runtime (read-only) | Cross-platform |
| `check-xcode.sh` | Check whether Xcode is installed and usable (read-only) | Cross-platform (macOS-specific checks) |
| `xcode-simulator-screenshot.sh` | Build, install, and launch an iOS app on a Simulator, then capture a screenshot (or, via `--ui-test`, a specific screen beyond the launch screen) | macOS only |
| `restart-simulator.sh` | Shut down all Simulator devices and/or fully quit + reopen Simulator.app | macOS only |
| `simulator-app-reset.sh` | Uninstall one app from a Simulator device and/or reset one of its privacy grants (e.g. notifications), without restarting the whole Simulator | macOS only |

---

## xcode-build.sh / xcode-test.sh / xcode-archive.sh

> **macOS only.** Requires Xcode installed on the host OS.

Auto-detects `.xcodeproj` and runs the build/test/archive.

```bash
# Auto-detect (searches within 2 levels of WORKSPACE_DIR)
./xcode-build.sh

# Specify project explicitly (absolute path)
./xcode-build.sh --project /path/to/MyApp.xcodeproj

# Specify project explicitly (relative to WORKSPACE_DIR — also works, and is
# the simplest form when the project sits deeper than auto-detect reaches,
# e.g. a nested sub-repo's own ios/ subdirectory)
./xcode-build.sh --project myapp/ios/MyApp.xcodeproj

# Specify scheme (default: base name of .xcodeproj)
./xcode-build.sh --scheme MyAppDebug
```

> Auto-detect only searches **2 levels** under `WORKSPACE_DIR` (`find -maxdepth 2`). A project
> nested deeper — e.g. `WORKSPACE_DIR/myapp/ios/MyApp.xcodeproj` (3 levels: `myapp` → `ios` →
> `MyApp.xcodeproj`) inside a sub-repo — won't be found automatically and needs an explicit
> `--project`, even though it's still "under the workspace" in the everyday sense.

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

**Single test method, when the XCTest class shares its name with its target**: `--only`'s
2-segment `Class/Method` shorthand only works because `xcodebuild -only-testing:`'s first
segment is normally read as the *target* — the script's 2-segment example works because the
target name (`MyAppTests`) and class name (`MyFeatureTests`) differ, so xcodebuild falls back to
reading the first segment as a class. But a UI test target's class is conventionally named the
same as its target (e.g. class `MyAppUITests` inside target `MyAppUITests`), and in that case the
2-segment form is read as `Target/Class` and silently matches 0 tests — the class-name segment
is missing. Pass all **three** segments instead:

```bash
# ❌ 0 tests — read as Target=MyAppUITests / Class=testSomething (no such class)
./xcode-test.sh --no-skip-ui-tests --test-target MyAppUITests --only "MyAppUITests/testSomething"

# ✅ Target/Class/Method
./xcode-test.sh --no-skip-ui-tests --test-target MyAppUITests --only "MyAppUITests/MyAppUITests/testSomething"

# ✅ Same, plus the project nested deeper than auto-detect's 2 levels (see above)
./xcode-test.sh --project myapp/ios/MyApp.xcodeproj --no-skip-ui-tests \
  --test-target MyAppUITests --only "MyAppUITests/MyAppUITests/testSomething"
```

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
./docker-compose-down.sh ./docker-compose.yml -- --remove-orphans
./docker-compose-build.sh ./docker-compose.yml -- --no-cache
```

`docker-compose-down.sh` rejects destructive flags (`-v`/`--volumes`, `--rmi`) — it only stops/removes containers, never volumes or images.

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

---

## check-xcode.sh

A read-only diagnostic that checks whether Xcode is installed and usable on the
host OS. Makes no changes. Run this before `xcode-build.sh` / `xcode-test.sh` /
`xcode-archive.sh` / `xcode-install-app.sh` / `xcodegen-generate.sh` to find out
in advance whether they'll work on this host, instead of discovering it from a
build failure.

```bash
./check-xcode.sh
```

What it checks:
- Whether the host OS is macOS (the other scripts above are macOS-only)
- Whether Command Line Tools or full Xcode is the active developer directory (`xcode-select -p`)
- Whether `xcodebuild` runs (including license-not-accepted errors)
- Which iOS Simulator runtimes are installed (via `xcrun simctl`)

---

## xcode-simulator-screenshot.sh

> **macOS only.** Requires Xcode and at least one iOS Simulator runtime installed on the host OS.

Builds an iOS app, installs and launches it on a Simulator, and saves a screenshot to a
path under `WORKSPACE_DIR` — the shared workspace mount is the only channel back to the
AI, since there's no other way to see what's on the host's screen.

```bash
# Auto-detect the .xcodeproj, save to tmp/simulator-screenshot.png
./xcode-simulator-screenshot.sh

# Specify scheme and output path (relative to WORKSPACE_DIR)
./xcode-simulator-screenshot.sh --scheme MyApp --output tmp/home.png

# Wait longer after launch before capturing (default: 3s)
./xcode-simulator-screenshot.sh --wait 5

# Capture a screen beyond the launch screen, via a UI test that navigates
# there itself and takes its own screenshot (see docs/ai-guide.md's
# "XCUITest Screenshot Automation" section for how to write that test)
./xcode-simulator-screenshot.sh --scheme MyApp --ui-test "MyAppUITests/MyAppUITests/testSettingsScreenshot" --output tmp/settings.png
```

`--output` must be a `WORKSPACE_DIR`-relative path (no `..`, no absolute paths). Build
output is also saved to:

```
<workspace>/tmp/xcode-simulator-screenshot-build.log
```

`--ui-test <Target>/<Class>/<method>` runs that one XCUITest method via `xcodebuild test`
and extracts the screenshot it captured (via `XCTAttachment`) using `xcresulttool`,
instead of the default simctl install/launch/screenshot flow — this is how a screen
beyond the app's launch screen gets captured. `--wait` is ignored in this mode, since
the test's own `waitForExistence` controls timing. This mode's build+test run needs more
headroom than a plain build, so this script declares `@timeout: 600` — after pulling a
change to this script, re-run `hostmcp tools sync` on the host to approve it, and pass
`--timeout 600` (CLI) or `client_timeout_seconds: 600` (`run_host_tool`) when calling it.

---

## restart-simulator.sh

> **macOS only.** Requires Xcode / Command Line Tools (`xcrun`) on the host OS.

Shuts down all booted Simulator devices (`xcrun simctl shutdown all`) and, by default,
also fully quits Simulator.app (without relaunching it). Use it when a Simulator is
stuck — frozen UI, stale app state, a device that won't boot — and a normal relaunch
from Xcode doesn't clear it.

> **Impact is host-wide, not project-scoped.** Simulator.app and the CoreSimulator
> daemon are shared by the whole Mac. Running this interrupts any Simulator session
> the developer has open for unrelated work (other projects, manual testing, an
> attached debugger), not just this project's.

> **Reopening is opt-in on purpose.** `xcode-test.sh` (`xcodebuild test`) and
> `xcode-simulator-screenshot.sh` (`xcrun simctl bootstatus -b` + `simctl
> install`/`launch`) both boot/use the target device headlessly regardless of
> whether Simulator.app's GUI is open, so running this script right before a
> build/test needs no reopen. Pass `--reopen` only when you want to look at the
> simulator yourself afterward.

```bash
# Shut down all devices and quit Simulator.app (stays closed)
./restart-simulator.sh

# Only shut down devices -- leaves Simulator.app running untouched
./restart-simulator.sh --shutdown-only

# Shut down devices, quit, and relaunch Simulator.app -- for manual/visual use
./restart-simulator.sh --reopen

# Force-kill a frozen Simulator.app instead of a graceful quit
./restart-simulator.sh --force
```

---

## simulator-app-reset.sh

> **macOS only.** Requires Xcode / Command Line Tools (`xcrun`) on the host OS.

Uninstalls one app from a Simulator device and/or resets one of its privacy permission
grants (notifications, camera, photos, ...), without restarting the whole Simulator.

> **Why this exists.** iOS/iPadOS remembers a permission decision (e.g. "Allow"/"Don't
> Allow" on the notification prompt) per bundle ID in the device's privacy database, not
> inside the app's own container. Reinstalling the same app via a normal build+install
> (`xcode-build.sh`, `xcode-test.sh`, `xcode-simulator-screenshot.sh`) does **not** clear
> that decision. A UI test (or manual check) that needs to see the permission prompt
> again — to verify what a fresh user actually sees, or to unblock a run stuck on a
> stale "Don't Allow" from an earlier attempt — has no way back to a clean state without
> this script.

```bash
# Uninstall the app entirely (also clears every privacy grant for it)
./simulator-app-reset.sh --bundle-id com.example.MyApp --uninstall

# Keep the app installed, just re-arm the notification permission prompt
./simulator-app-reset.sh --bundle-id com.example.MyApp --reset-privacy notifications

# Both at once, on a specific device
./simulator-app-reset.sh --bundle-id com.example.MyApp --device <udid> --uninstall --reset-privacy all
```

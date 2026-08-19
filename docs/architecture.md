# Architecture Details

[日本語版はこちら](architecture.ja.md)

Detailed diagrams explaining how AI Sandbox + HostMCP works.

[← Back to README](../README.md)

---

## Overall Architecture

```
┌───────────────────────────────────────────────────┐
│ Host OS                                           │
│                                                   │
│  ┌──────────────────────────────────────────────┐ │
│  │ HostMCP Server                               │ │
│  │  HTTP/SSE API for AI                         ←─────┐
│  │  Security policy enforcement                 │ │   │
│  │  Container access gateway                    │ │   │
│  │                                              │ │   │
│  └────────────────────↑─────────────────────────┘ │   │
│                       │ :18080                     │   │
│  ┌────────────────────│─────────────────────────┐ │   │
│  │ Docker Engine      │                         │ │   │
│  │                    │                         │ │   │
│  │   AI Sandbox  ←────┘                         │ │   │
│  │    ├─ Claude Code / Gemini                   │ │   │
│  │    ├─ SandboxMCP (stdio)                     │ │   │
│  │    └─ secrets/ → empty (hidden)              │ │   │
│  │                                              │ │   │
│  │   API Container    ←───────────────────────────────┘
│  │    └─ secrets/ → real files                  │ │   │
│  │                                              │ │   │
│  │   Web Container    ←───────────────────────────────┘
│  │                                              │ │
│  └──────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────┘
```

<details>
<summary>Tree format</summary>

**Data flow:** AI (AI Sandbox) → HostMCP (:18080) → Other containers

```
Host OS
├── HostMCP Server (:18080)
│   ├── HTTP/SSE API for AI
│   ├── Security policy enforcement
│   └── Container access gateway
│
└── Docker Engine
    ├── AI Sandbox (AI environment)
    │   ├── Claude Code / Gemini
    │   ├── SandboxMCP (stdio)
    │   └── secrets/ → empty (hidden)
    │
    ├── API Container
    │   └── secrets/ → real files
    │
    └── Web Container
```

</details>

---

## How Secret Hiding Works

Since AI runs inside the AI Sandbox, Docker volume mounts can hide secret files.

```
Host OS
├── your-api/.env  ← actual file
│
├── AI Sandbox (AI execution environment)
│   └── AI tries to read .env
│       → Mounted to /dev/null, appears empty
│
└── API Container (runtime environment)
    └── Node.js app reads .env
        → Reads normally
```

**Result:**
- AI cannot read secret files (security ensured)
- Apps can read secret files (functionality maintained)
- AI can still check logs and run tests via HostMCP

---

## Benefits of AI Sandbox Isolation

Running AI inside the AI Sandbox also restricts access to host OS files.

```
Host OS
├── /etc/            ← inaccessible to AI
├── ~/.ssh/          ← inaccessible to AI
├── ~/Documents/     ← inaccessible to AI
├── ~/other-project/ ← inaccessible to AI
├── ~/secret-memo/   ← inaccessible to AI
│
└── AI Sandbox
    └── /workspace/   ← only this is visible
        ├── hostmcp/
        ├── <your-project>/
        └── ...
```

**Benefits:**
- Cannot touch host OS system files
- Cannot access other projects
- Cannot access SSH keys or credentials (`~/.ssh/`)
- No risk of accidentally modifying the host OS

---

## Security Features in Detail

### 1. Secret Hiding

Hides secrets from AI using Docker volume mounts:

```yaml
# .devcontainer/docker-compose.yml
volumes:
  # Hide secret files
  - /dev/null:/workspace/your-api/.env:ro

tmpfs:
  # Hide secret directories. The trailing "# @secret" tag is required —
  # without it, validate-secrets.py silently skips this entry, while
  # check-secret-sync.sh instead reports it as a visible "missing" error.
  - /workspace/your-api/secrets  # @secret
```

**Result:**
- AI sees empty files/directories
- Actual containers can access real secrets
- Development works normally!

> **See it in action:** [ai-sandbox-demo](https://github.com/YujiSuzuki/ai-sandbox-demo) includes a complete SecureNote example with live demonstration of secret hiding.

### 2. Controlled Container Access

HostMCP enforces security policies:

```yaml
# hostmcp.yaml
security:
  mode: "moderate"  # strict | moderate | permissive

  allowed_containers:
    - "demo-*"
    - "project_*"

  exec_whitelist:
    "securenote-api":
      - "npm test"
      - "npm run lint"
```

For container file blocking (`blocked_paths`), auto-import from Claude Code / Gemini settings, and more, see [hostmcp README "Configuration Reference"](https://github.com/YujiSuzuki/hostmcp#configuration-reference).

**Example — Cross-container debugging:**

```bash
# Simulate a bug: Can't log in on web app

# Ask Claude Code:
"Login is failing. Can you check the API logs?"

# Claude gets logs via HostMCP:
hostmcp.get_logs("securenote-api", { tail: "50" })

# Error found in logs:
"JWT verification failed - invalid secret"

# Ask Claude Code:
"Please run the API tests to verify"

# Claude runs tests via HostMCP:
hostmcp.exec_command("securenote-api", "npm test")

# Issue identified and fixed!
```

### 3. Basic Sandbox Protection

- **Non-root user**: Runs as `node` user
- **Limited sudo**: Package managers only (apt, npm, pip)
- **Credential persistence**: Named volumes for `.claude/`, `.config/gcloud/`

> ⚠️ **Security note: npm/pip3 sudo risks**
>
> Allowing sudo for npm/pip3 can be exploited through malicious packages. Malicious postinstall scripts can execute arbitrary code with elevated privileges.
>
> **Mitigation options:**
> 1. Remove npm/pip3 from sudoers (edit `.sandbox/Dockerfile`)
> 2. Use `npm install --ignore-scripts` flag
> 3. Pre-install required packages in Dockerfile
> 4. Set `ignore-scripts=true` in `.npmrc`

### 4. Output Masking (Defense in Depth)

Even if secrets appear in logs or command output, HostMCP automatically masks them:

```
# Raw log output
DATABASE_URL=postgres://user:secret123@db:5432/app

# What AI sees (after masking)
DATABASE_URL=[MASKED]db:5432/app
```

Detects passwords, API keys, Bearer tokens, database URLs with credentials, and more by default. For configuration details, see [hostmcp README "Output Masking"](https://github.com/YujiSuzuki/hostmcp#output-masking).

### 5. Why No Docker Socket Access

You might wonder: "Why not just mount the Docker socket (`/var/run/docker.sock`) into the AI Sandbox so AI can access containers directly without HostMCP?"

This must not be done because **Docker socket access is essentially host administrator privileges**. If AI had the socket, it could:

- Use `docker exec` to **read `.env` and `secrets/` from other containers** (bypassing all hiding)
- Use `docker run -v /:/host` to **mount the entire host filesystem**
- Stop, delete, or manipulate any container or image

In other words, hiding secrets with volume mounts becomes pointless — AI could simply read the real files through Docker commands.

**HostMCP exists to solve this problem:**

| | Direct Docker Socket | Via HostMCP |
|---|---|---|
| Secret files | Readable | **Blocked** |
| Commands | Unrestricted | **Whitelist only** |
| Secrets in logs | Visible as-is | **Auto-masked** |
| Stop/delete containers | Possible | **Not possible** |

HostMCP is a gateway that provides only the operations AI actually needs (log checking, test execution, etc.) in a safe, controlled way.

---

## Multi-Project Workspace

These security features enable safely working with multiple projects in a single workspace.

Example (using [ai-sandbox-demo](https://github.com/YujiSuzuki/ai-sandbox-demo)):
- **Backend API** (demo-apps/securenote-api)
- **Web Frontend** (demo-apps/securenote-web)
- **iOS App** (demo-apps-ios/)

What AI can do:
- Read all source code (investigate issues across app and server boundaries)
- Check any container's logs (via HostMCP)
- Run tests across projects
- Debug cross-container issues
- **Never touch secrets**

---

## SandboxMCP - In-Container MCP Server

In addition to HostMCP (host-side), **SandboxMCP** runs inside the container.

**Why it exists:** a script or tool dropped in `.sandbox/` doesn't help if the AI doesn't know it exists, and re-explaining its usage every session doesn't scale. SandboxMCP solves this by auto-discovering scripts/tools and pushing workspace context to the AI automatically at startup — dynamic environment info such as git status, or proactively flagging that HostMCP is disconnected and host-tools are unavailable — this matters even for AI agents with full shell access, since the AI receives the context without having to decide to go look for it. See the [sandbox-mcp README](https://github.com/YujiSuzuki/sandbox-mcp#readme) for the full rationale.

```
┌─────────────────────────────────────────────────────┐
│ AI Sandbox (inside container)                       │
│                                                     │
│  ┌─────────────────┐      ┌─────────────────────┐  │
│  │ Claude Code     │ ←──→ │ SandboxMCP (stdio)  │  │
│  │ Gemini CLI      │      │                     │  │
│  └─────────────────┘      │ • list_scripts      │  │
│                           │ • get_script_info   │  │
│                           │ • run_script        │  │
│  ┌─────────────────────┐  │ • list_tools        │  │
│  │ .sandbox/scripts/   │  │ • get_tool_info     │  │
│  │ • validate-secrets  │←─│ • run_tool          │  │
│  │ • sync-secrets      │  └─────────────────────┘  │
│  │ • help              │                           │
│  │ • ...               │                           │
│  └─────────────────────┘                           │
└─────────────────────────────────────────────────────┘
```

### HostMCP vs SandboxMCP

| | SandboxMCP | HostMCP |
|---|---|---|
| Location | Inside container | Host OS |
| Transport | stdio | SSE (HTTP) |
| Purpose | Script/tool discovery & execution | Cross-container access |
| Startup | Auto-started by AI CLI | Manual (`hostmcp serve`) |

### 6 MCP Tools

| Tool | Description | Example Use |
|------|-------------|-------------|
| `list_scripts` | List available scripts | "What scripts can I use?" |
| `get_script_info` | Get script details | "How do I use validate-secrets.py?" |
| `run_script` | Execute a container script | "Run validate-secrets.py" |
| `list_tools` | List available tools | "What tools are available?" |
| `get_tool_info` | Get tool details | "How do I use search-history?" |
| `run_tool` | Execute a tool | "Search my conversation history for 'MCP'" |

### Auto-Registration

SandboxMCP automatically builds and registers on container startup:

- **DevContainer**: Runs in `postStartCommand`
- **CLI Sandbox**: Runs in startup script
- **Supports both Claude Code and Gemini CLI**: Registers if CLI is installed

For manual registration:

```bash
cd /workspace/.sandbox/sandbox-mcp
make register    # Build and register
make unregister  # Remove registration
```

### Adding Custom Tools

Place a Go file in `.sandbox/tools/` and SandboxMCP will automatically discover it. The file header (comments before `package`) is parsed to extract metadata. A `// ---` separator line stops parsing, so localized descriptions below it are not included:

```go
// Short description (first comment line becomes the description)
//
// Usage:
//   go run .sandbox/tools/my-tool.go [options] <args>
//
// Examples:
//   go run .sandbox/tools/my-tool.go "hello"
//   go run .sandbox/tools/my-tool.go -verbose "world"
//
// --- optional localized description (not parsed) ---
//
// ツールの日本語説明（任意）
package main
```

```
┌───────────────────────────────────────────────────┐
│ .sandbox/tools/                                   │
│  ├── search-history.go   ← built-in              │
│  └── my-tool.go          ← just drop a file here │
│                                                   │
│ SandboxMCP auto-discovers *.go files              │
│ No registration or configuration needed           │
└───────────────────────────────────────────────────┘
```

AI assistants can then use `list_tools` to find it, `get_tool_info` to read its usage, and `run_tool` to execute it.

### Adding Custom Scripts

You can also place shell scripts in `.sandbox/scripts/` and they will be automatically discovered. Since scripts can call other languages (Python, Node.js, etc.), you can build tools in any language, not just Go.

**Header format:**

```bash
#!/bin/bash
# my-script.sh
# English description (can be multi-line)
# Additional description continues here
# ---
# Japanese description (optional, not parsed)
```

- Line 1: Shebang
- Line 2: Filename
- Line 3+: English description (can span multiple lines, shown to AI in `list_scripts`)
- Line N: `# ---` separator (parsing stops here)
- Line N+1 onwards: Japanese description, etc. (for human readers, not passed to AI)

The `# ---` separator marks the end of parsed content. Everything after it is ignored by the parser but kept for human readers. This aligns with the Go tools' `// ---` separator pattern.

**Usage section (optional):**

If a `Usage:` line appears before the `# ---` separator, it will be displayed by `get_script_info`. The section ends at an empty comment line. This aligns with the Go tools pattern where Usage/Examples come before `// ---`.

```bash
#!/bin/bash
# my-script.sh
# English description
#
# Usage:
#   my-script.sh [options] <args>
#   my-script.sh --verbose "hello"
#
# ---
# 日本語の説明
```

**Skipped files:**

| Pattern | Reason |
|---|---|
| Files starting with `_` | Treated as libraries (e.g., `_startup_common.sh`) |
| `help.sh` | The help script itself is excluded from listings |
| Non-`.sh` files | Not processed |

**Automatic category classification:**

| Filename | Category |
|---|---|
| Starts with `test-` | `test` |
| All others | `utility` |

**Environment classification:**

Scripts are classified into two execution environments.

| Environment | Scripts |
|---|---|
| `container` (container only) | `sync-secrets.sh`, `validate-secrets.py`, `sync-compose-secrets.sh`, `check-secret-sync.sh`, `compare-secret-config.sh`, `check-undeclared-secrets.py`, `triage-undeclared-secrets.sh` |
| `any` (either) | All others |

```
┌───────────────────────────────────────────────────┐
│ .sandbox/scripts/                                 │
│  ├── validate-secrets.py  ← built-in (container)  │
│  ├── test-*.sh            ← test category         │
│  ├── _startup_common.sh   ← skipped (library)     │
│  └── my-script.sh         ← just drop a file here │
│                                                   │
│ SandboxMCP auto-discovers *.sh files              │
│ No registration or configuration needed           │
└───────────────────────────────────────────────────┘
```

AI assistants can use `list_scripts` to find them, `get_script_info` to read usage, and `run_script` to execute them.

### Startup Context Injection

Place shell scripts in [`.sandbox/sandbox-mcp-setup/`](../.sandbox/sandbox-mcp-setup/) to inject custom context into the AI's startup instructions. They run in alphabetical order (5s timeout each) when SandboxMCP starts, and their stdout is appended to the MCP `instructions` (shown as `<system-reminder>` in Claude Code).

```
.sandbox/sandbox-mcp-setup/
├── 05-sandbox-mcp-purpose.sh       ← self-describes SandboxMCP's role vs HostMCP
├── 10-sandbox-env.sh               ← reports $SANDBOX_ENV
├── 15-host-os.sh                   ← reports the host OS/arch from .sandbox/.host-os
├── 20-git-uncommitted.sh           ← reports uncommitted changes in nested git repos
├── 22-nested-repo-docs.sh          ← reports which doc files (CLAUDE.md/README.md/README.ja.md) each nested repo has
├── 25-undeclared-secrets-diff.sh   ← reports newly-appeared undeclared-secret-like files
├── 30-language.sh                  ← reports the response language derived from $LANG
├── 40-hostmcp-host-tools-hint.sh   ← hints that .sandbox/host-tools/ scripts exist when HostMCP isn't connected
└── 50-mcp-tool-timeout.sh          ← reports Claude Code's own MCP tool-call timeout (MCP_TOOL_TIMEOUT or the 60s default)
```

This is how the AI learns things like the current sandbox environment type or nested-repo status without being told every session.

All of the scripts above actually use the `# @output: file` header, spilling their stdout to a file instead of embedding it directly in `instructions`. `instructions` has a byte-size limit, and exceeding it silently truncates the field on the MCP client side (with no trace of what was cut) — this is the workaround. See the [sandbox-mcp README](https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup) for the full mechanism.

`instructions` still keeps a one-line pointer after the spill, but that line is easy to miss among other system-reminders. To close that gap, an ai-sandbox-specific UserPromptSubmit hook ([.sandbox/hooks/setup-output-reminder.sh](../.sandbox/hooks/setup-output-reminder.sh), auto-registered by `startup.sh`) inlines the actual file contents — once per setup-output directory — as `additionalContext` on the next prompt. Since it's the content itself and not just a repeated path, there's nothing left to skip past.

That one-shot dump is enough for purely informational scripts, but not for ones that need the AI to actually act (e.g. [25-undeclared-secrets-diff.sh](../.sandbox/sandbox-mcp-setup/25-undeclared-secrets-diff.sh), which requires mentioning a finding to the user in the very first reply): mixed in with 8 other FYI files and shown only once, an actionable item is easy for the AI to miss entirely. A script can opt out of that one-shot dump and into a repeated one by adding `# @notify: persistent` to its header comment, alongside `# @output: file` — this is an ai-sandbox-only convention read by `setup-output-reminder.sh` itself, not by sandbox-mcp (which has no notion of this tag). Files tagged this way get their own separate, higher-signal block, repeated on every turn until either the AI marks it resolved by running `touch <name>.resolved` next to the spilled `.txt` (the reminder text tells it the exact path) or a repeat cap (5 by default, `PERSISTENT_NOTIFY_CAP` env var) is reached.

For a producer script whose repeated notice corresponds to not-yet-confirmed state on disk, writing that state unconditionally right after detection — rather than only once delivery is proven — risks silently losing a finding if the session ends before any prompt is ever sent, or if the AI reads the notice but never actually relays it to the human (this is exactly what [check-undeclared-secrets-diff.py](../.sandbox/scripts/check-undeclared-secrets-diff.py) used to do). Such a script can add `# @confirm-target: <workspace-relative path>` alongside `# @notify: persistent`. Once the AI touches `<name>.resolved` for that notice — the same marker that stops the repeat above, i.e. once the AI has actually confirmed telling the human, not merely once the notice has been embedded — `setup-output-reminder.sh` promotes a pending file sitting next to the spilled `.txt` (named `<name>.pending.json` by convention, never a tag-declared absolute path) into the `@confirm-target` path, merging its `undeclared` entries into whatever is already there rather than overwriting wholesale. Until resolution happens, the producer script is expected to keep re-deriving its pending file from the latest scan on every invocation, and to keep diffing against the not-yet-advanced target file, so an unconfirmed finding keeps being reported as new rather than silently disappearing. Scoping the pending file to this notice's own PID directory rather than a single shared path means one session's promotion always reads only its own candidates, never a different, concurrently-alive session's. That alone isn't quite enough, though: each session's pending file is a snapshot frozen at connect time, so a slower session resolving after a faster one has already promoted a fuller snapshot could otherwise clobber that newer confirmation with its own stale one — merging rather than overwriting is what keeps promotion monotonic (it can only grow the confirmed set, never roll it back) regardless of resolution order across sessions.

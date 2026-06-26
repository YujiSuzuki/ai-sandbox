# AI Assistant Reference Guide

Detailed reference information for AI assistants working in this project.
This file is referenced from [CLAUDE.md](../CLAUDE.md) — read sections on demand, not all at once.

[← Back to CLAUDE.md](../CLAUDE.md)

---

## HostMCP Setup and Troubleshooting

### Initial Setup

**Step 1: Start HostMCP on Host OS**

```bash
# On Host OS (NOT in AI Sandbox)
cd hostmcp
make install  # Builds and installs to $GOPATH/bin
hostmcp serve --config configs/hostmcp.example.yaml
```

If HostMCP server is restarted, SSE connections drop. Inform user to run `/mcp` → "Reconnect".

**Step 2: Configure MCP in AI Sandbox**

```bash
# Inside AI Sandbox
claude mcp add --transport sse --scope user hostmcp http://host.docker.internal:18080/sse
```

After adding, restart VS Code for it to connect.

**Step 3: Verify**

Check if tools like `list_containers`, `get_logs` are available.

### Troubleshooting

1. **Verify HostMCP is running**: `curl http://localhost:18080/health` (on host OS)
2. **Try MCP Reconnect**: `/mcp` → "Reconnect" in Claude Code
3. **Restart VS Code completely**: Cmd+Q (macOS) / Alt+F4 (Windows/Linux)

If issues persist, verify MCP configuration:

```bash
cat ~/.claude.json | jq '.mcpServers.hostmcp'
# Should show: "url": "http://host.docker.internal:18080/sse"
```

**"Client not initialized" error:** Even when `/mcp` shows "connected", MCP tools may fail. This is caused by VS Code extension session management timing issues. Try:
1. `/mcp` → "Reconnect" first
2. If that fails, use `hostmcp client` fallback (below)
3. Last resort: restart VS Code completely

---

## HostMCP Client Fallback

When MCP tools are unavailable, use `hostmcp client` commands via Bash:

```bash
# List containers
hostmcp client list

# Get logs
hostmcp client logs securenote-api
hostmcp client logs --tail 50 securenote-api

# Execute whitelisted command
hostmcp client exec securenote-api "npm test"

# Host tools
hostmcp client host-tools list
hostmcp client host-tools info my-tool.sh
hostmcp client host-tools run my-tool.sh arg1 arg2

# Container lifecycle (if enabled)
hostmcp client restart securenote-api
hostmcp client stop securenote-api
hostmcp client start securenote-api
hostmcp client restart securenote-api --timeout 30

# Host commands (if enabled)
hostmcp client host-exec "git status"
hostmcp client host-exec --dangerously "git pull"
```

**Custom server URL:**
```bash
hostmcp client list --url http://host.docker.internal:9090
# or
export HOSTMCP_SERVER_URL=http://host.docker.internal:9090
```

**If `hostmcp` not found:** Tell user to run `cd /workspace/hostmcp && make install`. This works inside AI Sandbox (Go is available). Client commands connect to host via HTTP.

---

## Updating This Template

### Detecting Updates

```bash
# Method 1: State file
cat .sandbox/.state/update-check
# Format: <unix_timestamp>:<version>

# Method 2: Git
git fetch origin main
git log HEAD..origin/main --oneline

# Method 3: SandboxMCP
# Use get_update_status tool
```

### Update Procedure

1. **Check what changed**
   ```bash
   git fetch origin main
   git log HEAD..origin/main --oneline
   git diff HEAD..origin/main --stat
   ```

2. **Identify affected components**
   - `.sandbox/sandbox-mcp/` → SandboxMCP needs rebuild
   - `hostmcp/` → HostMCP needs rebuild (user must do on host OS)
   - `.devcontainer/` or `cli_sandbox/` → Container restart required
   - `.sandbox/scripts/` → Scripts updated (may need re-run)

3. **Detect conflicts** — Check if user customized:
   - `.devcontainer/docker-compose.yml`
   - `cli_sandbox/docker-compose.yml`
   - `hostmcp/configs/hostmcp.example.yaml` (and user's local `hostmcp.yaml`)
   - `.claude/settings.json`

4. **Explain changes and risks** to user before applying

5. **Apply the update**
   ```bash
   git pull origin main

   # Rebuild SandboxMCP (if affected)
   cd /workspace/.sandbox/sandbox-mcp
   make clean && make register

   # HostMCP: user must rebuild on host OS
   # cd /workspace/hostmcp && make install
   ```

6. **Verify** — Check SandboxMCP tools, HostMCP connection

### What You CAN/CANNOT Do

- ✅ Read state files, `git fetch`, `git diff`, `git pull`
- ✅ Rebuild SandboxMCP, build HostMCP client
- ❌ Rebuild/restart HostMCP server (host OS)
- ❌ Restart DevContainer, run Docker commands

Do not check for updates proactively unless user asks or is experiencing issues.

---

## Customization Workflow

When a user wants to adapt this template for their project, **do the work yourself**.

### Step 1: Gather project information

Use `AskUserQuestion` to collect:
1. **Project paths** — Directories in `/workspace/`
2. **Secret files** — Files with secrets (`.env`, `config/secrets.json`)
3. **Secret directories** — Directories to hide (`secrets/`, `keys/`)
4. **Container names** — Docker container names for HostMCP
5. **Allowed commands** — Commands per container (`npm test`, etc.)

### Step 2: Configure secret hiding

Edit **both** docker-compose files:
```yaml
volumes:
  - /dev/null:/workspace/my-api/.env:ro
tmpfs:
  - /workspace/my-api/secrets:ro
```

### Step 4: Configure HostMCP

```bash
cp hostmcp/configs/hostmcp.example.yaml hostmcp.yaml
```
Update `allowed_containers` and `exec_whitelist`.

### Step 5: Update AI configuration

- `.claude/settings.json` — Replace demo deny patterns
- `.aiexclude` / `.geminiignore` — Update secret patterns
- `CLAUDE.md` — Rewrite project-specific sections
  - Ask user about `commit-msg.sh` / `github-release.sh`: keep or remove? customize?
- `GEMINI.md` — Same updates

### Step 6: Run validation

```bash
.sandbox/scripts/validate-secrets.sh
.sandbox/scripts/compare-secret-config.sh
.sandbox/scripts/check-secret-sync.sh
```

### Step 7: Hand off to user

Tell them to: rebuild DevContainer, start HostMCP on host OS, verify.

### Scope

- ✅ Edit docker-compose, hostmcp.yaml, CLAUDE.md, settings files, run validation
- ❌ Rebuild DevContainer, start HostMCP, run Docker commands, add user's project files

---

## SandboxMCP Extensions

### Adding Custom Tools

Place Go files in `.sandbox/tools/`. Auto-discovered via `list_tools`, `get_tool_info`, `run_tool`.

**Header format:**
```go
// Short description (first line = description)
//
// Usage:
//   go run .sandbox/tools/my-tool.go [options] <args>
//
// Examples:
//   go run .sandbox/tools/my-tool.go "hello"
//
// --- (stops parsing, content below for human readers only)
//
// 日本語説明（任意）
package main
```

### Adding Custom Scripts

Place shell scripts in `.sandbox/scripts/`. Auto-discovered via `list_scripts`, `get_script_info`, `run_script`.

**Header format:**
```bash
#!/bin/bash
# my-script.sh
# English description
# ---
# Japanese description (optional, not parsed)
```

Since scripts can call other languages, you can build tools in any language.

### Manual Registration

```bash
cd /workspace/.sandbox/sandbox-mcp
make register    # Build and register
make unregister  # Remove
```

### Cost Estimation Workflow

When user asks about usage cost:
1. Run `usage-report.go -json` via `run_tool`
2. Use `WebFetch` to get pricing from `https://docs.anthropic.com/en/docs/about-claude/pricing`
3. Calculate API costs and compare with Pro/Max plan pricing

---

## TDD Workflow

When fixing bugs or implementing features, follow TDD:

1. **Write test first** — Detect the bug or verify expected behavior
2. **Verify test fails** — Proves the bug exists or feature is missing
3. **Implement/Fix** — Write minimum code to make the test pass
4. **Verify test passes** — Confirms the fix/implementation works
5. **Run all tests** — Ensure no regressions (`go test ./...` or equivalent)

### When to Apply

- Bug fixes: Always write test that reproduces the bug first
- New features: Write tests for expected behavior first
- Refactoring: Ensure tests exist before changing code
- Exploratory changes: May write tests after understanding the problem

## Writing Meaningful Tests

Tests must exercise real code paths, not duplicate logic.

**Bad** (duplicates logic):
```go
func TestClientLogLevel(t *testing.T) {
    clientName := "hostmcp-go-client"
    if clientName == "hostmcp-go-client" {
        expected := "DEBUG"  // Same logic as code!
    }
}
```

**Good** (tests actual behavior):
```go
func TestClientLogLevel(t *testing.T) {
    server := NewServer(...)
    ts := httptest.NewServer(server.handler)
    // Send real request, capture logs, verify output
}
```

If unsure whether a test is meaningful, ask the user before writing.

---

## Host OS Test Scripts

Test scripts on the host OS (e.g., `hostmcp/scripts/`) can cause real side effects. Display before execution:

1. **Impact** — Ports, temp files, processes
2. **Risk** — Level and reasoning
3. **Recovery** — Commands to clean up

Display recovery commands in failure summary.

**Examples:**
- `hostmcp/scripts/server-log-test.sh` — `show_prerun_info()` / `print_summary()`
- `.sandbox/scripts/test-advanced-features.sh` — `confirm_section()` per section

---

## Project Structure (Full)

```
/workspace/
├── .sandbox/               # Shared sandbox infrastructure
│   ├── Dockerfile          # Node.js base with limited sudo
│   ├── backups/            # Backup files from sync scripts (gitignored)
│   ├── config/             # Startup configuration
│   │   ├── startup.conf    # Verbosity settings, README URLs, backup retention
│   │   └── sync-ignore     # Patterns to exclude from sync warnings
│   ├── scripts/            # Shared scripts (run: .sandbox/scripts/help.sh)
│   │   ├── help.sh                   # Show script list with descriptions
│   │   ├── _startup_common.sh        # Common functions for startup scripts
│   │   ├── validate-secrets.sh       # 🐳 Secret hiding verification
│   │   ├── compare-secret-config.sh  # DevContainer/CLI config diff check
│   │   ├── check-secret-sync.sh      # Check if Claude deny files are hidden
│   │   ├── sync-secrets.sh           # 🐳 Interactive secret sync tool
│   │   ├── sync-compose-secrets.sh   # 🐳 Sync between DevContainer/CLI compose
│   │   ├── merge-claude-settings.sh  # Merge subproject .claude/settings.json
│   │   ├── init-host-env.sh          # Host-side init: env files + host OS info
│   │   ├── run-all-tests.sh          # Run all test scripts
│   │   └── test-*.sh                 # Test scripts
│   ├── host-tools/            # 🖥️ Host-only tool scripts
│   │   ├── copy-credentials.sh       # Export/Import home directory
│   │   ├── mac-memory.sh             # macOS memory usage check
│   │   ├── xcode-build.sh            # Xcode build (syntax check)
│   │   ├── xcode-test.sh             # Xcode test runner
│   │   └── xcode-archive.sh          # Xcode archive (App Store submission)
│   ├── tools/               # Utility tools
│   │   ├── search-history.go         # Conversation history search
│   │   ├── usage-report.go           # Token usage report
│   │   └── update-check.go           # Template update check
│   └── sandbox-mcp/          # Sandbox-Tools MCP Server (stdio, Go)
│
├── .devcontainer/          # VS Code Dev Container
│   ├── docker-compose.yml  # ⚠️ Secret hiding configuration
│   └── devcontainer.json   # VS Code DevContainer settings
│
├── cli_sandbox/            # CLI environment (backup)
│   ├── claude.sh / gemini.sh / ai_sandbox.sh
│   └── docker-compose.yml  # ⚠️ Secret hiding configuration
│
├── hostmcp/                  # HostMCP MCP Server (Go)
│   ├── cmd/hostmcp/          # Main entry point
│   ├── internal/           # Core implementation
│   └── configs/            # Example configurations
│
└── <your-project>/         # Your application code (add here)
```

**Script icons:** 🐳 = container only, 🖥️ = host OS only

---

## Two Environment Strategy

Two AI Sandbox environments exist:

1. **DevContainer** (`.devcontainer/`) — Primary, VS Code integration
2. **CLI Sandbox** (`cli_sandbox/`) — Backup, terminal-based

**Why both?** If DevContainer config breaks, user can run `./cli_sandbox/claude.sh` to get AI help fixing it.

### Environment Detection

```bash
echo $SANDBOX_ENV
```

| Value | Environment |
|-------|-------------|
| `devcontainer` | DevContainer (VS Code) |
| `cli_claude` | CLI Sandbox (Claude) |
| `cli_gemini` | CLI Sandbox (Gemini) |
| `cli_ai_sandbox` | CLI Sandbox (Shell) |

---

## Multiple DevContainer Instances

Use `COMPOSE_PROJECT_NAME` for isolated instances. Different names create separate volumes (home directory not shared automatically).

Copy home directory between projects:
```bash
./.sandbox/host-tools/copy-credentials.sh --export /path/to/workspace ~/backup
./.sandbox/host-tools/copy-credentials.sh --import ~/backup /path/to/workspace
```

See [docs/reference.md](reference.md) → "Running Multiple DevContainers" for details.

---

## AI Settings Files

### Secret Sync

`check-secret-sync.sh` reads patterns from:
- `.claude/settings.json` — Claude Code
- `.aiexclude` — Gemini Code Assist
- `.geminiignore` — Gemini CLI

`.gitignore` is intentionally **not supported** — it contains many non-secret patterns (`node_modules/`, `dist/`, `*.log`, `.DS_Store`) that would create noise in sync checks. AI exclusion files should explicitly list only secrets, keeping the intent clear and maintenance easy. If a user asks why `.gitignore` isn't checked, explain this design decision.

### `.claude/settings.json` Merge Behavior

| State | What happens |
|-------|--------------|
| File doesn't exist | Created by merging subproject settings |
| Exists, no manual changes | Re-merged from subprojects |
| **Exists with manual changes** | **Not overwritten** |

Source files: `<your-project>/.claude/settings.json` from each subproject directory.

---

## Security Architecture Details

### Secret Hiding (Volume Mounts)

```yaml
# In docker-compose.yml
volumes:
  - /dev/null:/workspace/your-api/.env:ro
tmpfs:
  - /workspace/your-api/secrets:ro
```

AI sees empty files/directories. Real containers access actual secrets.

### HostMCP Security Policy

```yaml
security:
  mode: "moderate"  # strict | moderate | permissive
  allowed_containers:
    - "securenote-*"
  exec_whitelist:
    "securenote-api":
      - "npm test"
      - "npm run lint"
```

### Sandbox Protection

- Non-root user (`node`)
- Limited sudo (only `apt`, `npm`, `pip3`)
- No Docker socket access

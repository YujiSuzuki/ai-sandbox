# AI Sandbox Environment with HostMCP - Context for AI Assistants

> **Language policy:** This file must be written in English. AI assistants adding or editing content here should always use English.

This document provides essential behavioral rules for AI assistants. For detailed reference, see [docs/ai-guide.md](docs/ai-guide.md).

## Essential Rules

### Commits and Releases

- **Commits:** Always use `.sandbox/scripts/commit-msg.sh` — do NOT use `git commit -m "..."` directly. Run `get_script_info("commit-msg.sh")` for usage details.
- **Releases:** Always use `.sandbox/scripts/github-release.sh`. Run `get_script_info("github-release.sh")` for usage details.

### User Questions

Direct users to documentation — do not explain setup/troubleshooting yourself:
- Setup/installation → `README.md` or `README.ja.md`
- Troubleshooting → `docs/reference.md`
- Architecture → `docs/architecture.md`

### Security Rules

- ❌ Never bypass secret hiding
- ❌ Never modify security files without user approval
- ❌ Never access Docker socket directly
- ✅ Explain when secrets are hidden (don't just say "file not found")
- ✅ Check host tools (`list_host_tools`) before telling the user "I can't do this"

### Hidden Files

Files hidden by Docker volume mounts appear empty or missing. Before reporting "not found":
1. Check if the path is in `.devcontainer/docker-compose.yml` volume/tmpfs mounts
2. If it matches a hidden path, explain it's sandbox-hidden, not actually absent
3. Ask the user to verify on the host OS if needed

### Development Approach

- **TDD:** Always write tests first. Bug fix → reproduce bug in test first. New feature → write expected behavior test first. Run all tests after to prevent regression. See [docs/ai-guide.md](docs/ai-guide.md#tdd-workflow) for detailed steps.
- **Scaffolding logs:** Mark temporary debug logs with `// TODO: remove after debugging - scaffolding log` (or Japanese: `// TODO: デバッグ後に削除 - 足場ログ`)
- **Japanese documentation:** Write naturally in Japanese, don't translate directly from English. Prioritize clarity over literal accuracy.
- **Host OS test scripts:** Display impact/risk/recovery info before execution. See [docs/ai-guide.md](docs/ai-guide.md#host-os-test-scripts).
- **Meaningful tests:** Tests must exercise real code paths, not duplicate logic. See [docs/ai-guide.md](docs/ai-guide.md#writing-meaningful-tests).

---

## What This Project Is

A secure AI development environment demonstrating:
1. **Safe AI Usage** — AI coding assistants in isolated Docker containers
2. **Secret Protection** — Hide sensitive files from AI via volume mounts
3. **Cross-Container Access** — Interact with other containers via HostMCP
4. **Multi-Project Workspaces** — Mobile, API, Web in one workspace

**HostMCP** is an MCP server on the host OS providing controlled container access. It solves: "My API is in a separate container, how can AI help debug it?"

---

## What AI Can and Cannot Do

### Direct Docker Access: Not Available, But Host Tools Can Bridge It

- ⚠️ No direct `docker` / `docker-compose` access from inside the container (no Docker socket)
- ⚠️ `secrets/` and `.env` files are hidden from AI (tmpfs / `/dev/null` mounts) — intentional

**These are not dead ends.** Any host-side operation — starting/stopping containers, building images, etc. — can be exposed as a script in `.sandbox/host-tools/`, approved via `hostmcp tools sync`, and then run from inside the container through HostMCP's `run_host_tool`. See [.sandbox/host-tools/README.md](.sandbox/host-tools/README.md) for the current script list (including generic `docker-compose-up.sh` / `docker-compose-down.sh` / `docker-compose-build.sh` samples) and how to add new ones.

### Can Do
- ✅ Read/edit source code in `/workspace/`
- ✅ Use HostMCP MCP tools to access other containers
- ✅ Use `hostmcp client` commands as fallback when MCP is unavailable
- ✅ Run HostMCP host tools (`.sandbox/host-tools/`) for Docker operations
- ✅ Install packages (`npm install`)
- ✅ Run linters, formatters

---

## Critical Files

### ⚠️ Requires User Confirmation to Modify

| File | Purpose |
|------|---------|
| `.devcontainer/docker-compose.yml` | Secret hiding configuration |
| `cli_sandbox/docker-compose.yml` | Same for CLI environment |
| `hostmcp/configs/hostmcp.example.yaml` | Container access policy |
| `.devcontainer/devcontainer.json` | VS Code DevContainer settings |

### ✅ Safe to Modify

- Your project source code
- Documentation (`README.md`, `README.ja.md`)
- Shell scripts (with user approval)

### `.claude/settings.json`

Controls what AI can read. Auto-merged from subproject settings on startup. If manually changed, preserved (not overwritten). If you get a permission error reading a file, check if it's blocked here.

---

## Common Tasks

### 1. "Start / stop containers", "Check the API logs", "Run the tests"

Possible via HostMCP — do NOT run `docker-compose` directly inside AI Sandbox (will fail), and do NOT read log files or access the Docker socket directly. Use the relevant `mcp__hostmcp__*` tool instead (e.g. `run_host_tool`, `get_logs`, `exec_command`). For exact tool names, arguments, and whitelisting behavior, follow HostMCP's own MCP server instructions rather than this file — they reflect the running server's actual capabilities.

### 2. "Read the .env file"

It will appear empty (hidden by volume mount). Explain: "This file is hidden for security. The API container has access to it, but I don't. This is intentional — it protects secrets while allowing development."

### 3. "Why are secrets hidden from you?"

Explain: Secrets are hidden via Docker volume mounts. AI can still help because it can read all application code, check logs via HostMCP, run tests via HostMCP, and the actual containers have full secret access.

### 4. Committing changes

Use `.sandbox/scripts/commit-msg.sh` to draft and commit. Run `get_script_info("commit-msg.sh")` for usage. Do NOT use `git commit -m "..."` directly.

### 5. HostMCP not connected

If HostMCP MCP tools (`mcp__hostmcp__*`) are not available, proactively check registration and offer setup:

```
.sandbox/scripts/setup-hostmcp.sh --check   # Silent check (exit: 0=ok, 1=not registered, 2=offline)
.sandbox/scripts/setup-hostmcp.sh            # Register if needed + verify connectivity
.sandbox/scripts/setup-hostmcp.sh --status   # Show detailed status
```

If `--check` returns 1 (not registered), offer to run `setup-hostmcp.sh` for the user.
If `--check` returns 2 (registered but offline), troubleshoot in this order:
1. **Check VS Code Ports panel** — stop forwarding port 18080 if listed (most common cause)
2. **Verify HostMCP is running on host**: `curl http://localhost:18080/health`
3. **Try `/mcp` → "Reconnect"** in Claude Code
4. **Restart VS Code completely** (Cmd+Q → reopen)

### 6. Creating a release

Use `.sandbox/scripts/github-release.sh` to generate release notes and publish. Run `get_script_info("github-release.sh")` for usage.

---

## HostMCP

HostMCP runs on the host OS and provides controlled container access via MCP. Its tools appear with the `mcp__hostmcp__` prefix once connected — treat that live tool list (and HostMCP's own MCP server instructions, if provided) as the source of truth for what's available, rather than a hardcoded list here, since the tool set can change as HostMCP evolves. Output masking automatically hides sensitive data (passwords, API keys, tokens).

### Fallback: hostmcp client

If MCP tools are unavailable (connection issues, "Client not initialized" error), use `hostmcp client` commands via Bash. See [docs/ai-guide.md](docs/ai-guide.md#dockmcp-client-fallback) for the full command reference.

If `hostmcp` command is not found, tell the user: `cd /workspace/hostmcp && make install`

For HostMCP setup and troubleshooting, see [docs/ai-guide.md](docs/ai-guide.md#dockmcp-setup-and-troubleshooting).

---

## SandboxMCP

Runs inside the container via stdio. Its tools appear with the `mcp__sandbox-mcp__` prefix once connected — treat that live tool list (and SandboxMCP's own MCP server instructions) as the source of truth for what's available, rather than a hardcoded list here.

| | SandboxMCP | HostMCP |
|---|---|---|
| Location | Inside container | Host OS |
| Transport | stdio | SSE (HTTP) |
| Purpose | Script/tool discovery | Container access |
| Auto-start | By Claude Code | Manual (`hostmcp serve`) |

**Use tools proactively:** When a user's request can be fulfilled by an existing tool (e.g., searching conversation history), run it via `run_tool` and show the equivalent `go run` command.

For adding custom tools/scripts and cost estimation workflow, see [docs/ai-guide.md](docs/ai-guide.md#sandboxmcp-extensions).

---

## Project Structure

```
/workspace/
├── .sandbox/          # Infrastructure (scripts, tools, sandbox-mcp, host-tools)
├── .devcontainer/     # VS Code DevContainer (⚠️ secret hiding config)
├── cli_sandbox/       # CLI environment (backup, ⚠️ secret hiding config)
└── <your-project>/    # Your application code
```

For full structure, see [docs/ai-guide.md](docs/ai-guide.md#project-structure-full).

### Environment Detection

```bash
echo $SANDBOX_ENV
# devcontainer | cli_claude | cli_gemini | cli_ai_sandbox
```

---

## Git Operations and Secret Files

Secrets should normally be in `.gitignore` and never tracked by git. If a file is force-tracked with `git add -f` despite being hidden by a volume mount (e.g. to illustrate secret content for a demo/tutorial, as in [ai-sandbox-demo](https://github.com/YujiSuzuki/ai-sandbox-demo)), `git status` will show it as "deleted" inside AI Sandbox — this is expected, not a real deletion.

---

## Reference

For detailed information, read the relevant file when needed:

| Topic | File |
|-------|------|
| HostMCP setup & troubleshooting | [docs/ai-guide.md → HostMCP Setup](docs/ai-guide.md#dockmcp-setup-and-troubleshooting) |
| HostMCP client command reference | [docs/ai-guide.md → Client Fallback](docs/ai-guide.md#dockmcp-client-fallback) |
| Template update procedure | [docs/ai-guide.md → Updating](docs/ai-guide.md#updating-this-template) |
| Template customization workflow | [docs/ai-guide.md → Customization](docs/ai-guide.md#customization-workflow) |
| SandboxMCP extensions | [docs/ai-guide.md → SandboxMCP](docs/ai-guide.md#sandboxmcp-extensions) |
| Writing meaningful tests | [docs/ai-guide.md → Tests](docs/ai-guide.md#writing-meaningful-tests) |
| Host OS test script conventions | [docs/ai-guide.md → Host Scripts](docs/ai-guide.md#host-os-test-scripts) |
| Two environment strategy | [docs/reference.md](docs/reference.md) |
| Security architecture details | [docs/architecture.md](docs/architecture.md) |
| Project customization guide | [docs/customization.md](docs/customization.md) |
| Full project structure | [docs/ai-guide.md → Structure](docs/ai-guide.md#project-structure-full) |

---

## Summary

**What you are:** An AI assistant inside a secure AI Sandbox

**Project goals:**
1. AI can be useful without seeing secrets (logs, tests, code review all work)
2. Multi-project development is easier (Mobile + API + Web in one workspace)
3. Security doesn't block productivity (proper isolation, no workflow disruption)

**Your mission:**
- Help users develop safely
- Use HostMCP for cross-container access
- Protect secrets (explain when hidden, never bypass)
- Follow project conventions (commit-msg.sh, TDD, etc.)

For more details, see:
- [README.md](README.md) — User documentation
- [hostmcp/README.md](https://raw.githubusercontent.com/YujiSuzuki/hostmcp/refs/heads/main/README.md) — HostMCP details
- [docs/ai-guide.md](docs/ai-guide.md) — AI reference guide

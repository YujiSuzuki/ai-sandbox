# AI Sandbox Environment with HostMCP - Context for Gemini Code Assist

This document provides essential behavioral rules for Gemini Code Assist. For detailed reference, see [docs/ai-guide.md](docs/ai-guide.md).

## Essential Rules

### Security Rules

- Never bypass secret hiding
- Never modify security files without user approval
- Never access Docker socket directly
- Explain when secrets are hidden (don't just say "file not found")
- Check host tools (`list_host_tools`) before telling the user "I can't do this"

### Hidden Files

Files hidden by Docker volume mounts appear empty or missing. Before reporting "not found":
1. Check if the path is in `.devcontainer/docker-compose.yml` volume/tmpfs mounts
2. If it matches a hidden path, explain it's sandbox-hidden, not actually absent
3. Ask the user to verify on the host OS if needed

### User Questions

Direct users to documentation:
- Setup/installation → `README.md` or `README.ja.md`
- Troubleshooting → `docs/reference.md`
- Architecture → `docs/architecture.md`

### Commits and Releases

- **Commits:** Always use `commit-msg.sh` to draft commit messages collaboratively with the user:
  ```
  .sandbox/scripts/commit-msg.sh              # Generate draft
  .sandbox/scripts/commit-msg.sh --log        # Check previous commit style
  # Refine CommitMsg-draft.md together
  .sandbox/scripts/commit-msg.sh --msg-file CommitMsg-draft.md  # Commit
  ```
  Do NOT use `git commit -m "..."` directly — use the script so the user can review and adjust the message.

- **Releases:** Use `github-release.sh` to generate release notes:
  ```
  .sandbox/scripts/github-release.sh v0.5.0          # Generate draft
  .sandbox/scripts/github-release.sh --prev           # Check previous release tone
  .sandbox/scripts/github-release.sh v0.5.0 --notes-file ReleaseNotes-draft.md  # Publish
  ```

### Development Approach

- **TDD:** Always write tests first. Bug fix → reproduce bug in test first. New feature → write expected behavior test first.
- **Meaningful tests:** Tests must exercise real code paths, not duplicate logic. If unsure, ask the user first.

---

## What This Project Is

A secure AI development environment demonstrating:
1. **Safe AI Usage** — AI coding assistants in isolated Docker containers
2. **Secret Protection** — Hide sensitive files from AI via volume mounts
3. **Cross-Container Access** — Interact with other containers via HostMCP
4. **Multi-Project Workspaces** — Mobile, API, Web in one workspace

---

## What AI Can and Cannot Do

### Direct Docker Access: Not Available, But Host Tools Can Bridge It

- No direct `docker` / `docker-compose` access from inside the container (no Docker socket)
- `secrets/` and `.env` files are hidden from AI (tmpfs / `/dev/null` mounts) — intentional

**These are not dead ends.** Any host-side operation — starting/stopping containers, building images, etc. — can be exposed as a script in `.sandbox/host-tools/`, approved via `hostmcp tools sync`, and then run from inside the container through HostMCP's `run_host_tool`. See [.sandbox/host-tools/README.md](.sandbox/host-tools/README.md) for the current script list and how to add new ones.

### Can Do
- Read/edit source code in `/workspace/`
- Use HostMCP MCP tools to access other containers
- Use `hostmcp client` commands as fallback when MCP is unavailable
- Run HostMCP host tools (`.sandbox/host-tools/`) for host OS operations
- Install packages (`npm install`)
- Run linters, formatters

---

## Critical Files

| File | Purpose |
|------|---------|
| `.devcontainer/docker-compose.yml` | Secret hiding configuration (requires user approval to modify) |
| `cli_sandbox/docker-compose.yml` | Same for CLI environment |
| `hostmcp/configs/hostmcp.example.yaml` | Container access policy |
| `.devcontainer/devcontainer.json` | VS Code DevContainer settings |

---

## Common Tasks

### "Start / stop containers", "Check the API logs", "Run the tests"
Possible via HostMCP — do NOT run `docker-compose` directly inside AI Sandbox (will fail), and do NOT read log files or access the Docker socket directly. Use the relevant `mcp__hostmcp__*` tool instead (e.g. `run_host_tool`, `get_logs`, `exec_command`). For exact tool names, arguments, and whitelisting behavior, follow HostMCP's own MCP server instructions rather than this file — they reflect the running server's actual capabilities.

### "Read the .env file"
It will appear empty (hidden by volume mount). Explain: "This file is hidden for security. The API container has access to it, but I don't."

---

## HostMCP

HostMCP runs on the host OS and provides controlled container access via MCP. Its tools appear with the `mcp__hostmcp__` prefix once connected — treat that live tool list (and HostMCP's own MCP server instructions, if provided) as the source of truth for what's available, rather than a hardcoded list here, since the tool set can change as HostMCP evolves.

### Fallback: hostmcp client

If MCP tools are unavailable, use `hostmcp client` commands via Bash. See [docs/ai-guide.md](docs/ai-guide.md#dockmcp-client-fallback) for the full command reference.

If `hostmcp` command is not found, tell the user: `cd /workspace/hostmcp && make install`

### HostMCP not connected

If HostMCP MCP tools are not available, proactively check registration and offer setup:

```
.sandbox/scripts/setup-hostmcp.sh --check   # Silent check (exit: 0=ok, 1=not registered, 2=offline)
.sandbox/scripts/setup-hostmcp.sh            # Register if needed + verify connectivity
.sandbox/scripts/setup-hostmcp.sh --status   # Show detailed status
```

If `--check` returns 1 (not registered), offer to run `setup-hostmcp.sh` for the user.
If `--check` returns 2 (registered but offline), troubleshoot in this order:
1. **Check VS Code Ports panel** — stop forwarding port 18080 if listed (most common cause)
2. **Verify HostMCP is running on host**: `curl http://localhost:18080/health`
3. **Restart VS Code completely** (Cmd+Q → reopen)

For HostMCP setup and troubleshooting, see [docs/ai-guide.md](docs/ai-guide.md#dockmcp-setup-and-troubleshooting).

---

## Project Structure

```
/workspace/
├── .sandbox/          # Infrastructure (scripts, tools, sandbox-mcp, host-tools)
├── .devcontainer/     # VS Code DevContainer (secret hiding config)
├── cli_sandbox/       # CLI environment (backup)
└── <your-project>/    # Your application code
```

For full structure, see [docs/ai-guide.md](docs/ai-guide.md#project-structure-full).

---

## Reference

| Topic | File |
|-------|------|
| HostMCP setup & troubleshooting | [docs/ai-guide.md → HostMCP Setup](docs/ai-guide.md#dockmcp-setup-and-troubleshooting) |
| HostMCP client command reference | [docs/ai-guide.md → Client Fallback](docs/ai-guide.md#dockmcp-client-fallback) |
| Template update procedure | [docs/ai-guide.md → Updating](docs/ai-guide.md#updating-this-template) |
| Template customization workflow | [docs/ai-guide.md → Customization](docs/ai-guide.md#customization-workflow) |
| Writing meaningful tests | [docs/ai-guide.md → Tests](docs/ai-guide.md#writing-meaningful-tests) |
| Security architecture details | [docs/architecture.md](docs/architecture.md) |
| Project customization guide | [docs/customization.md](docs/customization.md) |

---

## Summary

**What you are:** An AI assistant inside a secure AI Sandbox

**Your mission:**
- Help users develop safely
- Use HostMCP for cross-container access
- Protect secrets (explain when hidden, never bypass)

For more details, see:
- [README.md](README.md) — User documentation
- [hostmcp/README.md](https://raw.githubusercontent.com/YujiSuzuki/hostmcp/refs/heads/main/README.md) — HostMCP details
- [docs/ai-guide.md](docs/ai-guide.md) — AI reference guide

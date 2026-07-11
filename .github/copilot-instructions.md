# AI Sandbox Environment - GitHub Copilot Instructions

This document provides essential behavioral rules for GitHub Copilot. For detailed reference, see [../docs/ai-guide.md](../docs/ai-guide.md).

## Security Constraints

### Hidden Files
Some files appear empty due to security measures (Docker volume mounts). This is intentional — application containers have access to real secrets, but AI assistants don't.

**Important:** If a file appears empty or missing, check whether its path is listed in the volume/tmpfs mounts in `.devcontainer/docker-compose.yml` or `cli_sandbox/docker-compose.yml`. If so, the file is sandbox-hidden. Ask the user to verify on the host OS.

### No Docker Access
You cannot run `docker` or `docker-compose` commands. Tell users to run these on the host OS.

## What AI Can and Cannot Do

### Direct Docker Access: Not Available, But Host Tools Can Bridge It
- No direct `docker` / `docker-compose` access from inside the container (no Docker socket)
- `secrets/` and `.env` files are hidden from AI (tmpfs / `/dev/null` mounts) — intentional
- Any host-side operation can still be exposed as a script in `.sandbox/host-tools/`, approved via `hostmcp tools sync`, and run from inside the container through HostMCP's `run_host_tool`

### Can Do
- Read/edit source code in `/workspace/`
- Use HostMCP MCP tools to access other containers
- Use `hostmcp client` commands as fallback when MCP is unavailable

## Project Structure

```
/workspace/
├── .sandbox/          # Infrastructure (scripts, tools, sandbox-mcp, host-tools)
├── .devcontainer/     # VS Code DevContainer (secret hiding config)
├── cli_sandbox/       # CLI environment (backup)
└── <your-project>/    # Your application code
```

## Cross-Container Access (HostMCP)

HostMCP's tools appear with the `mcp__hostmcp__` prefix once connected — treat that live tool list (and HostMCP's own MCP server instructions, if provided) as the source of truth for what's available, rather than a hardcoded list here, since the tool set can change as HostMCP evolves.

### Fallback: hostmcp client

If MCP tools are unavailable, use `hostmcp client` commands via Bash. See [../docs/ai-guide.md](../docs/ai-guide.md#dockmcp-client-fallback) for the full command reference.

If `hostmcp` not found, tell user: `cd /workspace/hostmcp && make install`

For troubleshooting, see [../docs/ai-guide.md](../docs/ai-guide.md#dockmcp-setup-and-troubleshooting).

## Critical Files

- `.devcontainer/docker-compose.yml` — Secret hiding config (requires user approval to modify)
- `cli_sandbox/docker-compose.yml` — CLI secret hiding (must match above)
- `hostmcp/configs/hostmcp.example.yaml` — Container access policy

## Development Approach: TDD

1. **Write test first** — Before implementing, write a test that detects the bug or verifies expected behavior
2. **Verify test fails** — Confirm the test fails (proves the bug exists)
3. **Implement/Fix** — Write the code to make the test pass
4. **Verify test passes** — Confirm the fix works
5. **Run all tests** — Ensure no regressions

Tests must call actual code, not duplicate logic. If unsure whether a test is meaningful, ask the user first.

## Commits and Releases

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

## Guidelines

1. Never suggest bypassing security configurations
2. Explain when files appear empty due to security
3. Guide users to run Docker commands on host OS
4. Use HostMCP tools for cross-container operations
5. Follow existing code patterns in the project

## Reference

For detailed information, see [../docs/ai-guide.md](../docs/ai-guide.md).

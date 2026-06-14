# CLI Sandbox

[日本語](README.ja.md)

An alternative environment for running AI coding assistants from the terminal.

For basic usage and why this environment exists (as a recovery tool when DevContainer breaks), see the [root README.md](../README.md#two-environments).

## File Structure

| File | Purpose |
|------|---------|
| `claude.sh` | Launch Claude Code inside the container |
| `gemini.sh` | Launch Gemini CLI inside the container |
| `ai_sandbox.sh` | Launch an interactive shell without AI (for debugging/investigation) |
| `_common.sh` | Common startup logic and validation shared by the above scripts |
| `docker-compose.yml` | Container definition (includes secret hiding and resource limits) |
| `.env.example` | Environment variable template |
| `.env` | Environment variable settings (in `.gitignore`) |
| `build.sh` | Build the image |
| `build-no-cache.sh` | Build the image without cache |
| `test-sudo-security.sh` | Validation script to verify sudo restrictions are working |
| `.dockerignore` | Build exclusion targets |

## Startup Flow

Each script (`claude.sh`, `gemini.sh`, `ai_sandbox.sh`) sources `_common.sh` for shared processing.

```
Script starts
  │
  ├─ Set required variables (SCRIPT_NAME, COMPOSE_PROJECT_NAME, SANDBOX_ENV)
  ├─ Source _common.sh
  │    ├─ Validate required variables
  │    ├─ Verify execution directory (must be run from parent of cli_sandbox)
  │    └─ Load .env.sandbox, cli_sandbox/.env
  │
  ├─ run_startup_scripts()
  │    ├─ merge-claude-settings.sh    … Merge Claude settings
  │    ├─ security-reminder.sh        … Detect AI config changes
  │    ├─ compare-secret-config.sh    … Check for differences between DevContainer and CLI configs
  │    ├─ validate-secrets.sh         … Verify secret hiding is working
  │    └─ check-secret-sync.sh        … Check sync with .claude/settings.json
  │
  ├─ [Validation passes] → Launch AI tool (claude / gemini / bash)
  └─ [Validation fails] → confirm_continue_after_failure()
       ├─ [y] Launch shell only (AI is not started)
       └─ [N] Exit
```

When validation fails, the AI tool is intentionally not launched. You enter a shell only, fix the configuration, and try again.

## Environment Variables

### Settings in .env.example

```bash
TERM=xterm-256color       # Terminal type
COLORTERM=truecolor       # Color output
SANDBOX_MEMORY_LIMIT=4gb  # Container memory limit
```

Note: `COMPOSE_PROJECT_NAME` has default values set within each startup script (`claude.sh` → `cli-claude`, `gemini.sh` → `cli-gemini`, etc.). Setting it in `.env` will override these defaults and apply the same project name across all scripts.

### SANDBOX_ENV

A variable to identify the current environment inside the container. Different values are set per script.

| Script | SANDBOX_ENV value |
|--------|-------------------|
| `claude.sh` | `cli_claude` |
| `gemini.sh` | `cli_gemini` |
| `ai_sandbox.sh` | `cli_ai_sandbox` |

## docker-compose.yml Configuration

### Secret Hiding

Must be kept in sync with the DevContainer (`.devcontainer/docker-compose.yml`). If they differ, `compare-secret-config.sh` will warn at startup.

```yaml
volumes:
  # Per-file hiding: mount to /dev/null → appears as empty file
  - /dev/null:/workspace/your-api/.env:ro

tmpfs:
  # Per-directory hiding: tmpfs makes it an empty directory
  - /workspace/your-api/secrets:ro
```

For adding and syncing secret settings, see the [root README.md "Adapting to Your Own Project"](../README.md#adapting-to-your-own-project).

### Resource Limits

Limits are set to prevent the container from exhausting host resources.

```yaml
deploy:
  resources:
    limits:
      memory: ${SANDBOX_MEMORY_LIMIT:-4gb}
      cpus: "${SANDBOX_CPU_LIMIT:-2}"
```

You can change `SANDBOX_MEMORY_LIMIT` and `SANDBOX_CPU_LIMIT` in `.env`.

### Home Directory Persistence

Credentials (`.claude.json`, `.claude/`, etc.) are stored in a named volume `cli-sandbox-home`. Different `COMPOSE_PROJECT_NAME` values result in different volumes, so the home directory is not shared between tools.

To copy between volumes, use `.sandbox/host-tools/copy-credentials.sh`. See [docs/reference.md](../docs/reference.md#home-directory-exportimport) for details.

## Security Testing

A script to verify that sudo restrictions are working correctly inside the container.

```bash
# Enter the container
./cli_sandbox/ai_sandbox.sh bash

# Run inside the container
cd ./cli_sandbox
./test-sudo-security.sh
```

Test coverage:
- **Commands that should be allowed**: `apt-get`, `apt`, `dpkg`, `pip3`, `npm` (should work without password)
- **Commands that should be denied**: `rm`, `chmod`, `chown`, `su`, `bash`, `cat`, `mv`, `cp` (should be blocked)

Running this on the host OS will produce an error (container-only).

## Differences from DevContainer

| Item | DevContainer | CLI Sandbox |
|------|-------------|-------------|
| Launch method | From VS Code | From terminal via `./cli_sandbox/*.sh` |
| IDE integration | VS Code extensions available | None |
| Go environment | Added via devcontainer.json features | None (install manually if needed) |
| Project name | Set in `.devcontainer/.env` | Per-script defaults or `cli_sandbox/.env` |
| Use case | Day-to-day development | Recovery, alternative, terminal work |

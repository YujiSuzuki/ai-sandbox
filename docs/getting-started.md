# Getting Started Guide

[日本語版はこちら](getting-started.ja.md)

A step-by-step walkthrough from zero to a working AI Sandbox + HostMCP setup.

[← Back to README](../README.md)

---

## Who This Guide Is For

- You're familiar with Docker and VS Code but new to this project
- You want to understand how AI Sandbox and HostMCP fit together
- You want to get things running first, then explore

**Estimated time:** 15–30 minutes (5 minutes without HostMCP)

---

## Overview

Setup has three stages. Go as far as you need.

```
Steps 1–3: Get AI Sandbox running (required)
    ↓
Steps 4–6: Connect HostMCP (recommended)
    ↓
Steps 7–8: Try the demo apps (optional)
```

| Stage | What You Get |
|-------|-------------|
| **Sandbox only** | AI can read/write code. Secret files are hidden |
| **+ HostMCP** | AI can also check logs and run tests in other containers |
| **+ Demo apps** | Try all features with the included demo |

---

## Step 1: Check Prerequisites

Make sure the following are installed.

| Tool | Verify | Install |
|------|--------|---------|
| **Docker** | `docker --version` | [Docker Desktop](https://www.docker.com/products/docker-desktop/) or [OrbStack](https://orbstack.dev/) |
| **VS Code** | `code --version` | [Visual Studio Code](https://code.visualstudio.com/) |
| **Dev Containers extension** | Check in VS Code extensions | [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) |

If you plan to use HostMCP, you'll also need:

| Tool | Verify | Install |
|------|--------|---------|
| **Go** (1.25+) | `go version` | [go.dev](https://go.dev/dl/) |

> [!TIP]
> **No Go on host?** No problem — `install-hostmcp.sh` (Step 4) offers to download a prebuilt `hostmcp` binary automatically, no Go required.

### Expected Result

```bash
$ docker --version
Docker version 27.x.x, build xxxxxxx   # Any version shown = OK

$ code --version
1.9x.x                                  # Any version shown = OK
```

Also confirm Docker Desktop (or OrbStack) is **running**.

---

## Step 2: Get the Repository

```bash
# Option A: From template (click "Use this template" on GitHub, then clone)
git clone https://github.com/your-username/your-new-repo.git
cd your-new-repo

# Option B: Direct clone
git clone https://github.com/YujiSuzuki/ai-sandbox.git
cd ai-sandbox
```

> [!TIP]
> For more options, see [Customization Guide](customization.md).

### Expected Result

```
your-repo/
├── .devcontainer/
├── .sandbox/
└── README.md
```

If you see this directory structure, you're good.

---

## Step 3: Start the DevContainer

```bash
code .
```

Once VS Code opens:

1. A notification **"Reopen in Container"** appears in the bottom right → click it
2. If no notification appears → `Cmd+Shift+P` (macOS) / `Ctrl+Shift+P` (Windows/Linux) → **"Dev Containers: Reopen in Container"**

The first launch builds the container, which takes a few minutes.

### What Happens on First Startup

During DevContainer startup, these processes run automatically:

1. Docker image build (first time only; cached on subsequent starts)
2. Container startup
3. AI settings merge (consolidates `.claude/settings.json` from subprojects)
4. Secret config validation (checks `docker-compose.yml` settings are correct)
5. SandboxMCP build and registration (makes `.sandbox/` tools available to AI)
6. Template update check

Validation results appear in the VS Code terminal. If you see `✓` (success) for each check, everything is fine.

### Expected Result

- VS Code shows **"Dev Container: AI Sandbox"** in the bottom left
- A terminal is open at `/workspace`
- `ls` shows the project files

Secret files configured in `docker-compose.yml` appear empty inside the sandbox (hidden by volume mount). For a hands-on example, see [ai-sandbox-demo](https://github.com/YujiSuzuki/ai-sandbox-demo).

**At this point, the AI Sandbox is ready to use.** Launch Claude Code or Gemini Code Assist and try reading/writing code.

If you don't need HostMCP (access to other containers), skip ahead to [Next Steps](#next-steps).

> [!TIP]
> **Not using VS Code?** You can also use the CLI Sandbox (`cli_sandbox/`) for terminal-only workflows. Run `./cli_sandbox/claude.sh` for Claude Code or `./cli_sandbox/gemini.sh` for Gemini CLI. See [Reference](reference.md) for details.

---

## Step 4: Install HostMCP (on Host OS)

> [!IMPORTANT]
> From here, work on your **host OS** (outside the DevContainer). Open a separate terminal window — not the VS Code integrated terminal.

Run the install script and follow its prompts. It detects whether `hostmcp` is installed (and offers to update it if a newer release exists), offers to install it (`go install`, or a prebuilt binary download if you don't have Go), and generates the HostMCP config:

```bash
.sandbox/host-setup/install-hostmcp.sh
```

> [!TIP]
> For manual installation or other install options (no Go required), see the [HostMCP README](https://github.com/YujiSuzuki/hostmcp#readme).

### Expected Result

```bash
$ hostmcp version
x.x.x    # Version shown = OK
```

---

## Step 5: Start the HostMCP Server (on Host OS)

Still on the host OS (this is the command `install-hostmcp.sh` showed you at the end of Step 4):

```bash
hostmcp serve --workspace /path/to/your-repo
```

Adding `--sync` enables host tools — scripts in `.sandbox/host-tools/` (for building, starting, and stopping demo apps, etc.) that AI can execute via HostMCP. The first time AI tries to use a host tool, you'll be prompted to approve it.

```bash
hostmcp serve --workspace /path/to/your-repo --sync
```

### Expected Result

```
HostMCP server started on :18080
Security mode: moderate
Allowed containers: securenote-*, demo-*
```

Keep this terminal open (the server keeps running).

### Verify Connection (from another host terminal)

```bash
curl http://localhost:18080/health
# → 200 OK means success
```

---

## Step 6: Connect from AI Sandbox to HostMCP

Switch back to the **VS Code DevContainer terminal**:

```bash
# For Claude Code
claude mcp add --transport sse --scope user hostmcp http://host.docker.internal:18080/sse

# For Gemini CLI
gemini mcp add --transport sse hostmcp http://host.docker.internal:18080/sse
```

After registering, activate the connection:

- **Claude Code:** Type `/mcp` → select "Reconnect"
- **Alternatively:** Restart VS Code entirely (`Cmd+Q` / `Alt+F4` → reopen)

### Expected Result

Running `/mcp` in Claude Code shows `hostmcp` as **connected**:

```
  hostmcp
  ✔ connected
  17 tools
```

Try asking the AI:

```
"Show me the list of containers"
```

> [!NOTE]
> If you haven't started the demo apps yet, the container list may be empty. That's fine — the connection itself is confirmed.

### If It Doesn't Work

- See [Troubleshooting](reference.md#troubleshooting)
- Verify the HostMCP server is running (Step 5)
- Check if port 18080 is being forwarded in VS Code's Ports panel — if so, stop it

---

## Step 7: Try the Demo Apps (Optional)

Now try the demo apps ([ai-sandbox-demo](https://github.com/YujiSuzuki/ai-sandbox-demo)) to experience, hands-on, that secrets really are inaccessible to the AI, and that the Sandbox can operate and check logs on other containers outside itself.

See the [ai-sandbox-demo README](https://github.com/YujiSuzuki/ai-sandbox-demo) for setup instructions, and the [Hands-on Guide](https://github.com/YujiSuzuki/ai-sandbox-demo/blob/main/hands-on.md) for example prompts and exercises once the demo apps are running.

---

## Step 8: Talk to the AI

In the AI Sandbox, try these prompts with Claude Code (or Gemini):

### Basic Operations

```
"What scripts are available?"
→ Script list from .sandbox/ displayed via SandboxMCP
```

### Security Verification

```
"Check if any secret files are accessible"
→ AI runs validation script and reports the hiding status
```

> For prompts that exercise HostMCP against the demo apps (log viewing, running tests, container inspect/stats on `securenote-api`), see the [ai-sandbox-demo Hands-on Guide](https://github.com/YujiSuzuki/ai-sandbox-demo/blob/main/hands-on.md).

---

## Next Steps

With setup complete, continue based on what you want to do.

| Goal | Document |
|------|----------|
| Explore security features hands-on | [ai-sandbox-demo Hands-on Guide](https://github.com/YujiSuzuki/ai-sandbox-demo/blob/main/hands-on.md) |
| Use with your own project | [Customization Guide](customization.md) |
| Understand the architecture | [Architecture Details](architecture.md) |
| Compare with other tools | [Comparison with Existing Solutions](comparison.md) |
| Add network restrictions | [Network Restrictions](network-firewall.md) |

---

## Common Issues and Fixes

### "Reopen in Container" doesn't appear

- Verify the Dev Containers extension is installed
- Run `Cmd+Shift+P` → "Dev Containers: Reopen in Container" manually

### First build is slow

- Docker image download and build can take 3–5 minutes
- Subsequent starts use the cache and are much faster

### Can't connect to HostMCP

1. Verify the HostMCP server is running: `curl http://localhost:18080/health`
2. Check if port 18080 is being forwarded in VS Code's Ports panel — if so, stop it
3. Try `/mcp` → "Reconnect"
4. Restart VS Code completely (`Cmd+Q` → reopen)

For more details, see [Troubleshooting](reference.md#troubleshooting).

### Demo app containers not found

See the [ai-sandbox-demo Hands-on Guide's Troubleshooting section](https://github.com/YujiSuzuki/ai-sandbox-demo/blob/main/hands-on.md#troubleshooting).

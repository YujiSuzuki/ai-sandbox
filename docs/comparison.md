# Relationship to Existing Solutions

[日本語版はこちら](comparison.ja.md)

How AI Sandbox + HostMCP compares to other AI security tools, and why they work well together.

[← Back to README](../README.md)

---

## Existing Tools

### Claude Code Sandboxing

[Claude Code Sandboxing](https://code.claude.com/docs/en/sandboxing) uses OS-level primitives (Seatbelt on macOS, bubblewrap on Linux) to restrict filesystem writes and network access. You can also add `Read` deny rules in permissions to block AI from reading specific files.

**Strengths:**
- OS-level execution restrictions (no extra setup on macOS; Linux/WSL2 requires installing `bubblewrap` and `socat`)
- Read deny rules to block access to specific files
- Reduces permission fatigue

**Gaps this project fills:**
- Deny rules are application-level — they depend on correct configuration and the AI tool respecting them
- Deny rules [don't traverse parent directories](https://github.com/anthropics/claude-code/issues/12962), so in a monorepo or multi-project workspace, settings in one project won't protect secrets in a sibling project — AI Sandbox sidesteps this at the file level: each project's secret file is individually hidden from the AI's filesystem via a volume mount, regardless of directory nesting, so there's no rule to traverse in the first place; see [Secret Protection](../README.md#secret-protection). For the separate concern of configuring AI's access to another project/client's *containers* (not files), HostMCP handles its own scoping via per-instance separation and `allowed_containers`/`max_depth`; see [Multi-Client / Multi-Workspace](../README.md#multi-client--multi-workspace)
- Docker commands require direct access to the Docker socket, which is structurally incompatible with the sandbox. The [official troubleshooting docs](https://code.claude.com/docs/en/sandboxing#troubleshooting) themselves recommend adding `docker *` to `excludedCommands`, so Docker operations get no sandbox protection at all and run with unrestricted host privileges

### Docker AI Sandboxes

[Docker AI Sandboxes](https://docs.docker.com/ai/sandboxes) run AI agents in isolated microVMs with their own Docker daemon. The agent can't touch your host system.

**Strengths:**
- Strong isolation via microVMs
- Full autonomy for AI agents within the sandbox
- Each sandbox has its own Docker daemon

**Gaps this project fills:**
- Syncs your entire workspace directory into the microVM with no mechanism to exclude specific files — `.env` files are visible inside. This isn't an implementation oversight, but a difference in design goals: Docker AI Sandboxes is built to **protect the host** from the AI agent, not to **hide secrets** from the AI
- Fully isolated — each sandbox can't communicate with other containers, making cross-container debugging impossible

### Docker MCP Toolkit

[Docker MCP Toolkit](https://www.docker.com/blog/mcp-toolkit-mcp-servers-that-just-work/) provides 200+ containerized MCP servers with built-in isolation and secret management.

**Strengths:**
- Large catalog of pre-built MCP servers
- Built-in secret management for MCP server configurations

**Gaps this project fills:**
- Focuses on MCP server isolation, not on hiding project-level secrets from AI
- Doesn't address the problem of `.env` files and private keys in your source tree

---

## What This Project Adds

AI Sandbox + HostMCP fills two specific gaps that the tools above don't fully address:

### Gap 1: Filesystem-level secret hiding

Instead of blocking secret access with rules (which can be misconfigured or bypassed), this project makes secrets **physically absent** from AI's filesystem using Docker volume mounts:

```yaml
volumes:
  - /dev/null:/workspace/my-app/.env:ro     # AI sees an empty file
tmpfs:
  - /workspace/my-app/secrets:ro            # AI sees an empty directory
```

The secrets don't exist in AI's world — not blocked by a rule, not filtered by a config, just not there. Meanwhile, your app containers mount the real files normally.

To catch misconfigurations, the sandbox runs **startup validation** that checks whether your AI tool's deny rules and your `docker-compose.yml` volume mounts are in sync. If a secret file is blocked in one but not the other, you get a warning before AI sees it. A separate check also detects secret-like files that aren't hidden by `docker-compose.yml` (files covered only by an AI tool's deny rules are still flagged, since that only blocks reads and doesn't actually hide the file), every time an AI session starts — catching configuration gaps early for files created during day-to-day development. Rather than auto-remediating, the AI asks you how to handle each one: whether it's a secret that needs hiding, or fine to leave as is.

### Gap 2: Controlled cross-container access

HostMCP acts as a gateway between the AI sandbox and other Docker containers, with security policy enforcement:

- AI can read logs, run whitelisted commands, and inspect containers
- AI cannot access blocked paths or run arbitrary commands; starting/stopping containers is disabled by default and only works if explicitly enabled in the config
- Sensitive data (passwords, API keys, tokens) is automatically masked in output
- HostMCP itself binds to loopback (127.0.0.1) by default, so it isn't reachable from other machines on the network out of the box

---

## Using Them Together

These tools fall into two layers of a different nature, and separating them clarifies how they relate.

### Isolation boundaries: pick one based on your threat model

Docker AI Sandboxes and AI Sandbox (this project) both answer the same question — where do you draw the boundary around the AI agent's entire runtime environment? The former uses a microVM, the latter a container plus volume-mount secret removal. Because they play the same role, they aren't meant to be stacked; you pick one based on your threat model.

Claude Code Sandbox targets something narrower — it restricts Bash command execution at the OS level — so it can be nested inside whichever outer boundary you chose. When nesting it inside an unprivileged container such as AI Sandbox's, though, the [official docs](https://code.claude.com/docs/en/sandboxing#troubleshooting) note that bubblewrap can't mount a fresh `/proc` and `enableWeakerNestedSandbox` becomes necessary, in which case the nested sandbox's process isolation ends up depending on the outer container boundary instead (permission deny rules are unaffected and keep working). So nesting it inside AI Sandbox adds some protection, but not the "maximum protection" the earlier wording implied.

| Isolation boundary options | What It Does |
|----------------------------|--------------|
| Claude Code Sandbox | Restricts Bash command execution at the OS level (can nest inside another boundary, with the caveat above) |
| Docker AI Sandboxes | Isolates the entire AI agent in a microVM |
| **AI Sandbox** (this project) | Container isolation plus volume-mount removal of secrets from AI's filesystem |

### Where this project sits among isolation technologies

Cloud-managed AI agent services that need strong isolation actually rely on technologies like these:

- **AWS Bedrock AgentCore Code Interpreter**: spins up a dedicated Firecracker microVM per session — a one-session-one-microVM model ([AWS docs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/built-in-tools-how-it-works.html))
- **Google Cloud GKE Agent Sandbox**: kernel-level isolation via gVisor ([Google Cloud docs](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/machine-learning/agent-sandbox))

> **Note:** the AWS/Google services above are cloud APIs / managed services, not local-dev-environment alternatives to this project. They're cited only to show that gVisor/Firecracker are real, production-proven isolation technologies. Product-level comparisons like "can it exclude specific files from sync" or "can it talk to other containers" — the kind we did for [Docker AI Sandboxes](#docker-ai-sandboxes) — don't apply to these cloud services in the first place; they aren't in the same product category.

Firecracker creates a VM: it spins up one lightweight virtual machine (a microVM) and runs the code inside it. gVisor works differently — it doesn't create a VM at all. A userspace program called "Sentry" intercepts the application's system calls and reimplements kernel functionality itself; the process keeps running as an ordinary process on the host. Google's own description, "VM-grade isolation," is about the resulting strength, not the mechanism — worth keeping distinct.

| Approach | Creates a VM? | Runs on |
|---|---|---|
| Firecracker (AWS) | Yes (microVM) | Linux (requires KVM) |
| gVisor (Google) | No (intercepts syscalls) | Linux (as a Docker runtime) |

### Using these locally

Both are OSS, so neither is cloud-exclusive — see above. But how easily each one fits into a local dev environment differs:

- **gVisor**: locally, this is just switching Docker's runtime to `runsc`. That hardens process isolation, an axis orthogonal to this project's volume-mount secret hiding ([Gap 1](#gap-1-filesystem-level-secret-hiding)) — so it layers on top rather than replacing it. Whether it's actually usable on your machine can be checked with [`check-gvisor.sh`](../.sandbox/host-tools/check-gvisor.sh), a read-only script that runs on the host OS via HostMCP.
- **Firecracker**: also runnable locally, but needs Linux + KVM plus an integration layer like `firecracker-containerd` — not a simple runtime swap. In practice this means picking a different isolation boundary altogether, closer to the [Docker AI Sandboxes](#docker-ai-sandboxes) product category than to a drop-in runtime change.

Whether kernel exploits themselves belong in your threat model also depends on your development machine's OS:

- **Using Docker Desktop / OrbStack / etc. on macOS**: this is easy to overlook, but the container is actually running inside a disposable, lightweight Linux VM, separate from macOS itself. A successful kernel exploit inside the container only takes over that VM — reaching macOS itself (the Darwin kernel) requires a second, separate exploit against the hypervisor (a VM escape). In other words, a Mac development machine already has one extra layer of isolation working in its favor, independent of anything this project configures, purely because of how Docker Desktop/OrbStack itself is built. **So on a Mac dev machine, there's generally little need to add gVisor on top.** (On OrbStack specifically, it currently wouldn't help anyway: `runsc` crashes on startup because OrbStack's VM symlinks `/tmp` to `/private/tmp` and gVisor's chroot safety check rejects that — see [orbstack/orbstack#2362](https://github.com/orbstack/orbstack/issues/2362).)
- **Running Docker directly on Linux**: a kernel exploit inside a container is an attack on the host OS's kernel itself — nothing else is in the way. This project doesn't pin a runtime in `docker-compose.yml`, so it stays on Docker's default `runc`, which doesn't add a layer that stops that path. **So on Linux dev machines, it's worth considering switching the Docker runtime to `runsc` (gVisor).** As above, this is an orthogonal, additive hardening step relative to secret hiding ([Gap 1](#gap-1-filesystem-level-secret-hiding)); whether it's actually usable can be checked with [`check-gvisor.sh`](../.sandbox/host-tools/check-gvisor.sh).

Given that difference, how much priority you give to adding gVisor-based isolation on top reasonably differs between a Linux and a Mac development machine.

### Permission layer: composes independently

HostMCP's (this project) controlled cross-container access and Managed Settings deny rules operate at a different layer than isolation boundaries — they gate individual tool calls rather than the process/filesystem boundary — so they compose independently with whichever isolation boundary you chose above.

---

## Summary

| Feature | Claude Code Sandbox | Docker AI Sandboxes | This Project |
|---------|-------------------|-------------------|-------------|
| Execution restriction | OS-level | microVM isolation | Container isolation |
| File read blocking | Deny rules (application-level) | No mechanism | Volume mounts (filesystem-level) |
| Multi-project scope | Limited (no parent traversal) | Single workspace | Full workspace with per-file hiding |
| Cross-container access | Restricted | Isolated | Controlled via HostMCP |
| Secret masking in output | No | No | Automatic |
| Startup validation | No | No | Automatic sync check |
| Setup complexity | None on macOS; bubblewrap/socat on Linux/WSL2 | Docker Desktop | Docker + docker-compose |

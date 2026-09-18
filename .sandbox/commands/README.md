# AI-Sandbox Built-in Custom Commands

[日本語版はこちら](README.ja.md)

[← Back to Plugin Guide](../../docs/plugins.md)

[← Back to README.md](../../README.md)


`.sandbox/commands/` provides custom commands built on top of Claude Code's `/code-review` plugin, with the following improvements:
- Works without a Git repository (Non-Git mode support)
- 5 specialized review types (general / security / performance / architecture / prompt)
- Two-stage verification (batch scoring + validation) to reduce false positives

## Installation

Ask Claude Code to "install the custom commands," or use `install-commands.py` directly:

```bash
.sandbox/scripts/install-commands.py --list             # List available commands
.sandbox/scripts/install-commands.py ais-local-review    # Install ais-local-review
.sandbox/scripts/install-commands.py --all               # Install all commands
```

## Built-in Command List

| Command | Description |
|---------|-------------|
| `/ais-local-review` | Code review (5 modes: general / security / performance / architecture / prompt)<br>Use for a pre-commit catch-all or a focused specialist review. |
| `/ais-local-architecture-review` | Architecture review<br>Check design patterns, responsibility separation, and dependency structure. |
| `/ais-local-security-review` | Security review<br>Find vulnerabilities: auth flaws, injection risks, secret exposure, etc. |
| `/ais-local-performance-review` | Performance review<br>Spot bottlenecks in compute, memory, I/O, and scalability. |
| `/ais-local-test-review` | Test quality review<br>Verify tests exercise real behavior, catch anti-patterns, and identify coverage gaps. |
| `/ais-local-doc-review` | Review documentation for accuracy, consistency, and clarity<br>Check that READMEs and docs match the actual code and are easy to read. |
| `/ais-local-comment-review` | Review in-code comments for accuracy, first-read clarity, excess/deficiency, and necessity<br>Scans full files (not just a diff) — catches stale or low-value comments that a diff-scoped review would never see. |
| `/ais-local-design-challenge` | Challenge a design from multiple stances (skeptical reviewer, user advocate, ops owner, alternative architect)<br>Before spec-review: surface objections and alternative directions without proposing edits — keeps the "is this the right approach" judgment call with the user instead of anchoring on the current wording. |
| `/ais-local-spec-review` | Design doc quality review (coverage, consistency, test validity, etc.)<br>Before implementation: find gaps, contradictions, and ambiguities in the spec itself. |
| `/ais-local-prompt-review` | Review AI command / prompt files<br>Check quality and consistency of prompts in `.claude/commands/` and similar locations. |
| `/ais-local-design-enhance` | Brainstorm and enhance design docs (identify gaps and generate additions)<br>While drafting a spec: surface overlooked areas and generate ready-to-insert text. |
| `/ais-refactor` | Suggest concrete refactoring improvements<br>Get specific, actionable transformations to make working code more readable and maintainable. |
| `/ais-test-gen` | Auto-generate tests for changed code<br>Generate tests from scratch for implemented code, covering edge cases and error handling. |

All commands work even without a Git repository.

## Recommended Workflow: Tightening a Design Doc Before Implementation

The three design-doc commands above are meant to be used **in this order**, each in a fresh session so it isn't anchored by the conversation that produced the draft:

1. Draft the design doc with Claude Code.
2. `/ais-local-design-challenge` — is the approach itself right? Surfaces objections and alternative directions without proposing edits.
3. Decide which positions from Step 2 to adopt, then revise the doc accordingly — write it yourself, or ask Claude to write it once you've told it your decision. Either way, the decision of what to adopt is yours, made outside the command itself.
4. `/ais-local-spec-review` — now that the approach is settled, check the resulting document's internal consistency, completeness, and clarity.
5. `/ais-local-design-enhance` — fill in the remaining gaps (error handling, edge cases, test items) with ready-to-insert text.
6. Move to implementation, again in a fresh session.

Running spec-review or design-enhance before challenging the approach tends to just polish a design that hasn't been stress-tested yet.

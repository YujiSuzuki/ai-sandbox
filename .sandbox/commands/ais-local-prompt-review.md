---
description: Review AI command/prompt files for quality and consistency (works even without a Git repository)
description-ja: AIコマンド／プロンプトファイルの品質・一貫性をレビュー（Git リポジトリがなくても動作）
argument-hint: [project-path] [change summary]
allowed-tools: [Read, Bash(git -C:*), Bash(find:*), Bash(test:*), Task, AskUserQuestion, TodoWrite]
---

# Local Prompt Review

Reviews AI command/prompt files (.md) for quality, consistency, and effectiveness. If a Git repository exists, it reviews either uncommitted changes or the diff between branches; otherwise, it reviews the specified files/directories. Focuses on prompt design, agent orchestration, instruction clarity, and cross-command consistency.

## Language

Detect the user's language from their previous messages in the conversation. Output all review results, issue descriptions, and recommendations in the same language the user uses. If uncertain, follow the session's default response language (see CLAUDE.md's "Response Language" rule / sandbox-mcp's language signal); only fall back to English if no such signal is available.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: Project path (absolute or relative) or a single file path — the first whitespace-delimited token in `$ARGUMENTS`, if it looks like a path (starts with `/`, `./`, `../`, or contains `/`) and actually exists on disk. If no such token exists, or it doesn't exist on disk, treat the entire `$ARGUMENTS` string as the change summary and ask the user what to review.
- 2nd argument onwards: Everything after the 1st argument (change summary); asked via AskUserQuestion in Step 2 if omitted. In Git mode, this same text is also checked in Step 2 to infer the review scope (uncommitted vs. branch comparison) before asking.

## Execution Steps

Follow these steps precisely:

### Step 1: Project Selection and Git Detection

1. Search for projects under `/workspace` (both Git repositories and regular directories). Use `find` only to locate paths — never with mutating flags such as `-delete` or `-exec` — and derive directory names yourself from the returned paths rather than piping through other utilities:
   ```bash
   # Search for Git repositories (maxdepth 3: .git can sit a level or two below a monorepo root)
   find /workspace -maxdepth 3 -type d -name ".git" 2>/dev/null
   # Also search for main project directories (those with package.json, go.mod, Cargo.toml, etc.)
   # (maxdepth 2: marker files are expected at the project root or one level below it)
   find /workspace -maxdepth 2 -type f \( -name "package.json" -o -name "go.mod" -o -name "Cargo.toml" -o -name "pyproject.toml" -o -name "Makefile" \) 2>/dev/null
   ```
   For the first command, strip the trailing `/.git` from each result yourself to get the project directory. For the second command, take the containing directory of each matched file yourself. Do not rely on `sed`, `xargs`, or `dirname` for this — they are not declared in `allowed-tools`.

2. Take the first whitespace-delimited token of `$ARGUMENTS`. If it looks like a path (starts with `/`, `./`, `../`, or contains `/`), verify it exists on disk:
   ```bash
   test -e <candidate-token>
   ```
   Judge by the exit code (0 = exists). Do not append `&& echo …` — `echo` is not declared in `allowed-tools`. If it exists, use it as `<project-path>`.

3. If no valid project path was found in step 2 (empty `$ARGUMENTS`, no path-like token, or the token doesn't exist on disk), deduplicate the combined list from the two `find` commands in step 1 by directory path (a project may match both the `.git` search and the marker-file search), then use the AskUserQuestion tool to let the user select a project to review from the found projects. If no projects are found, ask the user to enter the project path manually. Use the selected path as `<project-path>` throughout Steps 2–3.

4. Check if the selected project directory has `.git` and determine **Git mode** or **Non-Git mode**:
   ```bash
   test -d <project-path>/.git
   ```
   Judge by the exit code (0 = Git mode, non-zero = Non-Git mode); do not append `&& echo …` for the same reason as above.

### Step 2: Determine Review Target and Change Summary

First, determine whether a change summary is already available:
- If a valid project path was found in Step 1 (the 1st argument), the 2nd argument onwards is the change summary, if provided.
- If no valid project path was found in Step 1 (the entire `$ARGUMENTS` string was treated as the change summary), that string is the change summary.
- In both cases, an empty or whitespace-only string does not count as an available change summary.
- Otherwise, no change summary is available yet, and it must be asked for below.

#### For Git Mode:

1. Check the repository state:
   ```bash
   git -C <project-path> status --porcelain -uall
   git -C <project-path> branch -a
   git -C <project-path> branch --show-current
   ```
   Note: `--show-current` prints nothing on a detached HEAD. In that case, treat `HEAD` as the target ref and only offer the branch-comparison flow if the user explicitly names a base ref.

2. Try to infer the **review scope** from the change-summary text determined above (the 2nd-argument-onwards text), before asking anything:
   - If it contains a clear signal for uncommitted work (e.g. "staged", "unstaged", "uncommitted", "working tree", "ステージ", "未コミット", "作業ツリー") AND `git status --porcelain -uall` produced output, treat scope as **Uncommitted changes** and skip step 3 entirely — no branch question is needed.
   - Else if it contains a clear signal for comparing branches (e.g. "branch", "compare", "vs", "..", "against main", a branch name from the `branch -a` output), treat scope as **Branch comparison**; step 3 still runs, but only to confirm which branches (omit the scope option from that question).
   - Otherwise, inference is inconclusive; step 3 runs and must include the scope option.

3. Use the AskUserQuestion tool **once** to confirm, in a single call, whichever of the following are still needed:
   - **Review scope** (only include if scope inference in step 2 was inconclusive): Uncommitted changes (offer this option only if `git status --porcelain -uall` produced output) / Branch comparison
   - **Base branch** (omit if scope is confirmed as Uncommitted changes): The branch to compare against (e.g., main, master, develop)
   - **Target branch** (omit if scope is confirmed as Uncommitted changes): The branch to review (current branch by default)
   - **Change summary** (only include this question if no change summary is available from above): A brief explanation of the purpose and background of the changes. Examples: "New review command for security", "Updated agent configuration", "Added prompt template"

   If the user selects **Uncommitted changes** for Review scope in this call, no base/target branches are needed.

#### For Non-Git Mode:

0. **Shortcut**: If `<project-path>` (whether it came from the 1st argument per Step 1.2 or from manual entry per Step 1.3) is itself a single file rather than a directory, it is already an unambiguous review target. Set `<target-paths>` to `<project-path>` and skip step 2's "Review target" question below — only ask for the change summary via AskUserQuestion if one isn't already available. Otherwise, continue with steps 1–2.

1. Search for command/prompt files within the project:
   ```bash
   find <project-path> -type f -name "*.md" \( -path "*commands*" -o -path "*prompts*" -o -path "*.claude/*" -o -path "*.sandbox/*" \) 2>/dev/null
   ```
   If the result has more than 50 entries, use only the first 50 for the purpose of the selection prompt below (do not pipe through `head` — it is not declared in `allowed-tools`).

2. Use the AskUserQuestion tool **once** to confirm, in a single call:
   - **Review target**: Path(s) to files or directories to review (can be multiple, space-separated). Examples: `.sandbox/commands/`, `.claude/commands/`, `prompts/`, etc. Resolve relative paths against `<project-path>` (not the current working directory) before using them. Use the confirmed path(s) as `<target-paths>` in Step 3.
   - **Change summary** (only include this question if no change summary is available from above): A brief explanation of the purpose and background of the changes. Examples: "Prompt quality audit", "Command consistency check", etc.

### Step 3: Retrieve and Analyze Review Targets

#### For Git Mode — Uncommitted changes:

1. Get the working-tree diff and changed files:
   ```bash
   git -C <project-path> diff HEAD --name-only
   git -C <project-path> diff HEAD
   git -C <project-path> status --porcelain -uall
   ```
   (`-uall` expands untracked directories into individual file entries; without it, a whole untracked directory would appear as a single `?? dir/` line.)

2. From the combined changed-files list (diffed `--name-only` output plus untracked files from `status --porcelain -uall`), keep only files matching `*.md` and drop `README*`, `CHANGELOG*`, `CONTRIBUTING*`, `LICENSE*` (same filter as Non-Git mode). Record the resulting list as the review targets.

   If the resulting list is empty (e.g., the uncommitted changes only touch non-Markdown files), inform the user that no command/prompt files have uncommitted changes and stop here — do not proceed to Step 4.

3. For untracked files in the resulting list, read their full content with the Read tool and treat it as newly added; tracked/modified files are already covered by the diff from step 1. Skip files that are clearly binary.

#### For Git Mode — Branch comparison:

1. Get the diff between base branch and target branch:
   ```bash
   git -C <project-path> diff <base-branch>...<target-branch> --name-only
   git -C <project-path> diff <base-branch>...<target-branch>
   git -C <project-path> log <base-branch>...<target-branch> --oneline
   ```
   If any of these commands fails (e.g., a branch name doesn't exist), use the AskUserQuestion tool to re-confirm the branch names before continuing — do not proceed with an empty diff.

2. From the changed-files list, keep only files matching `*.md` and drop `README*`, `CHANGELOG*`, `CONTRIBUTING*`, `LICENSE*` (same filter as Non-Git mode). Record the resulting list as the review targets.

   If the resulting list is empty (e.g., the diff only touches non-Markdown files), inform the user that no command/prompt files were changed between `<base-branch>` and `<target-branch>` and stop here — do not proceed to Step 4.

   If a file in the resulting list no longer exists in `<target-branch>` (i.e., it was deleted), skip reading its content as a review target and note it in the Step 7 report as "deleted" rather than treating it as a reviewable file.

#### For Non-Git Mode:

1. Collect command/prompt files from specified paths (run for each path in `<target-paths>`):
   ```bash
   find <target-path> -type f -name "*.md" -not -name "README*" -not -name "CHANGELOG*" -not -name "CONTRIBUTING*" -not -name "LICENSE*" 2>/dev/null
   ```
   If any path is not found or returns no results, use the AskUserQuestion tool to ask the user to confirm the path before continuing.

2. Read each file's content and record as review targets

#### Common:

3. Collect ALL command/prompt files in the directories that contain review target files (even unchanged ones) for cross-command consistency checking, applying the same filename filter as above (`*.md`, excluding `README*`, `CHANGELOG*`, `CONTRIBUTING*`, `LICENSE*`). Deduplicate by file path if multiple review target files share the same directory.

4. Collect related CLAUDE.md files:
   - CLAUDE.md at project root
   - CLAUDE.md in directories containing review target files

5. Record two counts for use in the Step 7 report: the number of files collected as review targets in Step 3.1/3.2 (Git mode: changed files; Non-Git mode: specified files), and the number of additional sibling files collected in Step 3.3 for consistency checking only. The total shown in Step 7 is simply the sum of these two counts.

### Step 4: Parallel Prompt Review Execution

**For Git mode** (both uncommitted and branch comparison): Launch 5 parallel Sonnet agents
**For Non-Git mode**: Launch 4 parallel Sonnet agents (skip Agent #5)

If an agent fails or returns no response, continue with the results from the remaining agents.

Pass the following to each agent:
- Review target file contents (Git mode: diff + full text of changed files, plus untracked-file contents where applicable, Non-Git mode: full files)
- Change summary (from Step 2)
- Related CLAUDE.md contents

Additionally, pass ALL sibling command files in the directories containing review target files to **Agent #2** (needed for the scoring/threshold cross-command comparison), **Agent #3** (needed for cross-command consistency checking), and **Agent #5** (needed to check whether a fix already applied to siblings was not applied to the changed file). Agents #1 and #4 do not need siblings for any of their checks, so omit them for those agents to keep context focused and reduce token usage.

**Agent #1: Instruction Clarity & Completeness**
- Ambiguous or vague instructions that an AI could misinterpret
- Missing steps or gaps in the execution flow
- Unclear preconditions or assumptions
- Steps that reference undefined variables or unavailable tools
- Missing error handling guidance (what to do when a step fails)
- Instructions that conflict with each other within the same file
- Overly complex steps that should be broken down (note: multi-agent orchestration steps are intentionally complex — only flag complexity that has no architectural justification)
- `allowed-tools` in YAML front matter lists tools not used in the instructions, or instructions invoke tools not declared in `allowed-tools`
- `allowed-tools` grants write/mutating tools (e.g., Write, Edit, Bash without a read-only scope) to a command whose stated purpose is read-only review — flag as a least-privilege concern
- `argument-hint` in YAML front matter does not match how `$ARGUMENTS` is actually parsed in the Arguments/Step 1-2 sections (e.g., hint implies an argument that is never read, or parsing logic supports an argument the hint doesn't mention)
- `$ARGUMENTS` handling: missing fallback when `$ARGUMENTS` is empty, or multi-word argument parsing not addressed

**Agent #2: Agent Orchestration & Design**

Focus on the *structure* of the multi-agent setup — who checks what and how they're wired together. Do not evaluate whether the resulting review would be effective or noisy; that judgment belongs to Agent #4.

- Agent role overlap (two or more agents whose stated focus areas would flag the same underlying condition)
- Inappropriate agent model selection (Sonnet vs Haiku for the task complexity). Guidance: Haiku is appropriate for classification/scoring tasks with clear criteria. Sonnet is appropriate for judgment-heavy analysis, nuanced reasoning, or tasks requiring broad context. Flag only when the mismatch is clear and unjustified.
- Missing or unclear information passed to agents (an agent is asked to check something but isn't given the file/context needed to check it)
- Agent output format inconsistencies (agents in the same Step 4 don't share a common issue schema, breaking downstream scoring/validation)
- Scoring/threshold *values* that are numerically inconsistent with sibling commands performing comparable severity judgments (e.g., this command validates at >=75 while a sibling with an equivalent risk profile validates at >=50, with no stated rationale)

**Agent #3: Cross-Command Consistency**
- Inconsistent YAML front matter structure (description, argument-hint, allowed-tools)
- Inconsistent step numbering or naming across commands in shared infrastructure steps (Steps 1-3, Step 5-7, YAML front matter, scoring criteria). Domain-specific steps (Step 4 agent definitions, report sections) may intentionally differ.
- Shared infrastructure steps (project selection, git detection, scoring, validation) that differ unnecessarily between commands
- Inconsistent report formats across commands
- Different false positive criteria that should be aligned
- Inconsistent terminology or phrasing
- Missing fields that exist in sibling commands (e.g., description-ja)
- `description-ja` (or other translated fields) present but not equivalent in meaning to the paired `description` field — not a literal-translation check, but flag if the Japanese version omits a capability, scope limitation, or condition ("works even without a Git repository") stated in the English version, or vice versa

**Agent #4: Effectiveness & False Positive Risk**

Focus on whether the review, as designed, would actually produce a good signal-to-noise ratio in practice — not on how the agents are organized (that's Agent #2's job).

- False positive examples that would cause the validation agent to incorrectly reject real findings: e.g., an entry so broadly worded that it covers shared infrastructure drift (which Agent #3 legitimately flags)
- Agent focus areas described only as meta-categories with no concrete, observable check conditions — an agent receiving these will produce either empty output or low-signal noise
- Focus items that target something an LLM cannot statically detect: e.g., "runtime performance of the reviewed prompt", "whether the prompt actually works end-to-end"
- Coverage gaps specific to *this command's stated purpose* that fall outside Agent #2's structural lens — e.g., the command claims to check "Git/Non-Git mode consistency" but no agent's focus area actually names that check
- Review focus that duplicates what external tooling already enforces (e.g., required YAML front matter fields validated by a schema linter outside this prompt)
- Confidence-scoring language (Step 5 criteria wording, not the numeric thresholds — see Agent #2) that is vague enough to produce inconsistent scores for similar issues

**Agent #5: Prompt Regression Detection** (Git mode only)

Before launching Agent #5, run the following yourself (in the main orchestrator, not inside the sub-agent) for each changed command/prompt file, and retain the raw output — it is reused as-is in Steps 5 and 6, since sub-agents do not share context with later steps. Untracked files have no history — skip them here and omit them from this agent's input:
```bash
git -C <project-path> log -p --follow --max-count=20 -- <file>
```

Pass to this agent:
- List of changed files (from Step 3, one path per line)
- Project path (for `git -C` option)
- The `git log -p --follow --max-count=20` output retrieved above, for each changed file

Using the supplied git history, check for:
- Previously fixed instruction defects being reintroduced (e.g., a step that was clarified in a past commit is now ambiguous again)
- Instructions that were added, then removed, then re-added in a different form — suggesting unresolved design churn
- Consistency issues that were corrected in siblings but not applied to the changed file

Note: this may surface the same underlying inconsistency that Agent #3 also flags from a current-state comparison. When both agents report the same file/section, keep Agent #5's version only if it adds historical context (e.g., naming the commit where siblings were fixed); otherwise treat it as a duplicate of the Agent #3 finding in Step 5 scoring.

Agent #5 findings use the `Regression` category (see report format below).

Each agent reports issues in the following format:
```
- ID: <agent-prefix>-<sequential-number> (e.g. A1-1, A1-2, … for Agent #1; A2-1, A2-2, … for Agent #2; etc.)
- File: <file-path>
- Section: <step or section name>
- Issue: <description>
- Impact: Critical / High / Medium / Low
- Category: Clarity / Orchestration / Consistency / Effectiveness / Regression
- Reasoning: <brief explanation of why this is an issue>
```

### Step 5: Confidence Scoring (Batch)

Collect ALL issues from Step 4 and pass them to a **single Haiku agent** for batch scoring.

Provide the agent with:
- The full list of issues from all agents
- The review target code (diff or full files)
- ALL sibling command files in the same directory (required to verify Agent #3 cross-command consistency findings, and Agent #5 sibling-fix findings)
- For Regression (Agent #5) findings: the `git log -p --follow --max-count=20` output for the relevant file(s), retrieved by the orchestrator before launching Agent #5 in Step 4 (required to score claims about reintroduced defects or historical churn)
- The scoring criteria below

Scoring criteria (pass these criteria directly to the agent):
- **0**: No confidence. Subjective style preference or nitpick
- **25**: Somewhat confident. Minor wording issue that is unlikely to cause misinterpretation
- **50**: Moderately confident. Real issue but impact on AI execution quality is uncertain
- **75**: Quite confident. Verified issue that will likely cause incorrect behavior, inconsistency, or false positives/negatives in review results
- **100**: Absolutely confident. Clear defect (conflicting instructions, missing critical step, broken reference) that will definitely cause failure

The agent returns a confidence score for each issue in the format `<ID>: <score>` (one per line, e.g. `A1-1: 75`), using the issue IDs assigned in Step 4.

If the scoring agent does not return a score for a given issue, treat it as a score of 0 (fail safe — an unscored issue should not pass the >= 75 threshold applied in Step 6).

If Step 4 produced zero issues, skip Steps 5–6 and proceed directly to the "no issues found" report in Step 7.

If Step 4 produced issues but none scored >= 75, skip Step 6 and use the "no issues found" report in Step 7, appending a one-line note that N low-confidence findings were filtered out. Apply the same rule if Step 6 rejects every issue.

### Step 6: Validation

For each issue that scored >= 75 in Step 5, launch a **single Sonnet agent** to re-verify all of them in one call.

The validation agent receives:
- The filtered list of issues (those scoring >= 75)
- The relevant source code for each issue (for Agent #3 consistency findings and Agent #5 sibling-fix findings, this includes ALL sibling command files in the same directory)
- For Regression (Agent #5) findings: the same orchestrator-retrieved `git log -p --follow --max-count=20` output used in Step 5, so the cited historical commits can actually be re-checked
- The original agent's reasoning (the Reasoning field from each issue)
- The full text of the False Positive Examples section from this command

For each issue, the validation agent must:
1. Re-read the cited code location
2. Confirm the issue is real (not a false positive from the examples in the False Positive section)
3. Return: **CONFIRMED** or **REJECTED** with a one-line reason

If the validation agent does not return a verdict for an issue, treat it as REJECTED (fail safe — an issue that couldn't be verified should not reach the user unconfirmed).

Remove REJECTED issues from the final report.

### Step 7: Filtering and Report Generation

1. Filter out issues that were REJECTED in Step 6 or scored below 75

2. Output final report in the following format:

---

## Prompt Review Results

**Project**: <project-path>
**Mode**: Git mode (uncommitted changes) / Git mode (branch comparison) / Non-Git mode
**Review target**:
  - Git mode (uncommitted): working tree vs HEAD
  - Git mode (branch comparison): <base-branch>...<target-branch>
  - Non-Git mode: <target-files-or-directories>
**Change summary**: <user-provided-summary>
**Files reviewed**: <count> command files (<count> review targets + <count> siblings for consistency; Git mode: review targets are changed/uncommitted files, Non-Git mode: review targets are the specified files)
**Deleted files** (Git mode branch comparison only; include this line only if applicable): <paths of files deleted in the diff, per Step 3>


### Issues Found

Issues with confidence >= 75:

**Issue 1**: <Brief description of the issue>
- File: `<file-path>`
- Section: <step or section name>
- Impact: <Critical / High / Medium / Low>
- Category: <Clarity / Orchestration / Consistency / Effectiveness / Regression>
- Confidence: <score>/100

```markdown
<relevant excerpt>
```

**Recommendation**: <specific improvement suggestion>

---

If no issues were found:

## Prompt Review Results

No issues found. Checked for instruction clarity, agent orchestration, cross-command consistency, and effectiveness.

---

## False Positive Examples (Consider in Steps 4, 5, and 6)

The following should be excluded as false positives:

- Writing style preferences (as long as instructions are clear)
- Minor formatting differences that don't affect AI interpretation
- Intentional differences between commands in **domain-specific steps** (e.g., Step 4 agent definitions, report section titles and content) — each command type has different review needs here. Do NOT apply this to shared infrastructure steps (Steps 1–3, Steps 5–7, YAML front matter, scoring thresholds), where unnecessary drift is a real consistency issue.
- Suggestions to add features beyond the command's stated scope
- Theoretical edge cases that are extremely unlikely to occur in practice
- Intentionally complex orchestration steps (multi-agent parallelism, Git/Non-Git mode branching) — complexity is expected in this type of command
- ALL CAPS used deliberately for emphasis in instructions
- Intentionally omitted error handling where silent continuation is the correct design (e.g., a step that can safely be skipped on failure)
- Wording differences between `ais-local-prompt-review.md` and `ais-local-prompt-review-single-agent.md` in Steps 5–6 (agent-number references such as "Agent #3"/"Agent #5" vs. category-name references) — this is a disclosed, intentional adaptation for the single-agent design (see the note at the top of the single-agent file), not undisclosed consistency drift

For Git mode only:
- Existing issues (not introduced in this PR)
- Issues in files not changed by the user in the PR (except cross-command consistency which may reference unchanged siblings)

## Notes

- Don't run builds or type checks (those are run separately in CI)
- Don't use gh command (this is for local review)
- Always include file and section references for each issue
- Use TodoWrite tool to track progress
- Read ALL sibling command files for consistency checks, not just the changed ones
- Focus on issues that would affect AI execution quality, not writing style

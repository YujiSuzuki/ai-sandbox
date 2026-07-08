---
description: Run local code review (works even without a Git repository)
description-ja: ローカルコードレビューを実行（Git リポジトリがなくても動作）
argument-hint: [project-path] [change summary]
allowed-tools: [Read, Glob, Grep, Bash(git -C * branch *), Bash(git -C * diff *), Bash(git -C * log *), Bash(git -C * blame *), Bash(git -C * status *), Bash(ls:*), Bash(find:*), Bash(test:*), Bash(head:*), Bash(echo:*), Task, AskUserQuestion, TodoWrite]
---

# Local Code Review

Performs code review on local code. If a Git repository exists, it reviews either uncommitted changes or the diff between branches; otherwise, it reviews the specified files/directories.

## Language

Detect the user's language from their previous messages in the conversation. Output all review results, issue descriptions, and recommendations in the same language the user uses. If uncertain, default to English.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: Project path (absolute or relative) or a single file path — the first whitespace-delimited token in `$ARGUMENTS`, if it looks like a path (starts with `/`, `./`, `../`, or contains `/`) and actually exists on disk. If no such token exists, or it doesn't exist on disk, treat the entire `$ARGUMENTS` string as the change summary and ask the user what to review.
- 2nd argument onwards: Everything after the 1st argument (change summary); asked via AskUserQuestion in Step 3 if omitted

## Execution Steps

Follow these steps precisely:

### Step 1: Project Selection and Git Detection

1. Take the first whitespace-delimited token of `$ARGUMENTS`. If it looks like a path (starts with `/`, `./`, `../`, or contains `/`), verify it exists on disk:
   ```bash
   test -e <candidate-token> && echo "VALID_PATH" || echo "NOT_A_PATH"
   ```
   If it exists, use it as `<project-path>` and **skip step 2** (no project search needed).

2. Only if no valid project path was found in step 1 (empty `$ARGUMENTS`, no path-like token, or the token doesn't exist on disk), search for projects under `/workspace` (both Git repositories and regular directories). Use `find` only to locate paths — never with mutating flags such as `-delete` or `-exec`:
   ```bash
   # Search for Git repositories (maxdepth 3: .git can sit a level or two below a monorepo root)
   find /workspace -maxdepth 3 -type d -name ".git" 2>/dev/null | head -30
   # Also search for main project directories (those with package.json, go.mod, Cargo.toml, etc.)
   # (maxdepth 2: marker files are expected at the project root or one level below it)
   find /workspace -maxdepth 2 -type f \( -name "package.json" -o -name "go.mod" -o -name "Cargo.toml" -o -name "pyproject.toml" -o -name "Makefile" \) 2>/dev/null | head -30
   ```
   For the first command, strip the trailing `/.git` from each result yourself to get the project directory. For the second command, take the containing directory of each matched file yourself. Do not pipe through `sed`, `xargs`, or `dirname` for this — they are not declared in `allowed-tools`.

   Deduplicate the combined list from the two `find` commands by directory path (a project may match both the `.git` search and the marker-file search), then use the AskUserQuestion tool to let the user select a project to review from the found projects. If no projects are found, ask the user to enter the project path manually.

3. Check if the selected project directory has `.git` and determine **Git mode** or **Non-Git mode**:
   ```bash
   test -d <project-path>/.git && echo "GIT_MODE" || echo "NON_GIT_MODE"
   ```

### Step 2: Determine Review Target

#### For Git Mode:

1. Check the repository state:
   ```bash
   git -C <project-path> status --porcelain -uall
   git -C <project-path> branch -a
   git -C <project-path> branch --show-current
   ```
   Note: `--show-current` prints nothing on a detached HEAD. In that case, treat `HEAD` as the target ref and only offer the branch-comparison flow if the user explicitly names a base ref.

   If `status --porcelain -uall` produced no output AND only one branch exists (nothing to compare against), there is nothing to review in Git mode. Tell the user so and ask whether they want to review specific files/directories directly instead (following the Non-Git mode flow), rather than proceeding.

2. Use the AskUserQuestion tool to confirm the **review scope**:
   - **Uncommitted changes** (offer this option only if `git status --porcelain -uall` produced output): review the working tree against `HEAD` (`git diff HEAD`, plus untracked files reported by `status --porcelain`)
   - **Branch comparison**: review the diff between two branches

3. If the user chose **Branch comparison**, use the AskUserQuestion tool to confirm:
   - **Base branch**: The branch to compare against — offer common candidates found in the `branch -a` output (e.g., main, master, develop) as options, with free-form input for anything else
   - **Target branch**: The branch to review (current branch by default)
   - If the chosen base and target are identical, tell the user the diff would be empty and ask again.

#### For Non-Git Mode:

0. **Shortcut**: If `<project-path>` is itself a single file rather than a directory, it is already an unambiguous review target. Set `<target-paths>` to `<project-path>` and skip step 2 below.

1. Check the file structure within the project:
   ```bash
   find <project-path> -maxdepth 4 -type d \
     -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/vendor/*" \
     -not -path "*/dist/*" -not -path "*/build/*" \
     2>/dev/null | head -50
   ```

2. Use the AskUserQuestion tool to confirm:
   - **Review target**: Path(s) to files or directories to review (can be multiple, space-separated)
   - Examples: `src/`, `internal/mcp/`, `main.go`, etc.
   - Use the confirmed path(s) as `<target-paths>` in Step 4.

### Step 3: Change Summary Input

If a valid project path was found in Step 1 (the 1st argument), use the 2nd argument onwards as the change summary if provided, and skip AskUserQuestion.

If no valid project path was found in Step 1 (the entire `$ARGUMENTS` string was treated as the change summary), use that string directly as the change summary and skip AskUserQuestion — unless that string is empty or whitespace-only, in which case no change summary is available (fall through to the rule below).

Only if no change summary text is available in either case, use the AskUserQuestion tool to get:
- **Change summary**: A brief explanation of the purpose and background of the changes
  - Examples: "Adding user authentication", "Performance improvements", "Bug fix"
  - For Non-Git mode: "New implementation review", "Code quality check", etc.

### Step 4: Retrieve and Analyze Review Targets

#### For Git Mode — Uncommitted changes:

1. Get the working-tree diff and changed files:
   ```bash
   git -C <project-path> diff HEAD --name-only
   git -C <project-path> diff HEAD
   git -C <project-path> status --porcelain -uall
   ```
   (`-uall` expands untracked directories into individual file entries; without it, a whole untracked directory would appear as a single `?? dir/` line.)

2. Untracked files (lines starting with `??` in the `status --porcelain -uall` output) do not appear in `git diff HEAD`. Read each untracked file with the Read tool and treat its full content as newly added code in the review target. Skip files that are clearly binary.

3. Record the combined list of changed files (diffed + untracked)

#### For Git Mode — Branch comparison:

1. Get the diff between base branch and target branch:
   ```bash
   git -C <project-path> diff <base-branch>...<target-branch> --name-only
   git -C <project-path> diff <base-branch>...<target-branch>
   git -C <project-path> log <base-branch>...<target-branch> --oneline
   ```

2. Record the list of changed files

#### For Non-Git Mode:

1. Collect source code from specified files/directories (run for each path in `<target-paths>`):
   ```bash
   find <target-path> -type f \
     -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/vendor/*" \
     -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/.next/*" -not -path "*/target/*" \
     -not -name "*.min.js" -not -name "*.min.css" \
     -not -name "*.lock" -not -name "*-lock.json" -not -name "*.lockb" -not -name "*.sum" \
     -size -1M \
     2>/dev/null | head -100
   ```
   Cap the combined result across all paths at 100 files (if a single path already returned 100, skip the rest and tell the user the scope was truncated). If no files are found or the user's path was unclear, ask them to specify files or directories directly.

2. Read each file's content and record as review targets. Skip files that are clearly binary.

#### Common:

3. Collect related CLAUDE.md files (use Glob):
   - CLAUDE.md at project root
   - CLAUDE.md in directories containing review target files

4. Collect documentation files in the project:
   ```bash
   find <project-path> -type f -name "*.md" \
     ! -path "*/.git/*" \
     ! -path "*/node_modules/*" \
     ! -path "*/vendor/*" \
     2>/dev/null | head -40
   ```
   Read each found doc file and record as documentation context.

### Step 5: Parallel Review Execution

**For Git mode** (both uncommitted and branch comparison): Launch 5 parallel Sonnet agents
**For Non-Git mode**: Launch 4 parallel Sonnet agents (skip Agent #3 which requires Git history)

If an agent fails or returns no response, continue with the results from the remaining agents.

Pass the following to each agent:
- Review target file contents (Git mode: diff plus untracked-file contents where applicable, Non-Git mode: full files)
- Change summary (from Step 3)
- Related CLAUDE.md contents

**Agent #1: CLAUDE.md Compliance Check**
Issue ID prefix: `A1-` (e.g. A1-1, A1-2, …)
- Verify code follows CLAUDE.md guidelines
- Report violations with specific locations and corresponding CLAUDE.md rules

**Agent #2: Bug Scan**
Issue ID prefix: `A2-` (e.g. A2-1, A2-2, …)
- Look for obvious bugs in the review target code
- Focus on significant bugs, avoid minor nitpicks

**Agent #3: Regression & History Analysis** (Git mode only)
Issue ID prefix: `A3-` (e.g. A3-1, A3-2, …)

Pass additionally to this agent:
- List of changed files (from Step 4, one path per line)
- Project path (for `git -C` option)

- Check git blame and history of changed files:
  ```bash
  git -C <project-path> log -p --follow --max-count=20 -- <file>
  git -C <project-path> blame <file>
  ```
  where `<file>` refers to each file from the changed files list above.
  **Volume cap**: if more than 10 files changed, run these commands only for the 10 files most relevant to the change summary (judge relevance from file paths and the summary) and note in the agent output which files were skipped. Untracked files have no history — skip them here.
- Check for conflicts with past changes
- Verify previously fixed bugs aren't being reintroduced
- Extract relevant context from past commit messages that may affect the current changes

**Agent #4: Code Comment Check**
Issue ID prefix: `A4-` (e.g. A4-1, A4-2, …)
- Review comments in target files
- Verify code follows guidance in comments
- Check handling of TODO and FIXME comments (Git mode: only flag TODO/FIXME introduced in the diff or in untracked files; do not report pre-existing ones in unchanged lines)

**Agent #5: Documentation Drift Check**
Issue ID prefix: `A5-` (e.g. A5-1, A5-2, …)

Pass additionally to this agent:
- Documentation file contents collected in Step 4

Check whether the reviewed code changes have caused documentation to become stale. Focus only on factual accuracy issues, not doc quality or style.

For Git mode — check in the diff:
- Functions, methods, or types that were renamed or removed but are still referenced by name in docs
- New CLI flags, config keys, or environment variables added in the diff that are not mentioned in docs
- File paths or module names changed in the diff that docs still reference with the old name
- Behavioural changes (return values, error conditions, default values) described differently in docs

For Non-Git mode — only report drift where BOTH the doc file and the referenced source file are within the reviewed files:
- Code examples in a reviewed doc that use APIs inconsistent with a reviewed source file
- Function/method names referenced in a reviewed doc that provably don't exist in the reviewed source files
- File paths or import paths in a reviewed doc that contradict the actual structure visible in the reviewed files

Do NOT report (Non-Git mode):
- Symbols or paths that might exist in source files outside the review scope (cannot be confirmed absent)
- Anything that requires reading files not included in the review target

Do NOT report (all modes):
- Missing docs for internal/private functions
- Doc style, clarity, or completeness issues (those belong in `/ais-local-doc-review`)
- Speculative drift where the relationship between code and doc is unclear

Each agent reports issues in the following format:
```
- ID: <agent-prefix>-<sequential-number> (e.g. A1-1, A1-2, … for Agent #1; A2-1, A2-2, … for Agent #2; etc.)
- File: <file-path>
- Line: <line-number>
- Issue: <description>
- Impact: Critical / High / Medium / Low
- Category: CLAUDE.md / Bug / History / Comment / DocDrift
- Reasoning: <brief explanation of why this is an issue>
```

### Step 6: Confidence Scoring (Batch)

Collect ALL issues from Step 5 and pass them to a **single Haiku agent** for batch scoring.

Provide the agent with:
- The full list of issues from all agents
- The review target code (diff or full files)
- The full text of the False Positive Examples section from this command
- The scoring criteria below
- Which mode this review runs in (Git mode or Non-Git mode)

Scoring criteria (pass these criteria directly to the agent):
- **0**: No confidence. False positive that falls apart under light scrutiny, or — **Git mode only** — a pre-existing issue not introduced by the reviewed changes. (In Non-Git mode all reviewed code is pre-existing by definition, so do NOT zero out issues on that basis.)
- **25**: Somewhat confident. Might be a real issue, but could be false positive. For style issues, not explicitly stated in CLAUDE.md
- **50**: Moderately confident. Real issue but trivial or unlikely to occur in practice. Low priority within the overall PR
- **75**: Quite confident. Cross-checked against the supplied code and confirmed it's likely to occur. Existing approach is insufficient. Directly affects functionality or explicitly stated in CLAUDE.md
- **100**: Absolutely confident. Cross-checked against the supplied code and confirmed it will definitely occur. Occurs frequently

The agent returns a confidence score for each issue in the format `<ID>: <score>` (one per line, e.g. `A1-1: 75`), using the issue IDs assigned in Step 5.

If the scoring agent does not return a score for a given issue, treat it as a score of 0 (fail safe — an unscored issue should not pass the >= 75 threshold applied in Step 7).

### Step 7: Validation

Launch **one single Sonnet validation agent** and pass it ALL issues that scored >= 75 in Step 6 (do not launch one agent per issue). If no issues scored >= 75, skip this step.

The validation agent receives:
- The filtered list of issues (those scoring >= 75)
- The relevant source code for each issue
- The original agent's reasoning (the Reasoning field from each issue)
- The full text of the False Positive Examples section from this command
- Which mode this review runs in (Git mode or Non-Git mode)

For each issue, the validation agent must:
1. Re-read the cited code location
2. Confirm the issue is real (not a false positive from the examples in the False Positive section)
3. Return: **CONFIRMED** or **REJECTED** with a one-line reason

If the validation agent does not return a verdict for an issue, treat it as REJECTED (fail safe — an issue that couldn't be verified should not reach the user unconfirmed).

Remove REJECTED issues from the final report.

### Step 8: Filtering and Report Generation

1. Filter out issues that were REJECTED in Step 7 or scored below 75 in Step 6

2. Output final report in the following format:

---

## Code Review Results

**Project**: <project-path>
**Mode**: Git mode (uncommitted changes) / Git mode (branch comparison) / Non-Git mode
**Review target**:
  - Git mode (uncommitted): working tree vs HEAD
  - Git mode (branch comparison): <base-branch>...<target-branch>
  - Non-Git mode: <target-files-or-directories>
**Change summary**: <user-provided-summary>

### Issues Found

If issues were found:

**Issue 1** (<internal-ID, e.g. A2-3>): <Brief description of the issue>
- File: `<file-path>`
- Line: L<start>-L<end>
- Impact: <Critical / High / Medium / Low>
- Category: <CLAUDE.md / Bug / History / Comment / DocDrift>
- Confidence: <score>/100

```diff
<relevant code snippet>
```

**Recommendation**: <specific fix suggestion>

---

If no issues were found:

### Code Review Results

No issues found. Checked for bugs and CLAUDE.md compliance.

---

## False Positive Examples (Consider in Steps 5, 6, and 7)

The following should be excluded as false positives:

- Things that look like bugs but aren't actually bugs
- Minor nitpicks that a senior engineer wouldn't point out
- Issues that linters, type checkers, or compilers configured in this project would detect
- General code quality issues not explicitly required by CLAUDE.md
- Issues explicitly disabled by lint ignore comments
- Functional changes that are the deliberate goal of the change itself (e.g., a redesigned API surface) — as opposed to unintended side effects introduced along the way, which should still be reported

For Git mode only:
- Existing issues (not introduced in this review's changes)
- Issues on lines not changed by the user in this review's changes

For DocDrift:
- Missing docs for internal/private symbols (not public API)
- Doc style, clarity, or completeness issues unrelated to code accuracy
- Speculative drift where the relationship between code and doc is ambiguous

## Notes

- Don't run builds or type checks (those are run separately in CI)
- Don't use gh command (this is for local review)
- Only ever run read-only git subcommands (`branch`, `diff`, `log`, `blame`, `status`). Never run mutating git commands (`commit`, `checkout`, `push`, `stash`, `reset`, etc.), even if asked mid-review — this command's role is strictly read-only.
- Always include file and line links for each issue
- Use TodoWrite tool to track progress

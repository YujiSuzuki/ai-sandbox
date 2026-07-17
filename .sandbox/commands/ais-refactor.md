---
description: Suggest concrete refactoring improvements for code (works even without a Git repository)
description-ja: コードのリファクタリング改善を具体的に提案（Git リポジトリがなくても動作）
argument-hint: [project-path] [change summary]
allowed-tools: [Read, Glob, Grep, Bash(git:*), Bash(ls:*), Bash(find:*), Task, AskUserQuestion, TodoWrite, Write, Edit]
---

# Local Refactor Suggestion

Analyzes code and suggests concrete refactoring improvements. If a Git repository exists, it analyzes either uncommitted changes or the diff between branches; otherwise, it analyzes specified files/directories. Unlike review commands that point out problems, this command provides specific, actionable code transformations.

## Language

Detect the user's language from their previous messages in the conversation. Output all review results, issue descriptions, and recommendations in the same language the user uses. If uncertain, follow the session's default response language (see CLAUDE.md's "Response Language" rule / sandbox-mcp's language signal); only fall back to English if no such signal is available.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: Project path (absolute or relative) or a single file path — the first whitespace-delimited token in `$ARGUMENTS`, if it looks like a path (starts with `/`, `./`, `../`, or contains `/`) and actually exists on disk. If no such token exists, or it doesn't exist on disk, treat the entire `$ARGUMENTS` string as the refactoring focus and ask the user what to review.
- 2nd argument onwards: Everything after the 1st argument (refactoring focus); asked via AskUserQuestion in Step 3 if omitted. In Git mode, this same text is also checked in Step 2 to infer the review scope (uncommitted vs. branch comparison) before asking.

## Execution Steps

Follow these steps precisely:

### Step 1: Project Selection and Git Detection

1. Search for projects under `/workspace` (both Git repositories and regular directories). Use `find` only to locate paths — never with mutating flags such as `-delete` or `-exec` — and derive directory names yourself from the returned paths rather than piping through other utilities:
   ```bash
   # Search for Git repositories (maxdepth 3: .git can sit a level or two below a monorepo root)
   find /workspace -name ".git" -type d -maxdepth 3 2>/dev/null
   # Also search for main project directories (those with package.json, go.mod, Cargo.toml, etc.)
   # (maxdepth 2: marker files are expected at the project root or one level below it)
   find /workspace -maxdepth 2 -type f \( -name "package.json" -o -name "go.mod" -o -name "Cargo.toml" -o -name "pyproject.toml" -o -name "Makefile" \) 2>/dev/null
   ```
   For the first command, strip the trailing `/.git` from each result yourself to get the project directory. For the second command, take the containing directory of each matched file yourself. Do not rely on `sed`, `xargs`, or `dirname` for this — they are not declared in `allowed-tools`.

2. Take the first whitespace-delimited token of `$ARGUMENTS`. If it looks like a path (starts with `/`, `./`, `../`, or contains `/`), verify it exists on disk:
   ```bash
   test -e <candidate-token> && echo "VALID_PATH" || echo "NOT_A_PATH"
   ```
   If it exists, use it as `<project-path>`.

3. If no valid project path was found in step 2 (empty `$ARGUMENTS`, no path-like token, or the token doesn't exist on disk), deduplicate the combined list from the two `find` commands in step 1 by directory path (a project may match both the `.git` search and the marker-file search), then use the AskUserQuestion tool to let the user select a project from the found projects. If no projects are found, ask the user to enter the project path manually.

4. Check if the selected project directory has `.git` and determine **Git mode** or **Non-Git mode**:
   ```bash
   test -d <project-path>/.git && echo "GIT_MODE" || echo "NON_GIT_MODE"
   ```

### Step 2: Determine Refactoring Targets

#### For Git Mode:

1. Check the repository state:
   ```bash
   git -C <project-path> status --porcelain -uall
   git -C <project-path> branch -a
   git -C <project-path> branch --show-current
   ```
   Note: `--show-current` prints nothing on a detached HEAD. In that case, treat `HEAD` as the target ref and only offer the branch-comparison flow if the user explicitly names a base ref.

   If `status --porcelain -uall` produced no output AND only one branch exists (nothing to compare against), there is nothing to analyze in Git mode. Tell the user so and ask whether they want to analyze specific files/directories directly instead (following the Non-Git mode flow), rather than proceeding.

2. Try to infer the **review scope** from the 2nd-argument-onwards text (the raw remainder of `$ARGUMENTS` after the project path — the same text used as the refactoring focus in Step 3), before asking anything:
   - If it contains a clear signal for uncommitted work (e.g. "staged", "unstaged", "uncommitted", "working tree", "ステージ", "未コミット", "作業ツリー") AND `git status --porcelain -uall` produced output, treat scope as **Uncommitted changes** and skip step 3 below.
   - Else if it contains a clear signal for comparing branches (e.g. "branch", "compare", "vs", "..", "against main", a branch name from the `branch -a` output), treat scope as **Branch comparison** and skip step 3 below (step 4 still runs to confirm which branches).
   - Otherwise, inference is inconclusive — fall through to step 3.

3. Only if the scope could not be inferred in step 2, use the AskUserQuestion tool to confirm the **review scope**:
   - **Uncommitted changes** (offer this option only if `git status --porcelain -uall` produced output): analyze the working tree against `HEAD` (`git diff HEAD`, plus untracked files reported by `status --porcelain`)
   - **Branch comparison**: analyze the diff between two branches

4. If the scope is **Branch comparison** (inferred or chosen above), use the AskUserQuestion tool to confirm:
   - **Base branch**: The branch to compare against — offer common candidates found in the `branch -a` output (e.g., main, master, develop) as options, with free-form input for anything else
   - **Target branch**: The branch with changes (current branch by default)
   - If the chosen base and target are identical, tell the user the diff would be empty and ask again.

#### For Non-Git Mode:

1. Check the file structure within the project:
   ```bash
   find <project-path> -type f \( -name "*.go" -o -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.rs" \) 2>/dev/null
   ```
   If the result has more than 50 entries, use only the first 50 for the purpose of the selection prompt below (do not pipe through `head` — it is not declared in `allowed-tools`).

2. Use the AskUserQuestion tool to confirm:
   - **Target files**: Path(s) to files or directories to analyze (can be multiple)
   - Examples: `src/`, `internal/mcp/`, `main.go`, etc.

### Step 3: Refactoring Focus Input

If a valid project path was found in Step 1 (the 1st argument), use the 2nd argument onwards as the refactoring focus if provided, and skip AskUserQuestion.

If no valid project path was found in Step 1 (the entire `$ARGUMENTS` string was treated as the refactoring focus), use that string directly as the refactoring focus and skip AskUserQuestion.

Only if no refactoring focus text is available in either case, use the AskUserQuestion tool to get:
- **Refactoring focus**: What aspect to prioritize (or "general" for broad analysis)
  - Examples: "Reduce duplication", "Improve readability", "Simplify error handling", "Extract shared logic"
  - For Non-Git mode: "General cleanup", "Improve testability", etc.

### Step 4: Retrieve and Analyze Targets

#### For Git Mode — Uncommitted changes:

1. Get the working-tree diff and changed files:
   ```bash
   git -C <project-path> diff HEAD --name-only
   git -C <project-path> diff HEAD
   git -C <project-path> status --porcelain -uall
   ```
   (`-uall` expands untracked directories into individual file entries; without it, a whole untracked directory would appear as a single `?? dir/` line.)

2. Untracked files (lines starting with `??` in the `status --porcelain -uall` output) do not appear in `git diff HEAD`. Read each untracked file with the Read tool and treat its full content as newly added code in the review target. Skip files that are clearly binary.

3. Read the full current content of each changed file (not just the diff) with the Read tool, for context

#### For Git Mode — Branch comparison:

1. Get the diff between base branch and target branch:
   ```bash
   git -C <project-path> diff <base-branch>...<target-branch> --name-only
   git -C <project-path> diff <base-branch>...<target-branch>
   git -C <project-path> log <base-branch>...<target-branch> --oneline
   ```

2. Read the full content of changed files (not just the diff) for context

#### For Non-Git Mode:

1. Collect source code from specified files/directories:
   ```bash
   find <target-path> -type f \( -name "*.go" -o -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.rs" -o -name "*.java" \) 2>/dev/null
   ```

2. Read each file's content and record as targets

#### Common:

3. Read related files that the target code depends on or is depended upon (imports, callers)

4. Collect related CLAUDE.md files:
   - CLAUDE.md at project root
   - CLAUDE.md in directories containing target files

### Step 5: Parallel Refactoring Analysis

**For Git mode** (both uncommitted and branch comparison): Launch 5 parallel Sonnet agents
**For Non-Git mode**: Launch 4 parallel Sonnet agents (skip Agent #5)

If an agent fails or returns no response, continue with the results from the remaining agents.

Pass the following to each agent:
- Target file contents (Git mode: diff + full files, plus untracked files where applicable, Non-Git mode: full files)
- Refactoring focus (from Step 3)
- Related/dependent file contents
- Related CLAUDE.md contents

**Agent #1: Duplication & Extraction**
- Identify duplicated code blocks across files
- Suggest function/method extraction for repeated patterns
- Identify shared logic that could be consolidated
- Propose helper functions or utilities (only when there are 3+ occurrences)

**Agent #2: Simplification & Readability**
- Identify overly complex conditional logic that can be simplified
- Suggest guard clauses to reduce nesting
- Identify long functions that should be broken down
- Propose renaming for unclear variable/function names
- Suggest idiomatic patterns for the language

**Agent #3: Structure & Responsibility**
- Identify functions/classes doing too many things
- Suggest separation of concerns improvements
- Identify misplaced logic (code in the wrong layer/module)
- Propose interface improvements for better abstraction

**Agent #4: Error Handling & Robustness**
- Identify inconsistent error handling patterns
- Suggest unified error handling approaches
- Identify swallowed errors or missing error propagation
- Propose error type consolidation

**Agent #5: Evolution Analysis** (Git mode only)
- Analyze git history for code churn patterns (untracked files have no history — skip them):
  ```bash
  git -C <project-path> log --oneline --follow --max-count=20 -- <file>
  git -C <project-path> log -p --follow --max-count=20 -- <file>
  ```
- Identify code that has been repeatedly modified (hotspots)
- Suggest stabilizing refactors based on change patterns
- Identify temporary workarounds that are now permanent

Each agent reports suggestions in the following format:
```
- Target: <file-path>
- Lines: L<start>-L<end>
- Type: Extraction / Simplification / Restructure / Error Handling / Stabilization
- Summary: <brief description>
- Before: <current code snippet>
- After: <proposed code snippet>
- Rationale: <why this improves the code>
```

### Step 6: Impact Scoring (Batch)

Collect ALL suggestions from Step 5 and pass them to a **single Haiku agent** for batch scoring.

Provide the agent with:
- The full list of suggestions from all agents
- The target source code (diff or full files)
- The scoring criteria below

Scoring criteria (pass these criteria directly to the agent):
- **0**: No value. Cosmetic change or subjective preference with no measurable improvement
- **25**: Minor improvement. Slightly cleaner but doesn't reduce complexity or improve maintainability meaningfully
- **50**: Moderate improvement. Reduces some duplication or improves readability, but scope is small
- **75**: Significant improvement. Clearly reduces complexity, improves testability, or eliminates a maintenance burden. Safe to apply
- **100**: Critical improvement. Eliminates a major source of bugs or maintenance cost. Transformation is clearly correct and safe

The agent returns an impact score (0/25/50/75/100) for each suggestion.

### Step 7: Validation

For each suggestion that scored >= 50 in Step 6, launch a **single Sonnet agent** to re-verify.

The validation agent receives:
- The filtered list of suggestions (those scoring >= 50)
- The relevant source code for each suggestion
- The original agent's reasoning
- The full text of the Non-Suggestions section from this command

For each suggestion, the validation agent must:
1. Re-read the cited code location
2. Confirm the suggestion is valid (not a non-suggestion from the Non-Suggestions section)
3. Verify the proposed transformation preserves existing behavior
4. Return: **CONFIRMED** or **REJECTED** with a one-line reason

Remove REJECTED suggestions from the final output.

### Step 8: Filtering and Output

1. Filter out suggestions that were REJECTED in Step 7 or scored below 50 in Step 6

2. Sort remaining suggestions by score (highest first)

3. Use the AskUserQuestion tool to confirm:
   - **Output mode**: Apply changes to files, or display suggestions in chat only
   - If applying changes, confirm which suggestions to apply

4. Output final report:

---

## Refactoring Suggestions

**Project**: <project-path>
**Mode**: Git mode (uncommitted changes) / Git mode (branch comparison) / Non-Git mode
**Target**:
  - Git mode (uncommitted): working tree vs HEAD
  - Git mode (branch comparison): <base-branch>...<target-branch>
  - Non-Git mode: <target-files-or-directories>
**Focus**: <user-provided-focus>

### High Impact (Score >= 75)

**Suggestion 1**: <Brief description>
- File: `<file-path>`
- Lines: L<start>-L<end>
- Type: <Extraction / Simplification / Restructure / Error Handling / Stabilization>
- Impact: <score>/100

Before:
```<language>
<current code>
```

After:
```<language>
<proposed code>
```

**Rationale**: <why this is an improvement>

### Moderate Impact (Score 50-74)

(Same format as above)

### Summary

| File | Suggestions | Avg Impact | Types |
|------|------------|-----------|-------|
| <file> | <count> | <score>/100 | Extraction, Simplification, ... |

---

If no meaningful refactoring suggestions:

### Refactoring Suggestions

No significant refactoring opportunities found. The analyzed code is clean and well-structured.

---

## Non-Suggestions (Consider in Steps 5, 6, and 7)

The following should NOT be suggested:

- Renaming that is purely stylistic with no clarity improvement
- Premature abstractions for code with only 1-2 occurrences
- Adding design patterns for the sake of patterns
- Refactoring stable code that works fine and isn't being modified
- Changes that would require modifying many callers without clear benefit
- Moving code between files without reducing coupling
- Adding intermediate variables that don't improve readability

For Git mode only:
- Refactoring code outside the changed files (unless directly related)
- Suggestions that conflict with the apparent intent of the changes

## Notes

- Don't run builds or type checks (those are run separately in CI)
- Don't use gh command (this is for local refactoring)
- Always include file and line references for each suggestion
- Use TodoWrite tool to track progress
- Every suggestion MUST include concrete before/after code (not just descriptions)
- Ensure suggested changes preserve existing behavior (no functional changes unless explicitly requested)
- Respect the project's existing patterns and conventions
- Any comments included in "After" code must state a durable constraint on the resulting code, not narrate the refactor's own history/process (e.g. "extracted this because X used to duplicate Y") — that belongs in the commit message, not the file. See docs/ai-guide.md#writing-comments.

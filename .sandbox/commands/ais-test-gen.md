---
description: Generate tests for changed or specified code (works even without a Git repository)
description-ja: 変更コードに対するテストを自動生成（Git リポジトリがなくても動作）
argument-hint: [project-path] [change summary]
allowed-tools: [Read, Glob, Grep, Bash(git:*), Bash(ls:*), Bash(find:*), Task, AskUserQuestion, TodoWrite, Write, Edit]
---

# Local Test Generation

Generates test cases for local code. If a Git repository exists, it generates tests for changed code from either uncommitted changes or the diff between branches; otherwise, it generates tests for specified files/directories. Focuses on meaningful tests that exercise real code paths, covering edge cases, error handling, and behavioral contracts.

## Language

Detect the user's language from their previous messages in the conversation. Output all review results, issue descriptions, and recommendations in the same language the user uses. If uncertain, follow the session's default response language (see CLAUDE.md's "Response Language" rule / sandbox-mcp's language signal); only fall back to English if no such signal is available.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: Project path (absolute or relative) or a single file path — the first whitespace-delimited token in `$ARGUMENTS`, if it looks like a path (starts with `/`, `./`, `../`, or contains `/`) and actually exists on disk. If no such token exists, or it doesn't exist on disk, treat the entire `$ARGUMENTS` string as the change summary and ask the user what to review.
- 2nd argument onwards: Everything after the 1st argument (change summary); asked via AskUserQuestion in Step 3 if omitted. In Git mode, this same text is also checked in Step 2 to infer the review scope (uncommitted vs. branch comparison) before asking.

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

### Step 2: Determine Test Targets

#### For Git Mode:

1. Check the repository state:
   ```bash
   git -C <project-path> status --porcelain -uall
   git -C <project-path> branch -a
   git -C <project-path> branch --show-current
   ```
   Note: `--show-current` prints nothing on a detached HEAD. In that case, treat `HEAD` as the target ref and only offer the branch-comparison flow if the user explicitly names a base ref.

   If `status --porcelain -uall` produced no output AND only one branch exists (nothing to compare against), there is nothing to generate tests for in Git mode. Tell the user so and ask whether they want to target specific files/directories directly instead (following the Non-Git mode flow), rather than proceeding.

2. Try to infer the **review scope** from the 2nd-argument-onwards text (the raw remainder of `$ARGUMENTS` after the project path — the same text used as the change summary in Step 3), before asking anything:
   - If it contains a clear signal for uncommitted work (e.g. "staged", "unstaged", "uncommitted", "working tree", "ステージ", "未コミット", "作業ツリー") AND `git status --porcelain -uall` produced output, treat scope as **Uncommitted changes** and skip step 3 below.
   - Else if it contains a clear signal for comparing branches (e.g. "branch", "compare", "vs", "..", "against main", a branch name from the `branch -a` output), treat scope as **Branch comparison** and skip step 3 below (step 4 still runs to confirm which branches).
   - Otherwise, inference is inconclusive — fall through to step 3.

3. Only if the scope could not be inferred in step 2, use the AskUserQuestion tool to confirm the **review scope**:
   - **Uncommitted changes** (offer this option only if `git status --porcelain -uall` produced output): generate tests for the working tree against `HEAD` (`git diff HEAD`, plus untracked files reported by `status --porcelain`)
   - **Branch comparison**: generate tests for the diff between two branches

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
   - **Target files**: Path(s) to files or directories to generate tests for (can be multiple)
   - Examples: `src/`, `internal/mcp/`, `main.go`, etc.

### Step 3: Change Summary Input

If a valid project path was found in Step 1 (the 1st argument), use the 2nd argument onwards as the change summary if provided, and skip AskUserQuestion.

If no valid project path was found in Step 1 (the entire `$ARGUMENTS` string was treated as the change summary), use that string directly as the change summary and skip AskUserQuestion.

Only if no change summary text is available in either case, use the AskUserQuestion tool to get:
- **Change summary**: A brief explanation of what the code does and what behavior to test
  - Examples: "User authentication with JWT", "File parsing with error handling", "API endpoint for CRUD operations"
  - For Non-Git mode: "Core business logic", "Utility functions", etc.

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

3. Record the combined list of changed files (diffed + untracked; exclude test files from this list, but read existing tests)

#### For Git Mode — Branch comparison:

1. Get the diff between base branch and target branch:
   ```bash
   git -C <project-path> diff <base-branch>...<target-branch> --name-only
   git -C <project-path> diff <base-branch>...<target-branch>
   git -C <project-path> log <base-branch>...<target-branch> --oneline
   ```

2. Record the list of changed files (exclude test files from diff, but read existing tests)

#### For Non-Git Mode:

1. Collect source code from specified files/directories:
   ```bash
   find <target-path> -type f \( -name "*.go" -o -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.rs" -o -name "*.java" \) 2>/dev/null
   ```

2. Read each file's content and record as targets

#### Common:

3. Detect the project's test framework and conventions:
   - Find existing test files and examine their structure:
     ```bash
     find <project-path> -type f \( -name "*_test.go" -o -name "*.test.js" -o -name "*.test.ts" -o -name "*.spec.js" -o -name "*.spec.ts" -o -name "test_*.py" -o -name "*_test.py" \) 2>/dev/null
     ```
     If the result has more than 20 entries, use only the first 20 (do not pipe through `head` — it is not declared in `allowed-tools`).
   - Read 2-3 existing test files to understand:
     - Test framework (Jest, Go testing, pytest, etc.)
     - Naming conventions
     - Helper functions and fixtures
     - Mocking patterns

4. Collect related CLAUDE.md files:
   - CLAUDE.md at project root
   - CLAUDE.md in directories containing target files

### Step 5: Parallel Test Generation

**For Git mode** (both uncommitted and branch comparison): Launch 5 parallel Sonnet agents
**For Non-Git mode**: Launch 4 parallel Sonnet agents (skip Agent #5)

If an agent fails or returns no response, continue with the results from the remaining agents.

Pass the following to each agent:
- Target file contents (Git mode: diff + full changed files, plus untracked files where applicable, Non-Git mode: full files)
- Change summary (from Step 3)
- Existing test examples (from Step 4)
- Test framework and conventions detected
- Related CLAUDE.md contents

**Agent #1: Happy Path Tests**
- Generate tests for normal/expected usage patterns
- Cover the main functionality of each changed/target function
- Test typical input values and expected outputs
- Test return values, side effects, and state changes

**Agent #2: Edge Case & Boundary Tests**
- Generate tests for boundary conditions (empty input, zero, nil/null, max values)
- Test off-by-one scenarios
- Test with unusual but valid inputs
- Test type coercion and format edge cases

**Agent #3: Error Handling Tests**
- Generate tests for error paths and failure modes
- Test invalid inputs and expected error responses
- Test timeout and resource exhaustion scenarios
- Test graceful degradation behavior
- Verify error messages are meaningful

**Agent #4: Integration Point Tests**
- Generate tests for function interactions and dependencies
- Test with mocked dependencies where appropriate
- Test data flow between components
- Test interface contracts (inputs/outputs match expectations)

**Agent #5: Regression & History-Based Tests** (Git mode only)
- Analyze git history for previously fixed bugs (untracked files have no history — skip them):
  ```bash
  git -C <project-path> log -p --follow --max-count=20 -- <file>
  ```
- Generate tests that would catch known regressions
- Generate tests based on patterns seen in past bug fixes

Each agent outputs test code in the following format:
```
- Target: <source-file-path>
- Test file: <proposed-test-file-path>
- Tests:
  <complete, runnable test code>
- Rationale: <brief explanation of what each test verifies>
```

### Step 6: Test Quality Scoring (Batch)

Collect ALL generated tests from Step 5 and pass them to a **single Haiku agent** for batch scoring.

Provide the agent with:
- The full list of generated tests from all agents
- The target source code
- The scoring criteria below

Scoring criteria (pass these criteria directly to the agent):
- **0**: Useless test. Tests implementation details, duplicates logic, or tests language features
- **25**: Low value. Tests obvious behavior that is unlikely to break. Tautological test
- **50**: Moderate value. Tests a real scenario but coverage overlap with other tests or limited additional confidence
- **75**: High value. Tests meaningful behavior, catches real bugs, uses proper assertions. Would catch a regression
- **100**: Essential test. Tests critical behavior, covers a known edge case or past bug. Must have for confidence

The agent returns a quality score (0/25/50/75/100) for each test.

### Step 7: Validation

For each test that scored >= 50 in Step 6, launch a **single Sonnet agent** to re-verify.

The validation agent receives:
- The filtered list of tests (those scoring >= 50)
- The relevant source code for each test
- The original agent's reasoning
- The full text of the Anti-Patterns section from this command

For each test, the validation agent must:
1. Re-read the target source code
2. Confirm the test is meaningful (not an anti-pattern from the Anti-Patterns section)
3. Return: **CONFIRMED** or **REJECTED** with a one-line reason

Remove REJECTED tests from the final output.

### Step 8: Filtering and Output

1. Filter out tests that were REJECTED in Step 7 or scored below 50 in Step 6

2. Group tests by target file and merge into coherent test files that follow project conventions. When multiple agents generate tests for the same function, deduplicate by keeping the higher-scored test and removing redundant ones

3. Use the AskUserQuestion tool to confirm:
   - **Output mode**: Write test files to disk, or display in chat only
   - If writing to disk, confirm file paths

4. Output final report:

---

## Test Generation Results

**Project**: <project-path>
**Mode**: Git mode (uncommitted changes) / Git mode (branch comparison) / Non-Git mode
**Target**:
  - Git mode (uncommitted): working tree vs HEAD
  - Git mode (branch comparison): <base-branch>...<target-branch>
  - Non-Git mode: <target-files-or-directories>
**Change summary**: <user-provided-summary>
**Test framework**: <detected framework>

### Generated Tests

**File: `<test-file-path>`**
- Tests generated: <count>
- Coverage focus: <what aspects are covered>
- Average confidence: <score>/100

```<language>
<complete test code>
```

### Test Summary

| Target File | Tests Generated | Avg Confidence | Categories Covered |
|------------|----------------|----------------|-------------------|
| <file> | <count> | <score>/100 | Happy path, Edge cases, ... |

### Not Generated (Rationale)

- <file-or-function>: <reason why tests were not generated (e.g., already well tested, pure configuration, trivial getter)>

---

If no meaningful tests could be generated:

### Test Generation Results

No meaningful tests generated. The target code is either already well-tested, purely declarative, or too tightly coupled to external systems for unit testing.

---

## Anti-Patterns (Consider in Steps 5, 6, and 7)

The following test patterns should be avoided:

- Tests that duplicate the implementation logic (testing `add(a,b)` by checking `a+b`)
- Tests that only verify mock behavior, not real code
- Tests that are tightly coupled to internal implementation details
- Tests for trivial getters/setters with no logic
- Tests that test the programming language itself (e.g., "array length works")
- Snapshot tests where the snapshot is just the current output with no verification of correctness
- Tests with no meaningful assertions (only checking "no error thrown")

## Notes

- Follow the project's existing test conventions exactly (framework, naming, structure)
- Generated tests must be complete and runnable without modification
- Don't generate tests for code that is already well-tested (check existing coverage)
- Don't use gh command (this is for local test generation)
- Always include target file references for each test
- Use TodoWrite tool to track progress
- Prefer testing behavior over implementation details

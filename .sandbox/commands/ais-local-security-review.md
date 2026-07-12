---
description: Run local security-focused code review (works even without a Git repository)
description-ja: ローカルセキュリティレビューを実行（Git リポジトリがなくても動作）
argument-hint: [project-path] [change summary]
allowed-tools: [Read, Glob, Grep, Bash(git:*), Bash(ls:*), Bash(find:*), Task, AskUserQuestion, TodoWrite]
---

# Local Security Review

Performs security-focused code review on local code. If a Git repository exists, it reviews either uncommitted changes or the diff between branches; otherwise, it reviews the specified files/directories. Focuses on vulnerabilities, injection risks, authentication/authorization flaws, and secret exposure.

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

3. If no valid project path was found in step 2 (empty `$ARGUMENTS`, no path-like token, or the token doesn't exist on disk), deduplicate the combined list from the two `find` commands in step 1 by directory path (a project may match both the `.git` search and the marker-file search), then use the AskUserQuestion tool to let the user select a project to review from the found projects. If no projects are found, ask the user to enter the project path manually.

4. Check if the selected project directory has `.git` and determine **Git mode** or **Non-Git mode**:
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

2. Try to infer the **review scope** from the 2nd-argument-onwards text (the raw remainder of `$ARGUMENTS` after the project path — the same text used as the change summary in Step 3), before asking anything:
   - If it contains a clear signal for uncommitted work (e.g. "staged", "unstaged", "uncommitted", "working tree", "ステージ", "未コミット", "作業ツリー") AND `git status --porcelain -uall` produced output, treat scope as **Uncommitted changes** and skip step 3 below.
   - Else if it contains a clear signal for comparing branches (e.g. "branch", "compare", "vs", "..", "against main", a branch name from the `branch -a` output), treat scope as **Branch comparison** and skip step 3 below (step 4 still runs to confirm which branches).
   - Otherwise, inference is inconclusive — fall through to step 3.

3. Only if the scope could not be inferred in step 2, use the AskUserQuestion tool to confirm the **review scope**:
   - **Uncommitted changes** (offer this option only if `git status --porcelain -uall` produced output): review the working tree against `HEAD` (`git diff HEAD`, plus untracked files reported by `status --porcelain`)
   - **Branch comparison**: review the diff between two branches

4. If the scope is **Branch comparison** (inferred or chosen above), use the AskUserQuestion tool to confirm:
   - **Base branch**: The branch to compare against — offer common candidates found in the `branch -a` output (e.g., main, master, develop) as options, with free-form input for anything else
   - **Target branch**: The branch to review (current branch by default)
   - If the chosen base and target are identical, tell the user the diff would be empty and ask again.

#### For Non-Git Mode:

1. Check the file structure within the project:
   ```bash
   find <project-path> -type f \( -name "*.go" -o -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.rs" \) 2>/dev/null
   ```
   If the result has more than 50 entries, use only the first 50 for the purpose of the selection prompt below (do not pipe through `head` — it is not declared in `allowed-tools`).

2. Use the AskUserQuestion tool to confirm:
   - **Review target**: Path(s) to files or directories to review (can be multiple)
   - Examples: `src/`, `internal/mcp/`, `main.go`, etc.

### Step 3: Change Summary Input

If a valid project path was found in Step 1 (the 1st argument), use the 2nd argument onwards as the change summary if provided, and skip AskUserQuestion.

If no valid project path was found in Step 1 (the entire `$ARGUMENTS` string was treated as the change summary), use that string directly as the change summary and skip AskUserQuestion.

Only if no change summary text is available in either case, use the AskUserQuestion tool to get:
- **Change summary**: A brief explanation of the purpose and background of the changes
  - Examples: "Adding user authentication", "API endpoint changes", "New input handling"
  - For Non-Git mode: "New implementation review", "Security audit", etc.

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

4. Read the full content of security-relevant configuration files in the project root (even if unchanged), for Agent #4:
   ```bash
   find <project-path> -maxdepth 2 -type f \( -name "package.json" -o -name "go.mod" -o -name "Cargo.toml" -o -name "Dockerfile" -o -name "nginx.conf" -o -name "*.yaml" -o -name "*.yml" -o -name ".env.example" \) 2>/dev/null
   ```
   If the result has more than 20 entries, use only the first 20 (do not pipe through `head` — it is not declared in `allowed-tools`).

#### For Git Mode — Branch comparison:

1. Get the diff between base branch and target branch:
   ```bash
   git -C <project-path> diff <base-branch>...<target-branch> --name-only
   git -C <project-path> diff <base-branch>...<target-branch>
   git -C <project-path> log <base-branch>...<target-branch> --oneline
   ```

2. Record the list of changed files

3. Read the full content of security-relevant configuration files in the project root (even if unchanged), for Agent #4:
   ```bash
   find <project-path> -maxdepth 2 -type f \( -name "package.json" -o -name "go.mod" -o -name "Cargo.toml" -o -name "Dockerfile" -o -name "nginx.conf" -o -name "*.yaml" -o -name "*.yml" -o -name ".env.example" \) 2>/dev/null
   ```
   If the result has more than 20 entries, use only the first 20 (do not pipe through `head` — it is not declared in `allowed-tools`).

#### For Non-Git Mode:

1. Collect source code from specified files/directories:
   ```bash
   find <target-path> -type f \( -name "*.go" -o -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.rs" -o -name "*.java" \) 2>/dev/null
   ```

2. Read each file's content and record as review targets

#### Common:

3. Collect related CLAUDE.md files:
   - CLAUDE.md at project root
   - CLAUDE.md in directories containing review target files

### Step 5: Parallel Security Review Execution

**For Git mode** (both uncommitted and branch comparison): Launch 5 parallel Sonnet agents
**For Non-Git mode**: Launch 4 parallel Sonnet agents (skip Agent #5)

If an agent fails or returns no response, continue with the results from the remaining agents.

Pass the following to each agent:
- Review target file contents (Git mode: diff plus untracked-file contents where applicable, Non-Git mode: full files)
- Change summary (from Step 3)
- Related CLAUDE.md contents

**Agent #1: Injection & Input Validation**
- SQL injection, NoSQL injection, command injection, LDAP injection
- XSS (reflected, stored, DOM-based)
- Path traversal and directory traversal
- Template injection (SSTI)
- Unsafe deserialization
- Missing or inadequate input validation and sanitization
- Race conditions and TOCTOU (time-of-check-time-of-use) vulnerabilities

**Agent #2: Authentication & Authorization**
- Broken authentication (weak password policies, missing MFA considerations)
- Broken access control (IDOR, privilege escalation, missing authorization checks)
- Session management flaws (insecure tokens, missing expiration, fixation)
- JWT misuse (algorithm confusion, missing validation, sensitive data in payload)
- Missing CSRF protection

**Agent #3: Data Exposure & Secret Handling**
- Hardcoded secrets, API keys, passwords, tokens in source code
- Sensitive data in logs (PII, credentials, tokens)
- Sensitive data in error messages exposed to users
- Missing encryption for data at rest or in transit
- Insecure storage of sensitive data
- Overly permissive CORS configuration

**Agent #4: Dependency & Configuration Security**
- Dependency configuration risks (pinning to wildcard versions, use of deprecated/archived packages, insecure registry sources). Note: for CVE scanning, recommend running `npm audit` / `govulncheck` separately
- Insecure default configurations
- Missing security headers
- Debug mode or verbose error output enabled in production
- Insecure TLS/SSL settings

**Agent #5: Git History Security Audit** (Git mode only)
- For each changed file from Step 4, check git blame and history (untracked files have no history — skip them):
  ```bash
  git -C <project-path> log -p --follow --max-count=20 -- <file>
  git -C <project-path> blame <file>
  ```
- Look for previously fixed security issues being reintroduced
- Check if security-sensitive code was changed without corresponding test updates
- Verify security patterns established in past commits are maintained

Each agent reports issues in the following format:
```
- File: <file-path>
- Line: <line-number>
- Issue: <description>
- Impact: Critical / High / Medium / Low
- Category: Injection / Auth / Data Exposure / Configuration / History
- CWE: CWE-<number> (if applicable)
```

### Step 6: Confidence Scoring (Batch)

Collect ALL issues from Step 5 and pass them to a **single Haiku agent** for batch scoring.

Provide the agent with:
- The full list of issues from all agents
- The review target code (diff or full files)
- The scoring criteria below

Scoring criteria (pass these criteria directly to the agent):
- **0**: No confidence. False positive or theoretical-only risk with no practical exploit path
- **25**: Somewhat confident. Possible issue but heavily context-dependent. May require specific conditions to exploit
- **50**: Moderately confident. Real vulnerability but low severity or requires unusual conditions to exploit
- **75**: Quite confident. Verified vulnerability with a plausible exploit path. Directly affects security posture
- **100**: Absolutely confident. Verified vulnerability that is easily exploitable. Immediate security risk

The agent returns a confidence score (0/25/50/75/100) for each issue.

### Step 7: Validation

For each issue that scored >= 50 in Step 6, launch a **single Sonnet agent** to re-verify.

The validation agent receives:
- The filtered list of issues (those scoring >= 50)
- The relevant source code for each issue
- The original agent's reasoning
- The full text of the False Positive Examples section from this command

For each issue, the validation agent must:
1. Re-read the cited code location
2. Confirm the issue is real (not a false positive from the examples in the False Positive section)
   - For issues scored 50–74: confirm if the vulnerability is real, even if exploitation requires specific conditions
   - For issues scored ≥ 75: apply strict verification — confirm only if the issue has a plausible exploit path
3. Return: **CONFIRMED** or **REJECTED** with a one-line reason

Remove REJECTED issues from the final report.

### Step 8: Filtering and Report Generation

1. Filter out issues that were REJECTED in Step 7 or scored below 50 (lower threshold than general review since security issues are more critical)

2. Output final report in the following format:

---

## Security Review Results

**Project**: <project-path>
**Mode**: Git mode (uncommitted changes) / Git mode (branch comparison) / Non-Git mode
**Review target**:
  - Git mode (uncommitted): working tree vs HEAD
  - Git mode (branch comparison): <base-branch>...<target-branch>
  - Non-Git mode: <target-files-or-directories>
**Change summary**: <user-provided-summary>

### Critical / High Issues

Issues with confidence >= 75:

**Issue 1**: <Brief description of the issue>
- File: `<file-path>`
- Line: L<start>-L<end>
- Impact: <Critical / High>
- Category: <Injection / Auth / Data Exposure / Configuration / History>
- CWE: CWE-<number>
- Confidence: <score>/100

```diff
<relevant code snippet>
```

**Recommendation**: <specific fix suggestion>

### Medium / Low Issues

Issues with confidence 50-74:

(Same format as above)

---

If no issues were found:

### Security Review Results

No security issues found. Checked for injection vulnerabilities, authentication/authorization flaws, data exposure, and configuration security.

---

## False Positive Examples (Consider in Steps 5 and 6)

The following should be excluded as false positives:

- Theoretical vulnerabilities with no practical exploit path in this context
- Issues behind multiple layers of existing security controls
- Issues that only apply to different deployment contexts
- Security patterns that are intentionally relaxed for development/testing (if clearly marked)
- Issues that linters, SAST tools, or type checkers would already detect

For Git mode only:
- Existing vulnerabilities (not introduced in this PR)
- Security issues on lines not changed by the user in the PR

## Notes

- Don't run builds or type checks (those are run separately in CI)
- Don't use gh command (this is for local review)
- Always include file and line links for each issue
- Use TodoWrite tool to track progress
- Focus on actionable findings, not security best practice lectures

---
description: Review comments in source code/scripts for objective accuracy, first-read clarity, appropriate detail, and whether they're worth having at all (works even without a Git repository)
description-ja: ソースコード・スクリプトのコメントの客観的妥当性・初見でのわかりやすさ・過不足・存在意義をレビュー（Git リポジトリがなくても動作）
argument-hint: [path]
allowed-tools: [Read, Glob, Bash(find:*), Bash(test:*), Bash(head:*), Task, AskUserQuestion, TodoWrite]
---

# Local Comment Review

Reviews comments in source code and scripts, regardless of whether they were touched recently — this scans the full content of the target files, not just a diff. It complements `/ais-local-review`'s Agent #4 (which only checks comments introduced in a diff) and is distinct from `/ais-local-doc-review` (which reviews prose documentation files, not in-code comments).

## Language

Detect the user's language from their previous messages in the conversation. Output all review results, issue descriptions, and recommendations in the same language the user uses. If uncertain, follow the session's default response language (see CLAUDE.md's "Response Language" rule / sandbox-mcp's language signal); only fall back to English if no such signal is available.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: A file or directory path (absolute or relative) — the first whitespace-delimited token in `$ARGUMENTS`, if it looks like a path (starts with `/`, `./`, `../`, or contains `/`) and actually exists on disk.
- If no such token exists, or it doesn't exist on disk, fall through to Step 1's project search / selection prompt.

## Execution Steps

Follow these steps precisely:

### Step 1: Target Selection

1. Take the first whitespace-delimited token of `$ARGUMENTS`. If it looks like a path, verify it exists on disk:
   ```bash
   test -e <candidate-token> && echo "VALID_PATH" || echo "NOT_A_PATH"
   ```
   If it exists, use it as `<target-path>` and skip the fallback search below.

2. Only if no valid target path was found above, search for projects under `/workspace` to offer as candidates:
   ```bash
   find /workspace -maxdepth 3 -type d -name ".git" 2>/dev/null | head -30
   find /workspace -maxdepth 2 -type f \( -name "package.json" -o -name "go.mod" -o -name "Cargo.toml" -o -name "pyproject.toml" -o -name "Makefile" \) 2>/dev/null | head -30
   ```
   Derive project directories from the results yourself (strip trailing `/.git`, or take the containing directory of matched marker files) — do not pipe through `sed`, `xargs`, or `dirname` (not declared in `allowed-tools`). Deduplicate by directory path, then use the AskUserQuestion tool to let the user pick a project, file, or directory to review (free-form input allowed for a specific subdirectory or file). If nothing is found, ask the user to enter a path manually.

### Step 2: Retrieve and Analyze Review Targets

1. Find candidate source/script files under `<target-path>`:
   - **Shortcut**: If `<target-path>` is itself a single file, skip the `find` below — set `<target-file-paths>` to that one file directly and proceed to the Read step below.
   - Otherwise:
     ```bash
     find <target-path> -type f \
       -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/vendor/*" \
       -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/.next/*" -not -path "*/target/*" \
       -not -path "*/.venv/*" -not -path "*/venv/*" -not -path "*/__pycache__/*" \
       -not -path "*/.tox/*" -not -path "*/.mypy_cache/*" -not -path "*/.pytest_cache/*" \
       -not -path "*/.terraform/*" -not -path "*/.cache/*" -not -path "*/coverage/*" \
       -not -name "*.min.js" -not -name "*.min.css" \
       -not -name "*.lock" -not -name "*-lock.json" -not -name "*.lockb" -not -name "*.sum" \
       -not -name "*.md" -not -name "*.rst" -not -name "*.txt" -not -name "*.adoc" \
       -size -500k \
       2>/dev/null | head -101
     ```
     (`*.md`/`*.rst`/`*.txt`/`*.adoc` are excluded — that's `/ais-local-doc-review`'s territory. The `.venv`/`__pycache__`/`.tox`/`.mypy_cache`/`.pytest_cache`/`.terraform`/`.cache`/`coverage` exclusions keep third-party/dependency and cache directories from silently consuming the 100-file cap in place of the project's own source.)

     If exactly 101 lines are returned, more than 100 files matched: use only the first 100 as `<target-file-paths>` and tell the user the scope was truncated to the first 100, suggesting a narrower `<target-path>` for a full pass. If fewer than 101 lines are returned, no truncation occurred — use all of them as `<target-file-paths>`.

     If the result is empty (e.g., an invalid path, or a directory containing only excluded file types), tell the user no reviewable files were found under `<target-path>` and stop — do not proceed to Step 3, and do not report "No issues found" as if a review had actually taken place.

2. Read each file in `<target-file-paths>` with the Read tool and record its content as `<target-files>`. Skip files that are clearly binary.

3. Collect related CLAUDE.md files (use Glob): CLAUDE.md at the project root and in directories containing target files. These may define project-specific comment conventions (e.g. a mandated scaffolding-log marker) that agents must not flag as noise.

### Step 3: Parallel Comment Review Execution

Launch 4 parallel Sonnet agents. If an agent fails or returns no response, continue with the results from the remaining agents.

Pass to every agent:
- Full content of `<target-files>` (not a diff — review every comment present, not just recently changed ones)
- Related CLAUDE.md contents (for project-specific comment conventions)
- The full text of the False Positive Examples section from this command (so agents avoid raising issues that Steps 4–5 would filter out anyway)

**Agent #1: Objective Accuracy** (Category: `Accuracy`)
Issue ID prefix: `A1-`
- Comments that contradict what the code actually does
- Comments describing behavior, parameters, or return values that no longer match the implementation (stale after a rename/refactor)
- Factually wrong claims (wrong units, wrong preconditions, wrong complexity/ordering guarantees)
- References to variables, functions, files, or config keys that no longer exist under that name

**Agent #2: First-Read Clarity** (Category: `Clarity`)
Issue ID prefix: `A2-`
- Comments that assume tribal knowledge a newcomer to the file wouldn't have
- Unexplained jargon, acronyms, or abbreviations
- Ambiguous wording, or pronouns ("this", "it") with an unclear antecedent
- Comments phrased so ambiguously they could mislead a first-time reader about intent
- Inconsistent terminology for the same concept across nearby comments

**Agent #3: Excess or Deficiency** (Category: `Balance`)
Issue ID prefix: `A3-`
- Redundant comments that just restate the line below in words (e.g. `// increment i` above `i++`)
- Comment blocks disproportionately long relative to the code's actual complexity
- Duplicated comments repeated near-verbatim at multiple nearby sites — including reciprocal pairs across two related files (e.g. script A's header explains why it defers to script B, and script B's header explains the same division of labor back), where the second occurrence adds no information the first didn't already establish
- Non-obvious logic, hidden constraints, or workarounds that have **no** comment explaining the "why" (a real gap, not a demand for line-by-line narration)
- Commented-out dead code left with no explanation of why it's kept

**Agent #4: Whether It's Worth Having** (Category: `Necessity`)
Issue ID prefix: `A4-`
- Comments with zero informational value beyond what the identifier name already says
- Stale TODO/FIXME with no path forward (no owner, date, or ticket reference), or ones referencing already-resolved work — distinct from Agent #1's stale-description check: the concern here is the marker's actionability, not whether it correctly names current symbols (a TODO that names a since-renamed symbol is Agent #1's finding; a TODO with no owner/path-forward, regardless of naming accuracy, belongs here)
- Unfilled placeholder/template comments (e.g. "TODO: describe this")
- Comments referencing removed features, deprecated tools, or defunct processes
- Leftover auto-generated boilerplate comments (e.g. unedited IDE/scaffold templates) that carry no project-specific meaning
- Comments narrating the *process* behind a change — "rather than doing X we did Y", "this reverses the original rationale for Z", "previously this ran as a side effect of W" — when that narrative has no bearing on how to safely read or modify the code today. This is commit-message/PR-description content, not durable documentation, and is a common pattern in AI-authored refactor comments (the assistant externalizes the reasoning it used *during* the task rather than the constraint a future reader needs). Only flag the narrative portion: if the same sentence also encodes a live constraint (e.g. a warning against re-merging two concerns, or why a seemingly-duplicate mechanism must stay split), keep the constraint and flag just the surrounding history for trimming — don't recommend deleting the whole comment.
- Present-tense "ownership boundary" comments that justify a design split by appeal to an abstract goal — "X remains owned exclusively by Y, so documentation about X can point at exactly one place", "for consistency", "so callers have a single place to look" — rather than by naming a concrete mistake the reader could otherwise make. Test it: would a reader who saw *only the surrounding code* (no comment) actually be tempted to do the thing the comment warns against? If the code already makes the boundary self-evident — e.g. the "don't inline this here" comment sits above a function whose entire body is a single call out to the other script, with no inlined logic anywhere nearby to tempt merging — the rule-statement itself is decorative, not load-bearing, even though it's phrased as a directive ("never do X here"). Flag the whole comment in that case, not just a narrative sub-portion. This pattern often appears as near-mirror comments in two related files, each explaining why it doesn't do the other's job — check sibling/paired files for the reciprocal half.

Each agent reports issues in the following format:
```
- ID: <agent-prefix>-<sequential-number> (e.g. A1-1, A1-2, … for Agent #1; A2-1, A2-2, … for Agent #2; etc.)
- File: <file-path>
- Line: L<start>-L<end> (the comment plus its immediately surrounding code)
- Issue: <description>
- Impact: Critical / High / Medium / Low
- Category: Accuracy / Clarity / Balance / Necessity (fixed per agent: Agent #1 always writes `Accuracy`, #2 `Clarity`, #3 `Balance`, #4 `Necessity` — see each agent's heading above)
- Reasoning: <brief explanation of why this is an issue>
- Recommendation: <specific rewrite or removal suggestion, carried through unchanged to the final report>
```

### Step 4: Confidence Scoring (Batch)

Collect ALL issues from Step 3 and pass them to a **single Haiku agent** for batch scoring.

Provide the agent with:
- The full list of issues from all agents
- The full content of the relevant target files
- The full text of the False Positive Examples section from this command
- The scoring criteria below

Scoring criteria (pass these criteria directly to the agent — each band is defined by what a first-time reader would *do*, not just how confused they'd feel):
- **0**: No confidence. Style preference, or matches a False Positive example
- **25**: Somewhat confident. A newcomer might pause briefly but would correctly infer the intent from the surrounding code within a few seconds, without acting on the wrong understanding
- **50**: Moderately confident. A newcomer could genuinely be confused for a moment, but nearby code or comments let them self-correct before acting on the wrong understanding
- **75**: Quite confident. A newcomer would likely act on the wrong understanding (e.g. call the function incorrectly, skip a required step) before catching the error themselves
- **100**: Absolutely confident. The comment states something demonstrably false about the code (verifiable by reading the code directly), or provides zero information beyond what the identifier name already says

The agent returns a confidence score for each issue in the format `<ID>: <score>` (one per line), using the issue IDs assigned in Step 3.

If the scoring agent does not return a score for a given issue, treat it as a score of 0 (fail safe).

### Step 5: Validation

Launch **one single Sonnet validation agent** and pass it ALL issues that scored >= 75 in Step 4 (do not launch one agent per issue). If no issues scored >= 75, skip this step.

The validation agent receives:
- The filtered list of issues (those scoring >= 75)
- The relevant source content for each issue
- The original agent's reasoning
- The full text of the False Positive Examples section from this command

For each issue, the validation agent must:
1. Re-read the cited code location
2. Confirm the issue is real (not a false positive from the examples below)
3. Return: **CONFIRMED** or **REJECTED** with a one-line reason

If the validation agent does not return a verdict for an issue, treat it as REJECTED (fail safe).

Remove REJECTED issues from the final report.

### Step 6: Filtering and Report Generation

1. Filter out issues that were REJECTED in Step 5 or scored below 75 in Step 4.

2. For each remaining issue, populate the report's `Recommendation` field directly from the `Recommendation` field the reporting agent produced in Step 3, and extract the `diff` snippet from the target file's already-read content at the cited `Line: L<start>-L<end>` range.

3. Output final report in the following format:

---

## Comment Review Results

**Review target**: <target-path>
**Files reviewed**: <count> files

### Issues Found

If issues were found, list each one like this:

**Issue 1** (<internal-ID, e.g. A3-2>): <Brief description of the issue>
- File: `<file-path>`
- Line: L<start>-L<end>
- Impact: <Critical / High / Medium / Low>
- Category: <Accuracy / Clarity / Balance / Necessity>
- Confidence: <score>/100

```diff
<relevant comment + surrounding code>
```

**Recommendation**: <specific rewrite or removal suggestion>

If no issues were found, replace this entire section's content with:

No issues found. Checked comments for objective accuracy, first-read clarity, excess/deficiency, and whether each comment justifies its own existence.

---

## False Positive Examples (Consider in Steps 3, 4, and 5)

The following should be excluded as false positives:

- Comment formatting/style preferences, as long as the content is clear and correct
- License headers and codegen tool banners bearing a recognizable generator signature (e.g. protobuf/gRPC notices) — intentional, not boilerplate noise. Does not cover unedited IDE/scaffold template comments with no generator-specific signature — those remain Agent #4's target.
- Comments required by a doc-generation convention (JSDoc, Godoc, docstrings) even when they restate the signature — that repetition is structurally expected by the tooling
- TODO/FIXME that references a specific ticket/issue ID — not "meaningless" just because the work isn't done yet
- Scaffolding-log markers matching this project's CLAUDE.md convention (`// TODO: remove after debugging - scaffolding log` or its Japanese equivalent) — intentional and expected, not stale
- Comments in test fixtures/mocks that describe the expected behavior being set up for a test, as long as that description still matches the fixture's current behavior (a stale description is an Agent #1 accuracy finding, not a false positive)
- Comments in a language other than the surrounding code's dominant language, when that matches CLAUDE.md's documented language policy for that area
- Historically-framed comments where the history *is* the constraint (e.g. "don't merge this back into X — it was split out on purpose") — only the surrounding pure-narrative padding is fair game, not comments where the past tense is load-bearing. This exemption requires the constraint to be genuinely non-obvious from the code alone: if the surrounding code already makes the split self-evident (e.g. the only thing here is a call to the other script — there is no inlined logic present that a reader could plausibly mistake for the wrong place to extend), the "don't merge it back" framing is not actually load-bearing and does not qualify for this exemption

## Notes

- Don't run builds or type checks (those are run separately in CI)
- Don't use gh command (this is for local review)
- This command is read-only — never edit target files, even to "just fix" an obvious issue
- Always include file and line references for each issue
- Use TodoWrite tool to track progress
- This reviews comments regardless of Git history — do not skip an issue merely because the comment predates recent changes

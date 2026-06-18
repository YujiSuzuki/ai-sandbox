---
description: Review design documents for internal consistency, completeness, implementability, and unresolved items (works even without a Git repository)
description-ja: 設計書の内部整合性・網羅性・実装可能性・未解決項目をレビュー（Git リポジトリがなくても動作）
argument-hint: [design-doc-path-or-dir] [context]
allowed-tools: [Read, Glob, Grep, Bash(git:*), Bash(ls:*), Bash(find:*), Task, AskUserQuestion, TodoWrite]
# Task is used in Step 4 to launch parallel Sonnet agents
---

# Local Design Document Review

Reviews design documents (specifications, implementation plans, feature designs) for internal consistency, cross-document consistency, completeness, implementability, and unresolved items. Intended for use **before implementation begins** — compares design docs against each other and against project rules in CLAUDE.md, not against existing code.

## Language

Detect the user's language from their previous messages in the conversation. Output all review results, issue descriptions, and recommendations in the same language the user uses. If uncertain, default to English.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: Path to a design document file or directory containing design docs (interactive selection if omitted)
- 2nd argument onwards: Optional context (e.g., "Phase 3 implementation plan", "new payment feature spec")

## Execution Steps

Follow these steps precisely.

### Step 1: Locate Design Documents

1. Determine the review target from $ARGUMENTS:
   - If a file path is given, use that file directly
   - If a directory path is given, find all design docs within:
     ```bash
     find <dir-path> -type f \( -name "*.md" -o -name "*.rst" -o -name "*.txt" \) -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null
     ```
   - If $ARGUMENTS is empty, search for design/spec doc directories under `/workspace`:
     ```bash
     find /workspace -maxdepth 3 -type d \( -name "docs*" -o -name "design*" -o -name "spec*" \) -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null
     ```
     Then use AskUserQuestion to let the user select the target

   **If no files are found after all of the above**: use AskUserQuestion to notify the user that no design documents were found and ask them to provide the path manually. Do not proceed until a valid path is given.

2. Read all identified design documents in full.

3. Find and read related CLAUDE.md files (these encode project-specific rules to check compliance against):
   ```bash
   find /workspace -maxdepth 3 -name "CLAUDE.md" -not -path "*/.git/*" 2>/dev/null
   ```

4. Collect any existing source code files **explicitly named** in the design docs (to check consistency with already-implemented portions, if any). Do not speculatively read source files — only those directly referenced.

5. Optionally gather recent git history for context (does not affect review scope):
   ```bash
   git -C <nearest-project-root> log --oneline -10 2>/dev/null || true
   ```

### Step 2: Context Input

If the 2nd argument is provided, use it as context and skip AskUserQuestion.

Only if omitted, use AskUserQuestion to ask:
- **Context**: What is this design about? Any background the reviewer should know?
  - Examples: "Phase 3 of payment feature", "New onboarding flow spec", "Database schema redesign"

### Step 3: Classify Design Document Type

Before launching review agents, classify the design documents by reading their structure:
- **Phased implementation plan**: Has numbered phases, each with tasks and test/UT items
- **Feature spec**: Describes a feature's UI, data model, and behavioral rules
- **Architecture / API design**: Describes system structure, interfaces, or data flow
- **Mixed**: Combination of the above

Include this classification in the prompt passed to each agent in Step 4 so that agents can prioritize accordingly. Do not store it separately — embed it directly in each agent's prompt.

Also detect the user's output language from previous messages (default: English) and record it for use in Step 4.

### Step 4: Parallel Design Review Execution

Launch 5 parallel Sonnet agents. Pass to each agent:
- Full content of all design documents
- Full content of CLAUDE.md files collected in Step 1
- Context from Step 2
- Document type classification from Step 3
- Content of any referenced source files collected in Step 1
- Output language detected in Step 3 (instruct agents: "Output all results in <language>")
- False Positives criteria (full text of the "False Positives" section at the end of this document)

---

**Agent #1: Internal Consistency**

Check within each design document for contradictions or ambiguities that would confuse an implementer reading only that document:

- Contradictory statements in different sections (e.g., "field X is required" in one section, "field X is optional" in another)
- The same concept referred to by different names without a stated alias
- Data model attributes or API fields referenced in behavior/UI sections but never formally defined in the model section
- Numbered items that are out of order, skip numbers, or have duplicate numbers
- A phase or step listed as a prerequisite for itself
- Behavior described as both synchronous and asynchronous without reconciliation

Report format:
```
- File: <file-path>
- Section: <heading or line range>
- Issue: <description>
- Impact: Critical / High / Medium / Low
- Category: InternalConsistency
- Excerpt: <verbatim quote of the relevant text from the design document, 1–5 lines>
```

---

**Agent #2: Cross-Document Consistency**

Check across all provided design documents for divergence:

- The same feature described with conflicting rules in two different documents
- Data field names, types, or constraints that differ between documents
- Phase numbering or naming that does not match between a summary document and a detail document
- A cross-reference ("see doc X, section Y") where the referenced content says something different from the referencing document
- A term defined in one document but used with a different meaning in another
- A decision recorded as "decided" in one document and "TBD" in another

Report format: same as Agent #1 with Category: CrossDocConsistency (include Excerpt from both conflicting locations if applicable)

---

**Agent #3: Completeness & Edge Cases**

For each feature, screen, or behavior described, check whether the design covers:

- **Empty / zero-data states**: What does the UI or API show when there is no data yet?
- **Error states**: Network failure, permission denied, API error, invalid input — are these handled?
- **Boundary conditions**: First use, last item, maximum or minimum limits
- **Async / concurrent behavior**: If operations are async, what happens if two run simultaneously?
- **Data migration / backward compatibility**: If an existing data model is changed, how are old records handled?
- **Partial failure / rollback**: If a multi-step operation fails midway, what is the recovery path?
- **Authorization / access control**: Who is allowed to perform each action? What happens if an unauthorized user tries?
- **Localization / internationalization**: If the app targets multiple locales, are locale-sensitive behaviors specified?

For phased plans specifically:
- Are prerequisite states for each phase's test items achievable using only features from that phase and prior phases?

Report format: same as Agent #1 with Category: Completeness (Excerpt should quote the feature description that is missing the edge case coverage)

---

**Agent #4: Implementability & Phase Dependencies**

Check whether the design can actually be built as written:

- **Circular dependencies**: Phase A requires Phase B which requires Phase A (directly or transitively)
- **Forward dependencies in tests**: A phase's test/UT items require a feature that is only introduced in a later phase — flag which phase the test should move to
- **Mutually exclusive constraints**: Two requirements that cannot both be satisfied simultaneously
- **Underspecified behavior**: Vague directives like "display appropriately", "handle gracefully", or "as needed" without a concrete definition
- **Missing integration points**: Feature X writes data to a store, but no spec describes how or when feature Y reads it
- **Implementation method conflicts**: Two sections that imply different implementation approaches (e.g., one implies synchronous, another implies batch/async) for the same feature

For phased plans, verify that each phase can be independently built and tested using only the phases that precede it.

Report format: same as Agent #1 with Category: Implementability (Excerpt should quote the conflicting or underspecified requirement)

---

**Agent #5: Unresolved Items & Project Rule Compliance**

**Part A — Unresolved items:**

Flag any item that is not explicitly deferred to a named future document or phase and appears as:
- ⚠️ markers without a resolution recorded
- TBD, TODO, "未定", "確認中", "未確定", "要確認", "事前確認必須", "仕様確認後に追加", "確認中" or similar
- "Assumed to work as…" statements where the assumption is not verified
- Decisions marked as needing user/stakeholder confirmation with no confirmation recorded

**Part B — CLAUDE.md rule compliance:**

Read the CLAUDE.md files and check whether this design violates any stated project rules. Common patterns to check (adapt to whatever CLAUDE.md actually says):
- Design requires a data schema change → does the design include a migration plan if CLAUDE.md requires one?
- Design omits UT/test items for features → if CLAUDE.md states UT is mandatory, flag missing test sections
- Design cites external API behavior that is not sourced from official documentation → if CLAUDE.md prohibits unverified API assumptions, flag these
- Design conflicts with a "never do X" rule stated in CLAUDE.md

Only flag CLAUDE.md compliance issues if CLAUDE.md actually states a rule that this design appears to break. Do not invent rules.

Report format: same as Agent #1 with Category: UnresolvedItems (Excerpt should quote the unresolved marker or the conflicting CLAUDE.md rule and the violating design text)

---

### Step 5: Confidence Scoring (Batch)

Collect ALL issues from Step 4 and pass them to a **single Haiku agent** for batch scoring.

Provide the agent with:
- The full list of issues from all five agents, each including the **excerpt text already quoted by the reporting agent** (do NOT pass the full design document — only the excerpts embedded in each issue report)
- The scoring criteria below

Scoring criteria (pass these directly to the agent):
- **0**: Subjective stylistic preference with no functional impact
- **25**: Minor ambiguity that an implementer would likely resolve correctly on their own
- **50**: Real gap or inconsistency, but unlikely to cause a wrong implementation in practice
- **75**: Clear problem that would likely cause incorrect implementation or require rework after the fact
- **100**: Definite blocker — contradictory specs, circular dependency, or a decision that must be made before implementation can start

The agent returns a confidence score (0 / 25 / 50 / 75 / 100) for each issue, using the format `ISSUE-N: <score>`. If an issue's Excerpt field is missing, score it 50 and append "(No excerpt provided)" after the score.

### Step 6: Validation

For each issue scoring >= 75 in Step 5, launch a **single Sonnet agent** to re-verify.

The validation agent receives:
- The filtered list of issues (those scoring >= 75)
- The relevant design document excerpts for each issue
- The original agent's reasoning

For each issue, the validation agent must:
1. Re-read the relevant excerpts provided
2. Determine whether the issue is genuine or a false positive (see False Positives section below)
3. Return exactly `ISSUE-N: CONFIRMED` or `ISSUE-N: REJECTED — <one-line reason>`

Remove REJECTED issues from the final report.

### Step 7: Report Generation

Filter to issues that scored >= 75 and were CONFIRMED in Step 6. If this filtered set is empty (no issues found, all scored < 75, or all rejected), output the "no issues found" template below instead.

Output the final report in this format:

---

## Design Document Review Results

**Review target**: <file or directory path>
**Context**: <from Step 2>
**Document type**: <from Step 3>
**Files reviewed**: <count> design documents

### Issues Found

**Issue 1**: <brief title>
- File: `<file-path>`
- Section: <heading or line range>
- Impact: Critical / High / Medium / Low
- Category: InternalConsistency / CrossDocConsistency / Completeness / Implementability / UnresolvedItems
- Confidence: <score>/100

```
<relevant excerpt from the design document>
```

**Recommendation**: <concrete, actionable suggestion>

---

If no issues were found:

### Design Document Review Results

No issues found. Checked for internal consistency, cross-document consistency, completeness, implementability, phase dependencies, and unresolved items.

---

## False Positives (Consider in Steps 4, 5, and 6)

Do NOT flag as issues:

- Decisions intentionally deferred with a clear label: "to be decided in Phase N", "out of scope for this document", "will be specified in doc X"
- Design choices that are unconventional but internally consistent and unambiguous
- UI copy, color, or visual details explicitly left to implementation-time discretion
- Missing implementation details for well-understood standard patterns, when the design explicitly delegates those details (e.g., "use standard pagination")
- Documents that intentionally supersede an older document, when this relationship is stated
- Test items that require a feature from the same phase (not a future phase)

## Notes

- Do not run builds or type checks
- Do not use the gh command
- Always cite the specific file, section, and line range for each issue
- Use TodoWrite to track progress through steps
- When reading existing source code for context, focus on data model and interface definitions — full implementation logic is usually not needed for design review

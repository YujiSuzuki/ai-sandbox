---
description: Review design documents (specs) for quality — completeness, consistency, realization clarity, test validity, and unresolved items (works even without a Git repository)
description-ja: 設計書（仕様書）の品質レビュー — 仕様の網羅性・整合性・実現方式の明確さ・テスト項目の妥当性・未解決事項（Git リポジトリがなくても動作）
argument-hint: [spec-doc-path-or-dir] [context]
allowed-tools: [Read, Glob, Grep, Bash(git:*), Bash(ls:*), Bash(find:*), Task, AskUserQuestion, TodoWrite]
# Task is used in Step 4 to launch parallel Sonnet agents
---

# Local Spec Review

Reviews design documents / specification files for their **own quality** — not whether implementation follows them, but whether the documents themselves are well-written, complete, consistent, and ready to be handed to an implementer.

Use this command **before implementation begins** to catch problems in the spec itself.

## Language

Detect the user's language from their previous messages in the conversation. Output all review results, issue descriptions, and recommendations in the same language the user uses. If uncertain, default to English.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: Path to a spec/design doc file or directory containing spec docs (interactive selection if omitted)
- 2nd argument onwards: Optional context (e.g., "Phase 3 plan for new feature", "payment flow spec")

## Execution Steps

Follow these steps precisely.

### Step 1: Locate Spec Documents

1. Determine the review target from $ARGUMENTS:
   - If a file path is given, use that file directly
   - If a directory path is given, find all spec/design docs within:
     ```bash
     find <dir-path> -type f \( -name "*.md" -o -name "*.rst" -o -name "*.txt" \) -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null
     ```
   - If $ARGUMENTS is empty, search for spec/design doc directories under `/workspace`:
     ```bash
     find /workspace -maxdepth 3 -type d \( -name "docs*" -o -name "design*" -o -name "spec*" \) -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null
     ```
     Then use AskUserQuestion to let the user select the target.

   **If no files are found**: use AskUserQuestion to notify the user and ask for the path manually. Do not proceed until a valid path is given.

2. Read all identified spec documents in full.

3. Find and read related CLAUDE.md files (project-specific rules that may affect spec quality standards):
   ```bash
   find /workspace -maxdepth 3 -name "CLAUDE.md" -not -path "*/.git/*" 2>/dev/null
   ```

4. Do **NOT** speculatively read source code files. Only read a source file if the spec document explicitly names it AND checking it is necessary to judge an issue.

5. Optionally gather recent git history for context (does not affect review scope):
   ```bash
   git -C <nearest-project-root> log --oneline -10 2>/dev/null || true
   ```

### Step 2: Context Input

If the 2nd argument is provided, use it as context and skip AskUserQuestion.

Only if omitted, use AskUserQuestion to ask:
- **Context**: What is this spec about? Any background the reviewer should know?
  - Examples: "Phase 3 of new feature", "onboarding flow redesign spec"

### Step 3: Classify Spec Document Type

Before launching review agents, classify the documents by reading their structure:
- **Phased implementation plan**: Has numbered phases, each with tasks and test/UT items
- **Feature spec**: Describes a feature's UI, data model, and behavioral rules
- **Architecture / API design**: Describes system structure, interfaces, or data flow
- **Mixed**: Combination of the above

Include this classification in the prompt passed to each agent in Step 4 so agents can prioritize accordingly. Also detect the user's output language from previous messages (default: English) and record it for use in Step 4.

### Step 4: Parallel Spec Review Execution

Launch 5 parallel Sonnet agents. Pass to each agent:
- Full content of all spec documents
- Full content of CLAUDE.md files collected in Step 1
- Context from Step 2
- Document type classification from Step 3
- Output language detected in Step 3 (instruct agents: "Output all results in <language>")
- False Positives criteria (full text of the "False Positives" section at the end of this document)

---

**Agent #1: Accuracy & Internal Consistency**

Check within each spec document for contradictions or ambiguities that would confuse an implementer reading only that document:

- Contradictory statements in different sections (e.g., "field X is required" in one section, "field X is optional" in another)
- The same concept referred to by different names without a stated alias
- Numeric values, constants, IDs, or limits that differ between sections of the same document
- A term defined in one section but used with a different meaning in another
- Decisions recorded as both "decided" and "TBD" in the same document
- Data model attributes or API fields referenced in behavior/UI sections but never formally defined in the model section
- A decision marked as "confirmed" but with no actual confirmation recorded
- Numbered items that are out of order, skip numbers, or have duplicate numbers
- A phase or step listed as a prerequisite for itself (directly or transitively)
- Behavior described as both synchronous and asynchronous in different sections without reconciliation

Report format:
```
- File: <file-path>
- Section: <heading or line range>
- Issue: <description>
- Impact: Critical / High / Medium / Low
- Category: Accuracy
- Excerpt: <verbatim quote of the relevant text, 1–5 lines>
```

---

**Agent #2: Cross-Document Consistency & Terminology**

Check across all provided spec documents for divergence:

- The same feature described with conflicting rules in two different documents
- Data field names, types, constraints, or numeric values that differ between documents
- Phase numbering or naming that does not match between a summary document and a detail document
- A term defined in one document but used with a different meaning in another
- A cross-reference ("see doc X, section Y") where the referenced content contradicts the referencing document
- Feature names or terminology that are inconsistently used (e.g., same feature called by two different names across documents)
- A decision recorded as "decided" in one document and "TBD" in another

Report format: same as Agent #1 with Category: Consistency (include Excerpt from both conflicting locations if applicable)

---

**Agent #3: Completeness & Edge Cases**

For each feature, screen, or behavior described, check whether the spec covers what an implementer would need:

- **Empty / zero-data states**: What does the UI or API show when there is no data yet?
- **Error states**: Network failure, permission denied, API error, invalid input — are these specified?
- **Boundary conditions**: First use, last item, maximum or minimum values
- **Async / concurrent behavior**: If operations are async, what happens if two run simultaneously?
- **Data migration / backward compatibility**: If an existing data model is changed, are old records handled?
- **Partial failure / rollback**: If a multi-step operation fails midway, what is the recovery path?
- **Authorization / access control**: Who is allowed to perform each action?
- **Ambiguous directives**: Vague instructions like "display appropriately", "handle gracefully", or "as needed" without concrete definitions
- **Missing integration points**: Feature X writes data to a store, but no spec describes how or when feature Y reads it

For phased plans specifically:
- Are prerequisite states for each phase's test items achievable using only features from that phase and prior phases?

Report format: same as Agent #1 with Category: Completeness (Excerpt should quote the feature description that is missing the coverage)

---

**Agent #4: Realization Method Clarity & Phase Dependencies**

Check whether each feature's implementation approach is clear enough that an implementer cannot misinterpret it:

- **Underspecified realization method**: Is the approach (Batch / real-time / polling / push / etc.) clearly stated, or left ambiguous?
- **Implementation method conflicts**: Two sections that imply different approaches for the same feature (e.g., one implies synchronous, another implies batch/async)
- **Circular dependencies**: Phase A requires Phase B which requires Phase A (directly or transitively)
- **Forward dependencies in tests**: A phase's test/UT items require a feature only introduced in a later phase — flag which phase the test should move to, or note "confirm after Phase N"
- **Mutually exclusive constraints**: Two requirements that cannot both be satisfied simultaneously
- **Unverified external API behavior**: The spec asserts how an external API behaves without citing official documentation (flag these as "realization method unclear — needs official doc citation")
- **Missing timing specification**: A feature is described but when it executes (on launch / on button tap / in background / etc.) is not specified

For phased plans, verify that each phase can be independently built and tested using only the phases that precede it.

Report format: same as Agent #1 with Category: RealizationClarity (Excerpt should quote the ambiguous or conflicting requirement)

---

**Agent #5: Unresolved Items, ⚠️ Markers & CLAUDE.md Compliance**

**Part A — Unresolved items and ⚠️ markers:**

Flag any item that is not explicitly deferred to a named future document or phase and appears as:
- ⚠️ markers without a resolution recorded
- TBD, TODO, "未定", "確認中", "未確定", "要確認", "事前確認必須", "仕様確認後に追加", "推測で実装してはならない" or similar
- "Assumed to work as…" statements where the assumption is not verified
- Decisions marked as needing user/stakeholder confirmation with no confirmation recorded
- Sections that say "to be decided" without naming when or who decides

Also check:
- Are ⚠️ markers present where external API behavior is cited without official documentation? (If not, flag as "missing ⚠️")
- Is it clear which unresolved items must be resolved **before** implementation of a given phase can start?

**Part B — CLAUDE.md rule compliance:**

Check whether this spec violates any stated project rules in CLAUDE.md. Common patterns (adapt to whatever CLAUDE.md actually says):
- Spec requires a data schema change → does it include a migration plan if CLAUDE.md requires one?
- Spec omits UT/test items for features → if CLAUDE.md states UT is mandatory, flag missing test sections
- Spec cites external API behavior without sourcing from official documentation → if CLAUDE.md prohibits unverified API assumptions, flag these
- Spec conflicts with a "never do X" rule stated in CLAUDE.md

Only flag CLAUDE.md compliance issues if CLAUDE.md actually states a rule that this spec appears to break. Do not invent rules.

Report format: same as Agent #1 with Category: UnresolvedItems (Excerpt should quote the unresolved marker or the conflicting CLAUDE.md rule and the violating spec text)

---

### Step 5: Confidence Scoring (Batch)

Collect ALL issues from Step 4 and pass them to a **single Haiku agent** for batch scoring.

Provide the agent with:
- The full list of issues from all five agents, each including the **excerpt text already quoted by the reporting agent** (do NOT pass the full spec document — only the excerpts embedded in each issue report)
- The scoring criteria below

Scoring criteria (pass these directly to the agent):
- **0**: Subjective stylistic preference with no functional impact
- **25**: Minor ambiguity that an implementer would likely resolve correctly on their own
- **50**: Real gap or inconsistency, but unlikely to cause wrong implementation in practice
- **75**: Clear problem that would likely cause incorrect implementation or require rework — implementer could not safely proceed without clarification
- **100**: Definite blocker — contradictory specs, circular dependency, or a decision that must be made before implementation can start

The agent returns a confidence score (0 / 25 / 50 / 75 / 100) for each issue, using the format `ISSUE-N: <score>`. If an issue's Excerpt field is missing, score it 50 and append "(No excerpt provided)" after the score.

### Step 6: Validation

For each issue scoring >= 75 in Step 5, launch a **single Sonnet agent** to re-verify.

The validation agent receives:
- The filtered list of issues (those scoring >= 75)
- The relevant spec document excerpts for each issue
- The original agent's reasoning

For each issue, the validation agent must:
1. Re-read the relevant excerpts provided
2. Determine whether the issue is genuine or a false positive (see False Positives section below)
3. Return exactly `ISSUE-N: CONFIRMED` or `ISSUE-N: REJECTED — <one-line reason>`

Remove REJECTED issues from the final report.

### Step 7: Report Generation

Filter to issues that scored >= 75 and were CONFIRMED in Step 6. If this filtered set is empty, output the "no issues found" template below.

Output the final report in this format:

---

## Spec Review Results

**Review target**: <file or directory path>
**Context**: <from Step 2>
**Document type**: <from Step 3>
**Files reviewed**: <count> spec documents

### Issues Found

**Issue 1**: <brief title>
- File: `<file-path>`
- Section: <heading or line range>
- Impact: Critical / High / Medium / Low
- Category: Accuracy / Consistency / Completeness / RealizationClarity / UnresolvedItems
- Confidence: <score>/100

```
<relevant excerpt from the spec document>
```

**Recommendation**: <concrete, actionable suggestion — e.g., "Add ⚠️ and note that this requires official API doc confirmation before implementation">

---

If no issues were found:

### Spec Review Results

No issues found. Checked for accuracy, cross-document consistency, completeness, realization method clarity, phase dependencies, and unresolved items.

---

## False Positives (Consider in Steps 4, 5, and 6)

Do NOT flag as issues:

- Decisions intentionally deferred with a clear label: "to be decided in Phase N", "out of scope for this document", "will be specified in doc X"
- Design choices that are unconventional but internally consistent and unambiguous
- UI copy, color, or visual details explicitly left to implementation-time discretion
- Missing implementation details for well-understood standard patterns, when the spec explicitly delegates those details (e.g., "use standard pagination")
- Documents that intentionally supersede an older document, when this relationship is stated
- Test items that require a feature from the same phase (not a future phase)
- ⚠️ markers that already have a stated resolution or confirmation recorded in the same document

## Notes

- Do not run builds or type checks
- Do not use the gh command
- Do not read source code files speculatively — only read a file if a spec explicitly names it and checking it is necessary
- Always cite the specific file, section, and line range for each issue
- Use TodoWrite to track progress through steps

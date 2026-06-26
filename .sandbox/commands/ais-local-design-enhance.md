---
description: Brainstorm and enhance design documents — identifies missing elements and generates concrete additions ready to insert (works even without a Git repository)
description-ja: 設計書のブレインストーミング・強化 — 不足要素を特定し、そのまま挿入できる追記案を生成（Git リポジトリがなくても動作）
argument-hint: [design-doc-path-or-dir] [context]
allowed-tools: [Read, Glob, Grep, Bash(git:*), Bash(ls:*), Bash(find:*), Task, AskUserQuestion, TodoWrite, Edit]
---

# Local Design Document Enhance

Reads design documents, identifies missing elements through structured brainstorming, and generates concrete text proposals ready to insert. Intended for **active iteration on a design** — not just finding problems, but producing ready-to-use additions in the document's own style and format.

## Language

Detect the user's language from their previous messages in the conversation. Output all results in the same language the user uses. If uncertain, default to Japanese.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: Path to a design document file or directory containing design docs (interactive selection if omitted)
- 2nd argument onwards: Optional context (e.g., "Phase 3 implementation plan", "new payment feature spec")

## Execution Steps

Follow these steps precisely.

### Step 1: Locate Design Documents

1. Determine the target from $ARGUMENTS:
   - If a file path is given, use that file directly
   - If a directory path is given, find all design docs within:
     ```bash
     find <dir-path> -type f \( -name "*.md" -o -name "*.rst" -o -name "*.txt" \) -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null
     ```
   - If $ARGUMENTS is empty, search for design/spec doc directories under `/workspace`:
     ```bash
     find /workspace -maxdepth 3 -type d \( -name "docs*" -o -name "design*" -o -name "spec*" \) -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null
     ```
     Then use AskUserQuestion to let the user select the target.

   **If no files are found**: use AskUserQuestion to notify the user and ask for the path manually. Do not proceed until a valid path is given.

2. Read all identified design documents in full.

3. Find and read related CLAUDE.md files:
   ```bash
   find /workspace -maxdepth 3 -name "CLAUDE.md" -not -path "*/.git/*" 2>/dev/null
   ```

4. Optionally gather recent git history for context:
   ```bash
   git -C <nearest-project-root> log --oneline -10 2>/dev/null || true
   ```

### Step 2: Context Input

If the 2nd argument is provided, use it as context and skip AskUserQuestion.

Only if omitted, use AskUserQuestion to ask:
- **Context**: What is this design about? What aspect do you most want to strengthen?
  - Examples: "Phase 3 of payment feature", "Error handling feels thin", "Test items are missing"

### Step 3: Classify Document Type & Style

Before launching agents, classify the documents by reading their structure:
- **Phased implementation plan**: Has numbered phases, each with tasks and test/UT items
- **Feature spec**: Describes a feature's UI, data model, and behavioral rules
- **Architecture / API design**: Describes system structure, interfaces, or data flow
- **Mixed**: Combination of the above

Also analyze the writing style:
- Heading levels used (##, ###, ####)
- How test/UT items are written (bullet list, numbered, table, etc.)
- Tone (imperative, declarative, etc.)
- Language (Japanese / English / mixed)

Record the style analysis — agents in Step 4 must match this style in their proposals.

Detect the user's output language from previous messages (default: Japanese) and record it for use in Step 4.

### Step 4: Parallel Enhancement Analysis

Launch 5 parallel Sonnet agents. Pass to each agent:
- Full content of all design documents
- Full content of CLAUDE.md files
- Context from Step 2
- Document type classification and style analysis from Step 3
- Output language (instruct agents: "Output all results in <language>")
- Instruction: "Generate proposals in the **exact same style** as the existing document. Match heading levels, bullet formats, UT item formats, and language."
- Instruction: "Do NOT generate proposals to resolve ⚠️ markers, TBD, '未定', '確認中', or similar unresolved markers — only the user can resolve these. Instead, note them as 'existing unresolved item — skipped'."

Each agent produces proposals in this format:

```
## Proposal: <short title>
- File: <file-path>
- Insert location: <existing heading or section title where this should be added>
- Category: <category>
- Rationale: <one sentence why this is missing>

### Proposed text:
(markdown block matching the document's style)
```

---

**Agent #1: Error States & Recovery**

Review every feature, API call, and user action in the design. For each one, check whether the following are specified. For any that are missing, generate a concrete proposal:

- Network failure or timeout during the operation
- API error response (4xx, 5xx) — what does the UI show? What is the recovery path?
- Permission denied — who gets blocked and what do they see?
- Invalid or malformed input — is validation described?
- Partial failure in a multi-step operation — can the user retry? Is state consistent?
- Operation that modifies data: is rollback or undo described?

Focus on gaps that would leave an implementer guessing. Do not propose error handling that is already described.

Category for this agent's proposals: `ErrorHandling`

---

**Agent #2: Edge Cases & Boundary Conditions**

Review every feature and data model. For each one, check whether the following states are covered. For any that are missing, generate a concrete proposal:

- **Empty / zero-data state**: What does the UI show when a list is empty, a count is zero, or no data exists yet?
- **First use**: What happens the very first time a user encounters this feature?
- **Maximum / minimum values**: Are limits defined and enforced? What happens when a limit is hit?
- **Concurrent operations**: What if the user triggers the same action twice rapidly? What if two users act simultaneously?
- **Offline / no connectivity**: Is the feature usable offline? What degrades gracefully?
- **Data that arrived in an unexpected order**: async results that return out of order

Category for this agent's proposals: `EdgeCase`

---

**Agent #3: Missing Test & UT Items**

Review every feature and phase in the design. For each one, check:

- Does it have test / UT items specified?
- If CLAUDE.md states UT is mandatory, flag every feature without a UT item as missing
- Are the test items **actually executable** using only features from the same or earlier phases? If a test item requires a later phase's feature, propose moving it or adding a note "confirm after Phase N"
- Are success cases, failure cases, and boundary cases all covered in the test items?
- Is there a prerequisite state needed for each test (e.g., "must have data from step X first")? If not, propose adding it.

Generate concrete UT / test item text that matches the document's existing test format exactly.

Category for this agent's proposals: `TestItem`

---

**Agent #4: Integration Points & Data Flow**

Review all features and data models for missing connections. For each gap found, generate a concrete proposal:

- **Missing read path**: Feature A writes data to a store — is there a spec for how Feature B reads it? If not, propose one.
- **Missing timing specification**: A feature is described but *when* it executes is not stated (on launch / on button tap / in background / on schedule). Propose a timing specification.
- **Missing state transitions**: The design describes a start state and an end state but not the transition. Propose the missing transition description.
- **Missing notification or callback**: An async operation completes — is there a spec for how the UI is notified?
- **Missing cleanup**: Data is created — is there a spec for when/how it is deleted or archived?

Category for this agent's proposals: `DataFlow`

---

**Agent #5: UX States & User-Facing Feedback**

Review every screen, flow, and user action for missing UX specifications. For each gap, generate a concrete proposal:

- **Loading / in-progress state**: Is there a spec for what the UI shows while an operation is running?
- **Success feedback**: After a key action, does the user get confirmation? (toast, alert, navigation, etc.)
- **Empty state UI**: Is the empty state screen or placeholder described?
- **Disabled / locked state**: If a feature is gated (by plan, permission, or prerequisites), what does the disabled UI look like?
- **Destructive action confirmation**: Is there a confirmation dialog before irreversible actions?
- **Accessibility**: If the app targets accessibility, are any behaviors missing?

Category for this agent's proposals: `UXState`

---

### Step 5: Consolidate & Deduplicate

Collect all proposals from Step 4. In a single pass:

1. Remove duplicate proposals (same insertion point + same content from two agents)
2. Merge overlapping proposals where sensible
3. Number each remaining proposal sequentially: **Proposal 1**, **Proposal 2**, etc.
4. Group by category for presentation

Total proposal count is typically 5–20. If more than 25 are generated, apply stricter deduplication — prefer the more specific proposal when two cover the same gap.

### Step 6: Present Proposals

Output the full proposal report in this structure:

---

## Design Enhancement Proposals

**Target**: <file or directory>
**Context**: <from Step 2>
**Document type**: <from Step 3>
**Total proposals**: <N>

---

### ErrorHandling (<count>)

**Proposal 1**: <title>
- File: `<path>`
- Insert in: `<section heading>`
- Rationale: <one sentence>

```markdown
<proposed text>
```

---

(repeat for each proposal, grouped by category)

---

After outputting the report, use AskUserQuestion to ask:

- **What to do with these proposals?**
  - Apply all proposals to the design documents
  - I'll copy-paste manually — no changes needed
  - Apply only specific proposals (tell me which numbers)

### Step 7: Apply Proposals (if requested)

**If "Apply all"**: for each proposal in order, use the Edit tool to insert the proposed text at the specified location in the target file. Read the file before each Edit to confirm the insertion point exists. After applying all, output a summary of what was added.

**If "Apply specific proposals"**: ask the user to specify which proposal numbers to apply (via AskUserQuestion or as a follow-up message), then apply only those using the Edit tool.

**If "I'll copy-paste manually"**: output a closing message: "Proposals are ready above. No changes were made to the files."

**Important rules for applying:**
- Insert text at the end of the specified section, before the next heading of the same or higher level
- Do not modify existing content — only add new content
- Preserve the document's existing indentation and blank-line conventions
- If the specified insertion point is not found, skip that proposal and report it as "skipped — section not found"

After applying, output:

```
## Changes Applied

- Proposal 1: ✅ Added to <file> → <section>
- Proposal 2: ✅ Added to <file> → <section>
- Proposal 3: ⚠️ Skipped — section "<heading>" not found
```

## Notes

- Do not run builds or type checks
- Do not use the gh command
- Always generate proposals in the document's own style — headings, bullet style, language, and tone must match
- Never modify existing content when applying proposals — insertion only
- Use TodoWrite to track progress through steps
- If a document has ⚠️ markers or "TBD" items, do not generate proposals to "resolve" them — only the user can resolve those. Instead, note them in the report as "existing unresolved items (not modified)"

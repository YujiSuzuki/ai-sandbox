---
description: Challenge a design document from multiple stances before it's finalized — surfaces objections and alternative directions without proposing edits (works even without a Git repository)
description-ja: 設計書を複数の立場から検証する — 編集案を出さずに、反論・懸念・代替案だけを洗い出す（Git リポジトリがなくても動作）
argument-hint: [design-doc-path-or-dir] [context]
allowed-tools: [Read, Bash(find:*), Task, AskUserQuestion, TodoWrite]
# Task is used in Steps 3, 3b, and 3c to launch Sonnet agents
---

# Local Design Challenge

Reviews a design document from several independent stances — not to check its internal consistency or completeness (see `/ais-local-spec-review`), and not to generate ready-to-insert additions (see `/ais-local-design-enhance`), but to question whether **the approach itself** is the right one.

Each stance is instructed to raise objections, risks, and alternative directions **without proposing specific edits**. Deciding what to do with these positions — rewrite the approach, note it as an accepted tradeoff, or dismiss it — is left to the user, since that judgment call is exactly what this command exists to keep in human hands.

One stance (Alternative Architect) goes further: it derives its alternative **before ever seeing the existing design**, from the requirements alone, then compares the two only afterward — so the alternative isn't a variation on what's already written down.

Use this command **before** `/ais-local-spec-review`: challenge the approach first, revise the document based on what holds up, then run spec-review to tighten the resulting document's internal consistency and completeness.

## Language

Detect the user's language from their previous messages in the conversation. Output all results in the same language the user uses. If uncertain, follow the session's default response language (see CLAUDE.md's "Response Language" rule / sandbox-mcp's language signal); only fall back to English if no such signal is available.

## Arguments

User-specified arguments: $ARGUMENTS

Argument interpretation:
- 1st argument: Path to a design document file or directory — the first whitespace-delimited token in `$ARGUMENTS`, if it looks like a path (starts with `/`, `./`, `../`, or contains `/`) and actually exists on disk. If no such token exists, or it doesn't exist on disk, treat the entire `$ARGUMENTS` string as context and ask the user for the doc path/directory.
- 2nd argument onwards: Optional context (e.g., "considering a payment provider switch", "V2 of the mastermind feature")

## Execution Steps

Follow these steps precisely.

### Step 1: Locate Design Documents

1. Determine the target from $ARGUMENTS:
   - Take the first whitespace-delimited token of `$ARGUMENTS`. If it looks like a path (starts with `/`, `./`, `../`, or contains `/`), verify it exists on disk:
     ```bash
     test -e <candidate-token> && echo "VALID_PATH" || echo "NOT_A_PATH"
     ```
   - If it exists and is a file, use that file directly
   - If it exists and is a directory, find all design docs within:
     ```bash
     find <dir-path> -type f \( -name "*.md" -o -name "*.rst" -o -name "*.txt" \) -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null
     ```
   - If no such token exists, or the token doesn't exist on disk, search for design/spec doc directories under `/workspace`:
     ```bash
     find /workspace -maxdepth 3 -type d \( -name "docs*" -o -name "design*" -o -name "spec*" \) -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null
     ```
     Then use AskUserQuestion to let the user select the target.

   **If no files are found**: use AskUserQuestion to notify the user and ask for the path manually. Do not proceed until a valid path is given.

2. Read all identified design documents in full.

3. Find and read related CLAUDE.md files (project constraints that a proposed alternative must still respect):
   ```bash
   find /workspace -maxdepth 3 -name "CLAUDE.md" -not -path "*/.git/*" 2>/dev/null
   ```

### Step 2: Context Input

If a valid doc path was found in Step 1 (the 1st argument) and the 2nd argument onwards is provided, use it as context and skip AskUserQuestion.

If no valid doc path was found in Step 1 (the entire `$ARGUMENTS` string was treated as context), use that string directly as context and skip AskUserQuestion.

Only if no context text is available in either case, use AskUserQuestion to ask:
- **Context**: What is this design about? What decision or approach do you most want stress-tested?
  - Examples: "Considering whether to store keys client-side", "V2 backend split — worried it's over-engineered"

Detect the user's output language from previous messages (default: Japanese) and record it for use in Step 3.

### Step 3: Parallel Stance Analysis

Launch 3 parallel Sonnet agents (#1–#3 below). Pass to each:
- Full content of all design documents
- Full content of CLAUDE.md files from Step 1
- Context from Step 2
- Output language (instruct agents: "Output all results in <language>")
- This instruction, verbatim, for every agent: "Do NOT propose specific edits, rewritten text, or insertion-ready wording. Your job is to raise objections, risks, and alternative directions in prose — the user decides what, if anything, to do with them. Do not soften a real objection into a suggestion just to sound constructive. If you genuinely find nothing worth raising from this stance, say so plainly rather than inventing a minor nitpick. Stay fully in character for the persona below for the entire response — do not soften it into a generic reviewer voice."

Each agent produces its output in this format:

```
## Stance: <stance name>

**Position 1**: <short title>
- Concern: <what's wrong, risky, or worth questioning — 2-4 sentences>
- Why it matters: <concrete consequence if this goes unaddressed>
- Alternative direction (if any): <a genuinely different approach, described at a conceptual level — not edit text>
```

---

**Agent #1: Skeptical Reviewer**

Persona: You are a stickler for risk who has seen this kind of design fail before. You always find the problem no one else catches, and you are not here to be agreeable. Assume the proposed approach is more fragile than it looks. For the design as a whole and for each major decision in it, ask:
- What would have to be true for this approach to fail, and how likely is that?
- Is this solving the actual problem, or a proxy for it?
- Where does this design rely on an untested assumption?
- Is there a simpler approach being overlooked because the current one is already written down?
- Where is this over-engineered for the problem's actual scale, or under-engineered for its actual risk?

---

**Agent #2: User Advocate**

Persona: You represent the end user in the room and nobody else will if you don't. You are openly impatient with decisions that trade user experience for implementation convenience. Set aside implementation convenience and evaluate purely from the perspective of the person who will use what's being built. For each user-facing decision:
- Does this decision optimize for ease of building over ease of use?
- What would confuse, frustrate, or block a real user encountering this?
- Is there a simpler mental model for the user that this design doesn't take?
- Whose need is this design actually centered on — the user's, or an internal constraint's?

---

**Agent #3: Operations Owner**

Persona: You are the person who gets paged at 3am when this breaks, and you review every design with that resentment in mind. Evaluate the design from the perspective of whoever has to run, monitor, debug, and support this after launch. For each component or process described:
- What breaks silently, and how would anyone find out?
- What manual intervention does this design assume someone will reliably do?
- What gets harder to change later because of a choice made here?
- Is there a support/on-call burden this design creates that isn't mentioned anywhere in the doc?

---

### Step 3b: Blind Alternative (Agent #4, Phase A)

Launch a separate Sonnet agent for this phase. **Do not give it the design documents.** Pass only:
- Context from Step 2
- Full content of CLAUDE.md files from Step 1
- Output language

Instruction: "You have not seen any existing design for this. Treat the context and constraints given as the only fixed inputs. Propose one concrete overall approach to solving this problem, described at a conceptual level. Then, playing devil's advocate against your own proposal, state what would make this alternative a bad choice — its most likely failure mode or weakest assumption. Do not hedge the self-critique; give it the same weight you'd want from a critic."

Output format:
```
## Blind Alternative

**Proposal**: <the independently-derived approach>
**What would make it a bad choice**: <the proposal's own weakest point, stated plainly>
```

### Step 3c: Comparison Against Requirements (Agent #4, Phase B)

Launch another Sonnet agent (or continue the same one). Pass:
- The full Blind Alternative output from Step 3b
- Full content of all design documents (revealed now, for the first time, to this line of reasoning)
- Context from Step 2
- Output language

Instruction: "You previously proposed the attached alternative without seeing the existing design. Now compare both approaches — the blind alternative and the existing design — against the same requirements/context. Do not just restate each one's description; identify the specific point(s) where they'd actually behave differently given the same input or failure scenario. For at least one such point of disagreement, propose one concrete, checkable test or scenario that would show which approach handles it better — something to run or reason through, not a matter of which document reads more convincingly."

Output format:
```
## Stance: Alternative Architect

**Blind proposal**: <from Step 3b>
**Where it differs from the existing design**: <the specific decision points where behavior would actually diverge>
**Deciding test**: <a concrete scenario or test that would show which approach handles a specific divergence better>
**Verdict**: <which approach this agent leans toward for this problem, and the one-sentence reason — framed as a leaning, not a directive>
```

---

### Step 4: Consolidate & Present

Collect all stances from Steps 3 and 3c. Do not merge, score, or filter positions across stances — each stance's view stands on its own, including disagreements between stances.

Output the report in this structure:

---

## Design Challenge Results

**Target**: <file or directory>
**Context**: <from Step 2>

<output each agent's full "## Stance: ..." block, in the order: Skeptical Reviewer, User Advocate, Operations Owner, Alternative Architect (Step 3c's output, including the Step 3b blind proposal it references)>

---

After outputting the report, use AskUserQuestion to ask:

- **What would you like to do with these positions?**
  - Discuss specific positions further before deciding anything
  - I'll decide on my own what to fold into the design — no further action needed

## Notes

- Do not run builds or type checks
- Do not use the gh command
- Never let an agent propose ready-to-insert text — that is `/ais-local-design-enhance`'s job, and mixing the two defeats the purpose of this command (a challenge phase anchored to the current wording is not a challenge)
- Use TodoWrite to track progress through steps
- This command intentionally does not auto-apply anything: the point of separating "raise objections" from "decide and rewrite" is to keep the second step in human judgment, not to save a step

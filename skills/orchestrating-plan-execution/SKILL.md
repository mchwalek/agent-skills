---
name: orchestrating-plan-execution
description: "Use when the user approves an approach and wants it implemented end to end, particularly when they say you should not write the code yourself. Examples: \"Let's go with Approach B\", \"proceed with the plan\", \"implement this and confirm with tests\""
---

# Orchestrating Plan Execution

**Requires [obra/superpowers](https://github.com/obra/superpowers) to be installed** — this skill orchestrates the `writing-plans`, `subagent-driven-development`, `dispatching-parallel-agents`, and `verification-before-completion` skills that ship with it.

## Overview

You hold the plan. Subagents write the code. State lives on disk, not in
context — context gets compacted, files don't.

## When to Use

- User picked an approach from options you presented
- Multi-step implementation work
- Any task where you would otherwise start editing files immediately

Skip for: single-file edits, questions, exploration.

## Workflow

Read the code first. Reconnaissance before planning is not a violation — find
what already exists before planning to build it. If recon shows the approved
approach is much smaller than agreed (a platform feature already covers it) or
much larger, that is a scope change: surface it before writing the plan.

1. Load `writing-plans`. Write the plan to `docs/plans/<slug>.md`. Each task
   gets: goal, files to touch, acceptance criteria, verification command.
2. Load `subagent-driven-development`. You are the orchestrator — write no
   production or test code yourself beyond a trivial one-line fix. The plan
   file, `PROGRESS.md` and `DECISIONS.md` are yours to write; they are
   coordination, not implementation.
3. Dispatch one subagent per plan task. Load `dispatching-parallel-agents` and
   parallelize ONLY tasks sharing no files with no ordering dependency.
   Dependent tasks still get dispatched — just sequentially.
4. Every subagent prompt contains:
   - exact skill names to load (subagents do NOT inherit your loaded skills)
   - path to the plan file and its specific task section
   - acceptance criteria
   - files it must NOT touch
   - "Report: files changed, commands run with their output, blockers.
     Do not write PROGRESS.md."
5. Only you write `PROGRESS.md` and `DECISIONS.md`, after each subagent
   returns. Parallel subagents writing the same file clobber each other.
6. Ambiguity → decide, log decision + rejected alternative in `DECISIONS.md`.
   Stop and ask only when irreversible or scope-changing.
7. Before claiming done: load `verification-before-completion`. Paste the real
   test command and its real output.
8. Any compaction summary must link the plan file, `PROGRESS.md`,
   `DECISIONS.md`, and name the in-flight task.

## Skill Selection

`subagent-driven-development` and `executing-plans` are mutually exclusive —
current session vs. separate session with review checkpoints. Loading both
leaves the workflow ambiguous. In-session orchestration →
`subagent-driven-development`.

## Red Flags — STOP

- Your action list ends with "then start editing"
- Parallel subagents dispatched against the same file
- A subagent prompt with no plan-file path in it
- Saying "done" without pasted test output
- The plan exists only in the conversation

## Rationalizations

| Excuse | Reality |
|---|---|
| "One coherent slice — splitting costs more in coordination than writing it" | The plan file IS the coordination. You specify the seams once either way; on disk they also survive compaction. |
| "Parallelism pays for search, not for a small connected diff" | Correct — so dispatch sequentially. Dispatching protects your context, not the clock. |
| "Context plus a todo list is enough" | Todos record what, never what was decided. Compaction eats the decisions. |
| "A plan file is scratch I'd have to delete" | One `.gitignore` line. |
| "For a change this size I'd accept the risk" | You are sizing the change before you have read the code. |
| "I'll re-confirm with the user if anything feels uncertain" | You won't know it was uncertain. The memory of the decision is the part that's gone. |
| "This task is small, I'll just do it" | Small tasks grow. Dispatch it. |

## Artifacts

`PROGRESS.md` and `DECISIONS.md` are working state. Add them and
`docs/plans/` to `.gitignore` once.

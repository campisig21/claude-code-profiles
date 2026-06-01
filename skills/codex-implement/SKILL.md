---
name: codex-implement
description: Dispatch implementation work to codex in a git worktree, auto-verify it, and land it on your approval. Use when you (Claude) have planned a change and it's time to implement — a plan task, a whole plan, a focused change, or a trivial in-place edit. Wraps codex exec/resume with verification and Claude-gated merge.
---

# codex-implement

You (the main session) are the **policy-maker**. `codex_dispatch.sh` is a deterministic
engine that does the mechanical work and **refuses unsafe sequences**. Never run raw
`git worktree` / `git merge` / `codex` yourself — always go through the engine. The one
exception: `codex exec resume --last` for iterating on a `--quick` edit.

Engine path: `~/.claude/profile-system/codex_dispatch.sh` (a profile symlinks it via
shared machinery). Run it from inside the repo codex should work on.

## 1. Decide the shape (decision table)

| Situation | Command |
|---|---|
| Fresh task / plan / focused change | `dispatch` |
| Iterating on an existing dispatch (your feedback or a failure) | `resume <id> "<fb>"` |
| Trivial edit, isolation is overkill | `quick` (add `--snapshot` if the tree is dirty) |

| Backend (`--backend`) | When |
|---|---|
| `codex` (default) | Impactful work, large diffs, anything beyond the local model's context budget. |
| `local` | Quick / low-stakes / mechanical edits, or working without the cloud. Run `local-up` first; prefer `--retry 0`. Pair with `quick` (in-place) or `dispatch` (isolated). |

| Task impact | `--verify` | `--retry` |
|---|---|---|
| High impact / risky / touches many files | `both` (default) | `0` (hand failures back to you) |
| Medium | `both` or `checks` | `1` |
| Low / mechanical | `checks` | `1`–`2` |
| No meaningful tests | `review` | `0` |

Granularity is your call (one task vs. a whole plan) — the engine treats them identically.

## 2. Dispatch

```
codex_dispatch.sh dispatch --verify <checks|review|both> --check '<cmd>' [--check '<cmd2>'] \
  --retry <N> --slug <short-label> "<prompt for codex>"
```
- Pass the **verify commands** the planned work should satisfy (e.g. `--check 'bash tests/run.sh'`).
- Write a **complete, self-contained prompt**: what to build, where, and the definition of done.

**Local backend:** before `--backend local`, load the model — `codex_dispatch.sh local-up`
(switches to the qwen36-only preset over SSH, then waits for `ready`) / `local-down` (stops the
container, freeing VRAM). The engine **refuses** local dispatch when the model isn't loaded and
prints the `local-up` command. `doctor` shows the live state (`unreachable | up-not-loaded | ready`).

## 3. Read the result, then take EXACTLY ONE next action

The engine prints a summary + an `ALLOWED NEXT ACTIONS` block. Follow it.
- If `verify` includes `review` (i.e. `both`/`review`): run `codex_dispatch.sh show <id> --diff`
  and **actually review the diff** before landing. Watch for weakened/deleted tests
  (the engine also flags `⚠ diff modifies tests`).
- Then exactly one of:
  - `codex_dispatch.sh land <id>` — review/checks pass. (Add `--reviewed` for `review`-only.)
  - `codex_dispatch.sh resume <id> "<feedback>"` — send fixes to codex; re-verifies.
  - `codex_dispatch.sh abandon <id>` — discard worktree + branch.
- On `failed` (retry budget exhausted): inspect, then `resume` or `abandon`. If you're unsure
  whether to keep spending retries, ask the user.

## 4. Quick (in-place) path

```
codex_dispatch.sh quick [--verify checks --check '<cmd>'] [--snapshot] "<prompt>"
```
Edits the current working tree directly (no worktree, no land step). Refuses a dirty tree
without `--snapshot`. Review the printed diff; commit or revert yourself.

## 5. Executing a multi-task plan — task tracking

When the work is a multi-task plan (not a single change), manage a task list so progress is
visible — this mirrors `subagent-driven-development`, but the lifecycle is keyed to the engine's
dispatch states, and **the `land` gate is yours** (this is not continuous auto-execution).

**Up front (once, BEFORE the first dispatch):** read the plan, extract **every** task, and create
one task per plan task with `TaskCreate` (fall back to `TodoWrite` if task tools are unavailable).
Encode ordering with `addBlockedBy` so dependent tasks can't be marked startable before their
prerequisites land.

| Engine event | Task status |
|---|---|
| `dispatch` / `quick` issued for a task | `in_progress` |
| `land` succeeds (green) | `completed` |
| `resume` issued | keep `in_progress` |
| `abandon` | back to `pending` (or delete if dropped from scope) |

`land` is the **only** completion signal — never mark a task `completed` at dispatch time, and
never `land` a task whose dependency hasn't landed.

**Batching:** independent tasks may be dispatched together; dependent tasks go sequentially. Keep
one `in_progress` per active dispatch, and update the list at each dispatch and each land.

## Red flags — STOP if you think any of these

| Thought | Reality |
|---|---|
| "I'll just `git merge`/`git worktree remove` this myself" | Use `land`/`abandon` — they run the rebase, re-verify, cleanup, and guardrails. |
| "Checks passed, I'll skip the diff review" | Only valid when `verify=checks`. For `both`/`review` you MUST `show --diff` and review. |
| "I'll run `codex exec` directly to implement this" | Go through `dispatch`/`quick` so it's isolated, verified, and tracked. |
| "I'll route this big/impactful change to `--backend local`" | Local is for quick/low-stakes work within its context budget. Impactful or large-context → default `codex`. |

> Governance: keep this table ≤7 rows, phrased by category. A misuse the engine can
> already refuse does NOT belong here — it belongs in the engine.

## Per-dispatch checklist

For a multi-task plan, first build the task list (§5) — one `TaskCreate` per plan task with
`addBlockedBy` deps — *before* the first dispatch. Then, for each dispatch:

- [ ] Pick backend (`codex` default; `local` for quick/low-stakes — run `local-up` first)
- [ ] Pick command + `--verify`/`--retry` from the decision table
- [ ] Mark the task `in_progress` (§5)
- [ ] `dispatch` (or `quick`) with explicit checks + a complete prompt
- [ ] Read the result + `ALLOWED NEXT ACTIONS`
- [ ] If review-mode: `show <id> --diff` and review
- [ ] Take exactly one of `land` / `resume` / `abandon`
- [ ] On a green `land`, mark the task `completed` (§5)

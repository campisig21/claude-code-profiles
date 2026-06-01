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

## Red flags — STOP if you think any of these

| Thought | Reality |
|---|---|
| "I'll just `git merge`/`git worktree remove` this myself" | Use `land`/`abandon` — they run the rebase, re-verify, cleanup, and guardrails. |
| "Checks passed, I'll skip the diff review" | Only valid when `verify=checks`. For `both`/`review` you MUST `show --diff` and review. |
| "I'll run `codex exec` directly to implement this" | Go through `dispatch`/`quick` so it's isolated, verified, and tracked. |

> Governance: keep this table ≤7 rows, phrased by category. A misuse the engine can
> already refuse does NOT belong here — it belongs in the engine.

## Checklist (make a TodoWrite item per step)
- [ ] Pick command + `--verify`/`--retry` from the decision table
- [ ] `dispatch` (or `quick`) with explicit checks + a complete prompt
- [ ] Read the result + `ALLOWED NEXT ACTIONS`
- [ ] If review-mode: `show <id> --diff` and review
- [ ] Take exactly one of `land` / `resume` / `abandon`

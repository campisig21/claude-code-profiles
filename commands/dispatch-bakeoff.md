---
description: Bake one task off across N (backend,model) workers in parallel via a Workflow — each a dispatch cell in its own worktree — then review the winner's diff and land exactly one, abandoning the rest
argument-hint: [--models gpt-5.5,qwen2.5,claude] [--check 'cmd']... "<task>"
allowed-tools: Workflow, Bash, Read
---

Run a **multi-model dispatch bake-off** for the user's task, then land exactly one winner.

Task: `$ARGUMENTS`

- Parse `--models <a,b,c>` (default `gpt-5.5,qwen2.5,claude`) and any `--check 'cmd'` flags
  from `$ARGUMENTS`; the remainder is the task description. Map each model to a backend:
  `claude` (or `opus`/`sonnet`/`haiku`/`fable`) → a direct cell (no codex); `qwen*` → `ollama`;
  everything else → `codex`.
- Invoke the bake-off Workflow — **this is your explicit opt-in to the `Workflow` tool**:
  `Workflow({ scriptPath: "<HOME>/.claude/profile-system/workflows/dispatch-bakeoff.js",
    args: { task: "<task>", slug: "<short-slug>", contestants: [{backend, model}, ...],
            checks: ["<cmd>", ...] } })`
  (Expand `<HOME>` to the absolute home path; `scriptPath` does not expand `~`.)
  The workflow fans out one **dispatch cell per contestant** (each follows the dispatch skill:
  compose → `begin --label <model>` → delegate → `verify` once → `record`), then a judge ranks
  the survivors. The workflow **lands nothing** (E9) — it returns verdicts + a recommendation.
- When the workflow returns: review the recommended winner with `dispatch show <winner_id> --diff`
  and actually read it — scrutinize any id in `recommendation.test_integrity_flags` for
  weakened/deleted tests. Then take exactly one landing decision: `dispatch land <winner_id>`,
  and `dispatch abandon <id>` for every other contestant. **Only the orchestrator lands** — the
  cells and the workflow never do.
- Never run raw git/codex; always go through the `dispatch` CLI. Watch progress live with
  `/workflows` or `dispatch console`; live-tail one contestant with `dispatch attach <id>`.

> Companion to `/dispatch` (single worker). The bake-off reuses the same library, ledger, and
> `land` — it is just the parallel, pick-one form.

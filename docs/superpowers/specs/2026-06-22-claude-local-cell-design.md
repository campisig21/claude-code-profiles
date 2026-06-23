# Design — claude-local as a dispatch cell + bake-off contestant (Phase B)

- **Status:** Draft (pending review)
- **Date:** 2026-06-22
- **Governing decision:** [ADR-0006](../../decisions/0006-claude-local-cell-integration.md)
  (non-codex delegates integrate via their own wrapper, never the frozen seam;
  on approval ADR-0006 → Accepted). Extends
  [ADR-0004](../../decisions/0004-claude-local-dispatch-transport.md) (the
  claude-local transport — Phase A, shipped).
- **Related:** Phase A spec
  `docs/superpowers/specs/2026-06-21-claude-local-transport-design.md` (§11 sketch);
  `ergonomic-wrapper-next` auto-memory.

> **Snapshot caveat.** Concrete values below (function names, flags, paths) are
> *design intent*. Once the code exists it is the authoritative contract
> ([ADR-0001](../../decisions/0001-record-architecture-decisions.md): contracts
> live in code). Treat this dated spec as a point-in-time snapshot.

---

## 1. Goal

Make **claude-local** (the Phase-A `claude -p`-against-the-station transport) a
**first-class dispatch cell** — a worker that runs a qwen tool loop inside a
`dispatch begin`-returned worktree, commits its work, and updates the sidecar,
exactly the way `codex-run` does — and wire it in as a **bake-off contestant** so
the same task can be raced across `codex-on-qwen` vs `claude-on-qwen` vs
`claude-on-claude`.

### Non-goals (Phase B)

- **No live bake-off run** — that is a deferred follow-up (needs the station up,
  burns real dispatch time). Phase B delivers the contestant *definition* + tests.
- **No edits to `lib/dispatch.sh`** — it is the FROZEN codex adapter (ADR-0006).
  All new code lives in `lib/claude-local.sh`, `bin/claude-run`, and the bake-off
  Workflow.
- **No verify/record/land logic** — those stay `dispatch` verbs the cell calls,
  unchanged. `claude-run cell` does run → digest → commit → sidecar, then returns;
  the caller drives `verify`/`record`/`land` (same division as `codex-run`).

---

## 2. Background & constraints

- **Two layers, one frozen.** `lib/dispatch-lib.sh` is the delegate-agnostic
  library (`d_begin` / `d_sc_get` / `d_sc_set` / `d_commit_worktree` /
  `d_verify` / `d_record` / `d_land`); `lib/dispatch.sh` is the FROZEN codex
  adapter (`d_codex_run` / `d_codex_exec`). `tests/dispatch_lib_extraction_test.sh`
  proves the library sources standalone (`has_codex=no`). So a new transport can
  reuse the lifecycle by sourcing `lib/dispatch-lib.sh` — **without** touching the
  frozen adapter. This is the architectural basis for the whole phase (ADR-0006).
- **The exec problem.** Phase A's `claude_local_exec` ends in `exec` (it replaces
  the shell — correct for a one-shot run). The cell must commit *after* the worker
  finishes, so it needs a **non-exec** run path that returns control. Hence
  `claude_local_run` (§3).
- **Commit uniformity.** The cell commits via the shared `d_commit_worktree`
  (`git add -A`), identical to `codex-run`. The worktree is a fresh clone at
  `base_ref`, so only the run's new/changed files stage; the target repo's tracked
  `.gitignore` keeps build artifacts out. The cell **never authors a `.gitignore`**
  (it breaks `land`'s `--ff-only`, per `ergonomic-wrapper-next`).
- **Background hazard.** `claude -p` must never be nested in a manual
  `nohup`/detached shell. The cell runs it **foreground in its own subprocess**
  (`claude_local_run` backgrounds nothing) — the worker blocks the cell for the
  run's duration (~minutes for a 30B loop), like `codex-run` blocks.
- **Reasoning-model budget.** Pass a real `--max-turns`/token budget or the worker
  returns empty `content[]` (documented caveat, not enforced).

---

## 3. Architecture & components

Three touched files (none is the frozen seam) + one new test file.

### `lib/claude-local.sh` — add a non-exec run path

| Function | Contract |
|---|---|
| `claude_local_env` (new, internal) | Echoes the resolved `env -u … ANTHROPIC_*` prefix array so `_exec` and `_run` share one env block (DRY; removes the duplicated contract). |
| `claude_local_run <dir> <streamfile> [claude-args…]` (new) | `cd <dir>`; run `${CLAUDE_BIN:-claude} -p --output-format stream-json --verbose "$@"` as a **subprocess** (NOT exec) with the resolved env, its **stdout redirected to `<streamfile>`** (not the cell's stdout — that's reserved for the digest); return claude's exit code. The cell's worker step. |
| `claude_local_exec` (unchanged behavior) | Still `exec`s for the one-shot path; refactored to use `claude_local_env`. |
| `claude_local_resolve` / `_probe` / `_digest` | Unchanged. |

### `bin/claude-run` — add the `cell` subcommand

```
claude-run cell <id> "<prompt>" [-- <extra claude flags>]
```

Steps (sources `lib/dispatch-lib.sh` + `lib/jsonutil.sh`):

1. `wt="$(d_sc_get "$id" '.worktree')"`; if `[ ! -d "$wt" ]` → error, exit 1.
2. `stream="$(d_sidecar_dir)/$id.stream.ndjson"` (sidecar-adjacent, not committed).
3. `claude_local_run "$wt" "$stream" "$prompt" "<extra>"`; capture `rc`.
4. `claude_local_digest < "$stream"` → per-step trace on stdout (the caller sees
   what qwen did).
5. `d_commit_worktree "$wt" "claude-local: $id (<model>)"` — reuse, `git add -A`;
   tolerate its `return 1` when the worker produced no changes.
6. `d_sc_set "$id" '.backend="claude-local" | .model=$m | .updated_at=$u' --arg m "$CL_MODEL" --arg u "$(d_now)"`.
7. `return $rc` (nonzero worker exit propagates so the caller can `record --status failed`).

`main()` gains a `cell)` branch ahead of the default exec path. The one-shot
verbs (`doctor`/`env`/`digest`) and the bare exec path are unchanged.

### `workflows/dispatch-bakeoff.js` — add the contestant

- Default contestants gain `{ backend: 'claude-local', model: 'qwen3-coder-30b' }`
  (a third kind, distinct from the em-dash direct-Claude cell and codex/ollama).
- The cell-prompt builder gains a `backend === 'claude-local'` branch that
  instructs the cell to delegate via:
  ```
  bin/claude-run cell "$id" "<your composed prompt>" -- --allowedTools <…> --max-turns <n>
  ```
  launched per the `dispatch` SKILL `claude-local` bullet (harness background
  facility for surfacing; never manual `nohup`).
- The verdict schema is unchanged (`backend` is a free string).

### `tests/claude_run_cell_test.sh` — hermetic

`ps_make_sandbox_repo` → real `d_begin` (real worktree + sidecar) → `claude-run
cell` with a **cell-test fake `claude`** (a local variant the test writes — NOT a
change to the shared `ps_make_fake_claude_p`, which Phase A depends on — that
writes a file into its cwd and emits canned NDJSON on stdout) → assert:

- worktree resolved from the sidecar id;
- the worker's file is **committed** in the worktree branch (`d_has_changes` vs
  `base_ref` → yes);
- sidecar `.backend == "claude-local"` and `.model` set;
- the digest trace was printed (contains a `tool:`/`result:` line from the fixture);
- a fake `claude` exiting nonzero makes `claude-run cell` return nonzero
  (caller-can-record-failed path).

Plus: extend a `tests/dispatch_bakeoff_*` test to assert the claude-local
contestant yields a well-formed cell prompt (mentions `bin/claude-run cell`) and a
valid verdict shape. Full suite stays green.

---

## 4. Data flow

```
orchestrator / bake-off contestant agent
  └─ dispatch begin <slug> --label qwen-local        → id (+ worktree + sidecar)
  └─ bin/claude-run cell "$id" "<prompt>" -- --allowedTools … --max-turns N
       ├─ d_sc_get id .worktree → wt
       ├─ claude_local_run wt stream prompt …        (claude -p qwen, NON-exec, NDJSON→stream)
       ├─ claude_local_digest < stream               (per-step trace → stdout)
       ├─ d_commit_worktree wt "claude-local: id"    (git add -A; tolerate no-change)
       └─ d_sc_set id .backend=claude-local .model=…
  └─ dispatch verify "$id" --check … ; dispatch record "$id" --status needs_review|failed
  (orchestrator reviews + lands the winner — unchanged)
```

Mirrors `codex-run` step-for-step, with `claude_local_run` where `d_codex_exec`
would be and the digest as the surfacing.

---

## 5. Error handling

- **Missing worktree** for `$id` (bad id / pruned) → clear message, exit 1.
- **Worker nonzero exit** → surface; still `d_sc_set` the backend/model; return the
  nonzero code so the cell records `failed` (don't swallow).
- **No changes produced** → `d_commit_worktree` returns 1; tolerate (treat as a
  noop-ish run; the verify step / `record --status noop` handles it).
- **Empty `content[]`** (reasoning budget too small) → digest shows no tool/result
  line; verify catches the missing artifact.
- **Frozen-seam temptation** → never add a `dispatch claude-run` verb; the `cell`
  mode lives in `bin/claude-run` (ADR-0006).

---

## 6. Testing

- **`tests/claude_run_cell_test.sh`** (house harness, model-free): the cell
  lifecycle against a real `d_begin` worktree with a fake `claude` (§3).
- **bake-off contestant test** (extend existing): the claude-local contestant's
  cell prompt + verdict shape.
- **Seams:** `${CLAUDE_BIN}` (fake claude), real `dispatch-lib.sh` (no fake — it's
  the unit under integration), `ps_make_sandbox_repo`.
- **Regression:** the full `tests/*_test.sh` suite stays green (run with
  `</dev/null` — `curator_loop_test.sh`'s fake `flock` blocks on a non-EOF stdin).
- **Live bake-off:** deferred (own follow-up; needs the station READY).

---

## 7. Deliverables

- `lib/claude-local.sh`: `claude_local_env` + `claude_local_run`.
- `bin/claude-run`: `cell` subcommand.
- `workflows/dispatch-bakeoff.js`: claude-local contestant + cell-prompt branch.
- `tests/claude_run_cell_test.sh` + a bake-off contestant assertion.
- ADR-0006 → Accepted on landing; `bin/claude-run` `cell` mode becomes its
  canonical source.

---

## 8. Risks & open questions

- **Workflow agent ↔ foreground worker.** A bake-off contestant is a Workflow
  `agent()`; it shells `bin/claude-run cell` and blocks ~minutes on the 30B loop.
  This is fine (codex-run blocks too), but the **live** 3-way run (deferred) is
  where we confirm the wall-clock and the digest surfacing inside a Workflow agent.
- **Surfacing granularity.** `cell` mode prints the digest *after* the run (one
  trace), not incrementally — sufficient for a bake-off verdict. Incremental
  orchestrator-direct surfacing remains the Phase-A path. If a future need wants
  live in-cell streaming, a superseding note records it.
- **`d_now` availability.** Confirm `d_now` (or the timestamp helper the sidecar
  uses) is exported from `dispatch-lib.sh`; if not, use the same helper `d_begin`
  uses for `.updated_at`.

---

## 9. Revision log (append-only)

- 2026-06-22 — initial draft.

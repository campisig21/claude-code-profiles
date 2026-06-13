# Subsystem E — Dispatch Harness Decoupling (polyglot dispatch + live console) — Design Spec

- **Date:** 2026-06-13
- **Status:** Approved (design); pending spec review
- **Subsystem:** E (A = Profiles · B = Self-improvement learning · C = Codex dev-process dispatch · D = Portability/productization · **E = Harness decoupling**)
- **Project home:** `~/.claude/profile-system/` (this repo)
- **Builds on:** C (`docs/specs/2026-05-31-codex-dispatch-design.md`) and D (`docs/specs/2026-06-10-portability-productization-design.md`). **Generalizes C without rewriting it** — C's behavior becomes one cell of E's matrix and remains the back-compat default.

---

## 1. Goal

Today the dev-process dispatch (Subsystem C) **fuses two concerns into one bash engine**: it is *both* the orchestrator (the autonomous `dispatch → verify → retry → needs_review` loop) *and* the primitive library (worktree, ledger, land, verify). And the model the worker runs is only swappable *inside* one fixed harness — every path funnels through `codex exec`.

Subsystem E **splits those two concerns into two orthogonal axes** and inverts the control relationship:

- **Harness** = *who orchestrates the dispatch* → the **native `Agent`/`Workflow` tool**, with Claude live in the loop. The bash autonomous loop is demoted off the critical path.
- **Worker** = *a native Agent cell*; the **model is a field on the cell**. For Claude models the cell implements directly; for non-Claude models (gpt-5.5, gpt-5.4, qwen, …) the cell **composes a precise codex prompt via agent tooling and delegates the implementation to `codex exec -m <model>`**.

`codex_dispatch.sh` is demoted from orchestrator to **a called library** (`lib/dispatch-lib.sh`): worktree + ledger + the `codex exec` invocation + verify/land/console primitives. It *runs nothing on its own initiative*; the harness calls it.

Four payoffs drive the design (user-prioritised, 2026-06-13):

1. **Cost / token offload** — Claude stays in the cheap orchestrator+reviewer+prompt-composer seat; gpt/qwen do the implementation grunt-work.
2. **Parallel multi-model bake-off** — fan the same task to gpt + qwen + Claude in isolated worktrees, diff-compare, land the winner.
3. **Harness independence / portability** — orchestration is no longer hostage to codex CLI drift (C's R4/D's R5); a clean library others can extend with new models.
4. **Live observability + attach/switch** — a "classic dispatch console" surfacing what every agent is doing across models, with the ability to switch into a running one.

This spec covers **only Subsystem E**. It consumes C's machinery and D's portable backends; it does not modify A or the role framework.

---

## 2. The constraint that shapes everything (L6)

Subsystem D, decision **L6**, established: *"Claude Code's native Task/Agent subagents run Claude models and cannot be repointed at Ollama."* E confirms the same wall against OpenAI:

> The native `Agent` tool's `model` parameter is a **Claude-only enum** (`sonnet | opus | haiku | fable`). There is no provider override and no per-subagent way to point a native cell at gpt-5.5. The same holds for `Workflow`'s `agent({model})`.

**Consequence (the keystone):** "a native agent cell whose model is gpt-5.5" is not directly expressible. The *intent* is achieved with **one layer of indirection** — the cell is a native Claude cell (cheap), and for non-Claude models its body runs `codex exec -m <model>` inside its worktree. From the authoring surface it reads as "native cell, model is a field"; under the hood non-Claude models ride in through codex because that is the only door L6 leaves open. The Claude wrapper earns its tokens by doing the **codebase understanding + codex-prompt composition** before handing off.

---

## 3. Locked decisions (resolved in brainstorming, 2026-06-13)

| # | Decision | Choice |
|---|----------|--------|
| E1 | Control inversion | **`codex_dispatch` becomes a called library** (`lib/dispatch-lib.sh`), not an orchestrator. The harness calls it; it initiates nothing. |
| E2 | Harness | **Native `Agent` tool** for single dispatch; **`Workflow` tool** for the parallel bake-off. No bash orchestrator on the critical path. |
| E3 | Worker unit | **A native Agent cell.** One mechanism for every dispatch. |
| E4 | Model selection | **A field on the cell.** `claude` → cell implements directly; non-Claude → cell composes a prompt and delegates to `codex exec -m <model>`. (Bounded by L6 — §2.) |
| E5 | Prompt composition | **The cell composes the codex prompt through agent tooling** (Read/Grep/Glob → files, constraints, acceptance) before delegating. This is the cell's core value, not a passthrough. |
| E6 | Worker-axis bash surface | **Zero new per-worker files.** The codex-family worker is the *existing* one-function selector `d_backend_args` + the single call site `d_codex_exec`. `lib/local-*.sh` are model-**server lifecycle** (orthogonal) and stay untouched. |
| E7 | Worktree ownership | **Library-owned** (today's model) — one lifecycle owner, cleanest for `land`/`verify`/`doctor`. Not harness `isolation:"worktree"`. (MC-A resolved.) |
| E8 | Old autonomous loop | **Kept as a back-compat `harness=codex` path through Phase 1; retire in Phase 3** once the cell path proves out. (MC-B resolved.) |
| E9 | Land & guardrails | **Unchanged from C.** `land` still refuses unless `needs_review` + verified, rebases + re-verifies + merges, clean-aborts on conflict. The Layer-1 seatbelt lives in the library where mechanism belongs. |
| E10 | Native-cell pair validation | The engine validates `(harness, model)`: a Claude-model worker is only meaningful as a direct cell; non-Claude requires the codex delegation path. Illegal/empty combinations fail loudly. |

### 2.1 Environment facts (verified 2026-06-13)
- `Agent` tool `model` enum: `sonnet | opus | haiku | fable` (Claude-only); supports `run_in_background: true` and `isolation: "worktree"`.
- `Workflow` `agent({model, isolation, agentType, schema})` — same Claude-only model constraint; agents may shell to `codex` via Bash.
- `codex exec -m <model>` selects the model; `--oss --local-provider ollama -m <model>` for local (D.2). The single call site and version-drift mitigations from C (R4) and D (R5) are inherited.

---

## 4. System overview

```
        ┌──────────────────────── ORCHESTRATOR (main Claude session) ───────────────────────┐
        │  picks task → spawns dispatch CELL(s) via the native Agent/Workflow tool           │
        │  reviews returned verdict/diff → calls land | abandon                              │
        └───────────────┬───────────────────────────────────────────────┬───────────────────┘
                        │ Agent tool (run_in_background)                 │ Workflow (Phase 2: bake-off)
                        ▼                                                ▼
        ┌─ DISPATCH CELL (a native Claude subagent) ─┐      fan out N cells at {gpt, qwen, claude}
        │ 1. COMPOSE codex prompt via agent tooling  │      each in its own library worktree,
        │    (Read/Grep/Glob → files/constraints/AC) │      pipeline: compose → run → verify → verdict
        │ 2. DELEGATE by model:                      │      → orchestrator diff-compares, lands one
        │    claude   → implement directly           │
        │    gpt/qwen → dispatch-lib codex-run -m …  │
        │ 3. VERIFY + record status → return verdict │
        └───────────────┬────────────────────────────┘
                        │ calls (never orchestrated by)
                        ▼
        ┌──────────── lib/dispatch-lib.sh  (CALLED LIBRARY) ────────────┐
        │ begin · codex-run · verify · record · attach · console        │
        │ land · abandon · list · show         (Layer-1 land safety)    │
        │   worktree (library-owned) + ledger sidecar + event log        │
        └────────────────────────────────────────────────────────────────┘
```

State still lives **with the target repo**: sidecar at `$(git rev-parse --git-dir)/codex-dispatch/<id>.json`, library-owned worktree at `<repo>/.codex-dispatch-worktrees/<id>/`, plus a new per-dispatch **event log** `<id>.events.jsonl` beside the sidecar. The ledger is the single source of truth that makes the console uniform across Claude and gpt cells.

---

## 5. Detailed design

### 5.1 Component layout (additive; mirrors A/C's engine+lib+skill+command shape)

```
~/.claude/profile-system/
├── codex_dispatch.sh             # KEPT — thin CLI front; harness=codex back-compat loop (E8) + delegates to lib
├── lib/
│   ├── dispatch-lib.sh           # NEW — harness-agnostic CALLED LIBRARY (the §5.2 extraction)
│   ├── dispatch.sh               # SLIMMED — codex-family worker adapter (d_codex_exec/_resume, d_backend_args)
│   │                             #            + the demoted harness=codex autonomous loop (back-compat only)
│   ├── console.sh                # NEW — event-log tail + unified live board (attach/console)
│   └── local-*.sh                # UNTOUCHED — model-server lifecycle (orthogonal axis)
├── skills/dispatch/SKILL.md      # NEW — the dispatch-cell contract (compose → delegate → verify → report)
├── workflows/dispatch-bakeoff.js # NEW (Phase 2) — Workflow orchestrator for the multi-model bake-off
├── commands/dispatch.md          # NEW — /dispatch (supersedes /codex-implement; back-compat alias retained)
└── tests/dispatch_*_test.sh      # EXTEND — fake codex + fake cells + console/attach + pair-validation
```

### 5.2 The extraction (what becomes the library vs. what stays codex-specific)

A clean fault line already exists inside today's `lib/dispatch.sh`:

| Harness-agnostic → `lib/dispatch-lib.sh` | codex-specific → stays in `lib/dispatch.sh` |
|---|---|
| identity `d_now`/`d_slugify`/`d_short` | `d_codex_exec` / `d_codex_resume` (the sole codex call site) |
| worktree mgmt, gitignore, `d_sync_deps` | `d_codex_session_id` |
| sidecar/ledger I/O `d_sc_*`, `d_list_ids` | `d_backend_args` (the one-function model selector) |
| `d_run_checks` | |
| commit/diff/`d_has_changes`/`d_touches_tests` | |
| `land` rebase+verify+merge, `abandon`, `doctor` | |

The left column (~70% of the file) knows nothing about workers — that is the portability win (payoff 3). The right column **is** the codex-family worker adapter, already a single self-contained unit; adding a model = one `case` arm in `d_backend_args` (E6).

### 5.3 The dispatch cell (`skills/dispatch/SKILL.md`)

A native Claude subagent, spawned by the orchestrator (default `run_in_background: true`). Its rigid contract:

1. **Compose (E5).** Use Read/Grep/Glob to understand the task in repo context; produce a precise codex prompt — target files, constraints, acceptance criteria. This is where Claude's codebase understanding is spent.
2. **Begin.** `dispatch-lib begin <slug>` → library-owned worktree + ledger entry (`status=running`), returns `<id>`.
3. **Delegate by model (E4).**
   - `model=claude` → the cell edits files directly in the worktree (no codex).
   - `model=gpt-5.5|qwen|…` → `dispatch-lib codex-run <id> -m <model> "<composed-prompt>"`, which runs `codex exec` in the worktree, streaming `--json` events to the event log.
4. **Verify + record.** `dispatch-lib verify <id> --check '<cmd>'`; `record <id> --status needs_review|failed`.
5. **Return a structured verdict** (id, status, diffstat, check summary, `touches_tests`). The harness re-invokes the orchestrator on completion.

The cell **never** lands. Landing is the orchestrator's explicit, reviewed decision (E9).

### 5.4 The called-library API (`lib/dispatch-lib.sh`)

Every subcommand merely exposes a primitive; **none orchestrates**:

| Call | Role |
|---|---|
| `begin <slug>` | library-owned worktree + ledger entry; returns `<id>` |
| `codex-run <id> -m <model> "<prompt>"` | run `codex exec` (via the §5.2 adapter) in the worktree; stream `--json` → event log |
| `verify <id> --check '<cmd>'` | run checks in the worktree; record exit + output tail + `touches_tests` |
| `record <id> --status <s>` | cell/orchestrator updates ledger status |
| `attach <id>` | live-tail one dispatch's event log ("switch into what it's doing") |
| `console` | one board: every in-flight dispatch — `id · harness · model · status · last-activity` |
| `land <id>` / `abandon <id>` | unchanged from C — Layer-1 land safety (E9) |
| `list` / `show <id> [--diff]` | unchanged from C — E1 diff token economy preserved |

### 5.5 Observability & attach (payoff 4)

- **Event log.** Each dispatch gets `<id>.events.jsonl` beside the sidecar: append-only `{ts, phase, kind, line}`. The library and the streamed `codex --json` output both write to it.
- **`attach <id>`** live-tails that one log — for gpt cells this surfaces the model's progress *inside* the cell, independent of any UI, steerable via `resume "<feedback>"` (codex is non-interactive: steer-by-resume, not TUI takeover).
- **`console`** aggregates every sidecar's `status` + last event line into one refreshing board — the cross-model dispatch pane.
- **Harness-native surfacing.** Because cells are native, they *also* appear in Claude Code's background-agent switcher (single dispatch) and the `/workflows` live view (bake-off) for free. The ledger keeps the board uniform regardless.

### 5.6 The Workflow bake-off (Phase 2, `workflows/dispatch-bakeoff.js`)

Fan the same task to N `{model}` cells, each its own library worktree, `pipeline(compose → codex-run/implement → verify → structured verdict)`; the orchestrator diff-compares survivors and lands exactly one via the **same** `land <id>`. gpt/qwen cells shell to the library; the Claude contestant is a direct native cell. All write the **same ledger**, so `console` and `land` stay uniform. Surfaced live via `/workflows`.

### 5.7 Back-compat (E8)

`harness=codex` — today's autonomous `dispatch`/`resume`/`land` loop — remains callable through `codex_dispatch.sh` and `/codex-implement` for Phase 1, unchanged, so nothing in flight breaks. It is retired in Phase 3 once the cell path is proven, with `/codex-implement` left as an alias to `/dispatch`.

---

## 6. Build & sequencing

- **Phase 1 (the seam + offload + observability).** Extract `lib/dispatch-lib.sh`; add `codex-run`/`begin`/`verify`/`record`; add `console.sh` (`attach`/`console`); ship `skills/dispatch/SKILL.md` (compose→delegate→verify→report) and `/dispatch` for single dispatch at `model=gpt`. Keep `harness=codex` back-compat. **Highest value, smallest blast radius.**
- **Phase 2 (multi-model quality lever).** `workflows/dispatch-bakeoff.js` — parallel fan-out across models incl. a direct-Claude contestant; orchestrator diff-compare + single land.
- **Phase 3 (portability polish).** Add-a-model recipe (one `d_backend_args` arm + doc), plugin packaging (extends D.6), contributor docs; retire the `harness=codex` autonomous loop.

Each phase ships its own implementation plan (`docs/plans/`) and lands via the Claude-plans / cell-implements workflow with green tests.

---

## 7. Acceptance criteria

E is "done" (through Phase 1) when, on this machine:

1. `lib/dispatch-lib.sh` exists and exposes `begin`/`codex-run`/`verify`/`record`/`attach`/`console`/`land`/`abandon`/`list`/`show`; `codex_dispatch.sh` delegates to it; **C's existing tests still pass** against the slimmed `dispatch.sh`.
2. A dispatch cell spawned via the `Agent` tool: composes a codex prompt from repo context, calls `codex-run -m <gpt-model>`, the work lands in the **library-owned worktree** (not the live tree), verification runs, and a structured verdict returns to the orchestrator — with the **full diff NOT auto-dumped** (E1 preserved).
3. `attach <id>` live-tails the cell's event log and shows codex `--json` progress; `console` lists every in-flight dispatch with `id · harness · model · status · last-activity`.
4. `land <id>` refuses unless `needs_review` + verified; on success rebases onto HEAD, re-verifies, merges, removes the worktree, sets `landed`; clean-aborts + retains the worktree on conflict (E9 == C's C3/flag-2).
5. Pair validation (E10): an illegal `(harness, model)` combination fails loudly with the correct next command; a non-Claude model with no codex available errors cleanly.
6. `harness=codex` back-compat: the original `/codex-implement` autonomous flow still works end-to-end (E8).
7. The model axis adds a model with a **single `d_backend_args` arm and no new files** (E6), proven by a test.

### Testing approach

- Extends C/D's **dependency-free pure-bash harness**, sandbox-isolated (`CC_PROFILE_ROOT`, `CODEX_HOME`, `CODEX_DISPATCH_CODEX_BIN`, `CODEX_DISPATCH_FAKE_STATE`, `OLLAMA_HOST` + fake-curl).
- New: `dispatch_lib_extraction_test.sh` (library primitives in isolation, C-tests-still-green), `dispatch_codex_run_test.sh` (`codex-run` → event log via fake codex), `dispatch_console_test.sh` (`attach`/`console` board from stubbed sidecars+event logs), `dispatch_pair_validation_test.sh` (E10 refusals), `dispatch_backcompat_test.sh` (E8 loop intact).
- **Boundary note** (as in C): the fakes prove the *library + cell orchestration shape*, not real model behavior. A short **manual smoke checklist** covers: a real cell composing a prompt + delegating to real `codex exec -m <model>`; `attach` showing live progress; a real bake-off landing one winner; the native switcher / `/workflows` surfacing cells.
- **Workflow caveat:** the Phase-2 bake-off orchestrator is JS run by the harness, not unit-testable in the bash harness; it is covered by the manual smoke checklist + schema validation of cell verdicts.

---

## 8. Out of scope
- **Subsystem A/B/D internals** — E consumes their machinery; it modifies none.
- **Repointing the native `Agent` tool at a non-Claude provider** — forbidden by L6 (§2); the codex-delegation indirection is the sanctioned path.
- **A TUI takeover of a running codex session** — codex `exec` is non-interactive; "switch into" a gpt cell = live-tail + steer-by-`resume` (§5.5).
- **Cross-repo / multi-repo dispatch orchestration**; persistent analytics beyond the per-dispatch sidecars + event logs.
- **`/agentdev:develop` integration** — a sibling track (native meta-development); related but specified separately.

---

## 9. Risks & mitigations
- **R1 — Thin-wrapper token creep.** A cell that over-reasons before delegating erodes the offload economics. *Mitigation:* the SKILL bounds the compose step to context-gathering + prompt construction; heavy implementation reasoning is explicitly codex's job.
- **R2 — Split lifecycle confusion (worktree).** E7 keeps worktrees **library-owned** precisely so `land`/`verify`/`doctor` have one owner; native cells operate *in* the library worktree rather than a harness-isolated one. *Mitigation:* the cell `cd`s into the `begin`-returned path; doctor reconciles as in C (R6).
- **R3 — Event-log ↔ ledger drift.** A second per-dispatch artifact git can't see. *Mitigation:* `doctor` extended to prune orphan event logs alongside sidecars/worktrees.
- **R4 — codex CLI / oss-flag drift** (inherited C-R4 / D-R5). *Mitigation:* single call site in `dispatch.sh`; `codex-local-doctor` asserts the paths; version surfaced by `doctor`.
- **R5 — Bake-off worktree/VRAM contention** (Phase 2, many parallel cells). *Mitigation:* concurrency cap on the Workflow fan-out; local-model cells respect the model-server lifecycle (`l_ready`) before running.
- **R6 — Back-compat rot (E8).** Two dispatch paths during Phases 1–2. *Mitigation:* a hard Phase-3 retirement date for `harness=codex`; back-compat path frozen (no new features) until then.

---

## 10. Resolved micro-decisions
- **MC-A — Worktree ownership:** **library-owned** (E7).
- **MC-B — Old autonomous loop:** **keep as `harness=codex` back-compat through Phase 1; retire in Phase 3** (E8).
- **MC-C — Command name:** `/dispatch` (supersedes `/codex-implement`, which becomes an alias).
- **MC-D — Spec location:** `docs/specs/` (this repo's established subsystem-spec convention, matching A–D), not the brainstorming default.

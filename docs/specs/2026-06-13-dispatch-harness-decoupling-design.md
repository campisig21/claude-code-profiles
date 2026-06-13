# Subsystem E — Dispatch Harness Decoupling (polyglot dispatch + live console) — Design Spec

- **Date:** 2026-06-13
- **Status:** Approved (design); pending spec review
- **Revised:** 2026-06-13 — spec-review revisions folded in (model/backend two-axis, library/CLI seam, bake-off id, `land` coupling, observability, phase split); see §10 "Resolved in spec review". Status unchanged pending author re-read.
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
| E4 | Model selection | **A field on the cell**, resolved as a `(backend, model)` pair. `model=claude` → the cell implements directly (no codex). Non-Claude → the cell delegates via `dispatch codex-run --backend <codex\|ollama\|…> -m <model>`: `--backend` picks the codex flag-bundle (cloud vs `--oss`, via `d_backend_args`), `-m` picks the model. (Bounded by L6 — §2; the two sub-axes are detailed in §5.4 / E6.) |
| E5 | Prompt composition | **The cell composes the codex prompt through agent tooling** (Read/Grep/Glob → files, constraints, acceptance) before delegating. This is the cell's core value, not a passthrough. |
| E6 | Worker-axis bash surface | **Two orthogonal sub-axes, zero new per-worker files.** A worker is a `(backend, model)` pair: `--backend` selects the codex flag-bundle via the *existing* one-function selector `d_backend_args` (cloud `codex` / `ollama` / future providers); `-m <model>` selects the model at runtime. So adding a **cloud model** is **no code** (just `-m`); adding a **provider** is **one `d_backend_args` arm**. The single call site stays `d_codex_exec`. `lib/local-*.sh` are model-**server lifecycle** (orthogonal) and stay untouched. |
| E7 | Worktree ownership | **Library-owned** (today's model) — one lifecycle owner, cleanest for `land`/`verify`/`doctor`. Not harness `isolation:"worktree"`. (MC-A resolved.) |
| E8 | Old autonomous loop | **Kept as a back-compat `harness=codex` path through Phase 1; retire in Phase 3** once the cell path proves out. (MC-B resolved.) |
| E9 | Land & guardrails | **Unchanged from C.** `land` still refuses unless `needs_review` + verified, rebases + re-verifies + merges, clean-aborts on conflict. The Layer-1 seatbelt lives in the library where mechanism belongs. |
| E10 | Native-cell pair validation | **The library enforces it** (mechanism, per C's "engine is the seatbelt"): `codex-run` **refuses a Claude model** (Claude cells implement directly) and **refuses a non-Claude model when no codex/backend is available** — each failing loudly with the correct next command. A Claude-model worker is only meaningful as a direct cell. |

### 2.1 Environment facts (verified 2026-06-13)
- `Agent` tool `model` enum: `sonnet | opus | haiku | fable` (Claude-only); supports `run_in_background: true` and `isolation: "worktree"`.
- `Workflow` `agent({model, isolation, agentType, schema})` — same Claude-only model constraint; agents may shell to `codex` via Bash.
- **Two codex sub-axes that compose:** `-m <model>` selects the model; the **backend flag-bundle** selects the transport — nothing extra for cloud `codex`, `--oss --local-provider ollama` for local (D.2) — emitted by `d_backend_args`. E.g. cloud `codex exec -m gpt-5.5` vs local `codex exec --oss --local-provider ollama -m qwen2.5`. The single call site and version-drift mitigations from C (R4) and D (R5) are inherited.

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

State still lives **with the target repo**: sidecar at `$(git rev-parse --git-dir)/codex-dispatch/<id>.json`, library-owned worktree at `<repo>/.codex-dispatch-worktrees/<id>/`. The sidecar schema gains `harness` (`agent`\|`workflow`\|`codex`) and `model` fields alongside the existing `backend`; `console`/`show` **default** them for legacy sidecars (absent ⇒ `codex`/`—`, mirroring today's `backend` defaulting). Observability adds a per-dispatch **event log** `<id>.events.jsonl` beside the sidecar — the console-facing append-only `{ts, phase, kind, line}` stream — while C's raw `<id>.codexlog.jsonl` is retained unchanged as the verbatim codex `--json` capture (two artifacts, distinct roles). Concurrent appenders to `events.jsonl` write **whole lines atomically** to avoid interleave corruption. The ledger is the single source of truth that makes the console uniform across Claude and gpt cells.

---

## 5. Detailed design

### 5.1 Component layout (additive; mirrors A/C's engine+lib+skill+command shape)

```
~/.claude/profile-system/
├── codex_dispatch.sh             # KEPT — thin CLI front; harness=codex back-compat loop (E8) + delegates to lib
├── bin/dispatch                  # NEW — CLI entrypoint the cell shells to (begin/codex-run/verify/record/attach/console/land/abandon/list/show); sources lib/dispatch-lib.sh
├── lib/
│   ├── dispatch-lib.sh           # NEW — harness-agnostic CALLED LIBRARY (the §5.2 extraction), exposed via bin/dispatch
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

The extraction crosses **two** files, not one. The worker-agnostic primitives already sit in `lib/dispatch.sh`; the orchestration commands (`land`/`abandon`/`doctor`, the verify loop, result formatting) sit in **`codex_dispatch.sh`**. Both files' worker-agnostic parts move into `lib/dispatch-lib.sh`:

| Harness-agnostic → `lib/dispatch-lib.sh` | Lives today in | codex-specific → stays in `lib/dispatch.sh` |
|---|---|---|
| identity `d_now`/`d_slugify`/`d_short` | `dispatch.sh` | `d_codex_exec` / `d_codex_resume` (the sole codex call site) |
| worktree mgmt, gitignore, `d_sync_deps` | `dispatch.sh` | `d_codex_session_id` |
| sidecar/ledger I/O `d_sc_*`, `d_list_ids` | `dispatch.sh` | `d_backend_args` (the one-function **backend** selector) |
| `d_run_checks`, commit/diff/`d_has_changes`/`d_touches_tests` | `dispatch.sh` | |
| `verification_satisfied`, `emit_result`/`emit_next_actions` | `codex_dispatch.sh` | |
| `land` rebase+verify+merge, `abandon`, `doctor` | `codex_dispatch.sh` | |

The `dispatch.sh` half (~70% of that file) knows nothing about workers — the portability win (payoff 3). Two things this redraw makes explicit:

- **`land` is *not* purely worker-agnostic today.** Its current `cmd_land` also feeds the landed dispatch's `codexlog.jsonl` into the **subsystem-B curator inbox** via `resolve_active_profile`/`profile_dir` (`lib/paths.sh`). **Decision:** the extracted `land` keeps the B.2 feed behind a single **injectable on-land hook** (a `d_on_land` callback, default = the curator feed, **no-op when profiles/`paths.sh` are absent**) — so the library stays portable while this machine's A/B learning loop is preserved.
- **The autonomous retry loop does *not* move.** `finish_verify`'s dispatch→verify→resume→retry loop stays on the demoted `harness=codex` path only (E8); on the cell path the **cell owns retry judgment** (§5.3), and the library's `verify` is single-shot.

The codex-specific column **is** the worker adapter; per E6, adding a *provider* = one `case` arm in `d_backend_args`, adding a *cloud model* = none.

### 5.3 The dispatch cell (`skills/dispatch/SKILL.md`)

A native Claude subagent, spawned by the orchestrator (default `run_in_background: true`). It shells to the `bin/dispatch` CLI (§5.1); because each Bash call is a fresh shell, the cell **captures the `<id>` echoed by `begin` and threads it through every later call**. Its rigid contract:

1. **Compose (E5).** Use Read/Grep/Glob to understand the task in repo context; produce a precise codex prompt — target files, constraints, acceptance criteria. This is where Claude's codebase understanding is spent.
2. **Begin.** `dispatch begin <slug> --label <model>` → library-owned worktree + ledger entry (`status=running`); echoes `<id>` on stdout — **the cell saves it**. `--label` disambiguates parallel same-slug contestants in the bake-off (§5.6).
3. **Delegate by `(backend, model)` (E4).**
   - `model=claude` → the cell edits files directly in the worktree (no codex). The library **refuses** `codex-run` for a Claude model (E10).
   - non-Claude → `dispatch codex-run <id> --backend <codex|ollama|…> -m <model> "<composed-prompt>"` runs `codex exec` in the worktree, streaming `--json` events to the event log.
4. **Verify + record.** `dispatch verify <id> --check '<cmd>'` runs the checks **once** (recording exit + output tail + `touches_tests`). The cell — not a bash loop — then **decides** resume vs. accept vs. fail and calls `record <id> --status needs_review|failed`. (C's autonomous retry loop runs only on the back-compat path, E8.)
5. **Return a structured verdict** (id, harness, backend, model, status, diffstat, check summary, `touches_tests`). The harness re-invokes the orchestrator on completion.

The cell **never** lands. Landing is the orchestrator's explicit, reviewed decision (E9).

### 5.4 The called-library API (`lib/dispatch-lib.sh`)

All subcommands are exposed by the `bin/dispatch` CLI front (§5.1), which sources `lib/dispatch-lib.sh`. Every subcommand merely exposes a primitive; **none orchestrates**:

| Call | Role |
|---|---|
| `begin <slug> --label <model>` | library-owned worktree + ledger entry; returns `<id>`. The `<id>`/branch embed `--label`, so parallel same-slug contestants never collide (§5.6) |
| `codex-run <id> --backend <codex\|ollama\|…> -m <model> "<prompt>"` | run `codex exec` (via the §5.2 adapter) in the worktree; stream `--json` → event log. `--backend` selects the flag-bundle (`d_backend_args`), `-m` the model. **Refuses a Claude model** (E10) |
| `verify <id> --check '<cmd>'` | run checks in the worktree **once**; record exit + output tail + `touches_tests`. No auto-retry — retry judgment is the cell's (§5.3) |
| `record <id> --status <s>` | cell/orchestrator updates ledger status |
| `attach <id>` | live-tail one dispatch's event log ("switch into what it's doing") |
| `console` | one board: every in-flight dispatch — `id · harness · backend · model · status · last-activity` |
| `land <id>` / `abandon <id>` | unchanged from C — Layer-1 land safety (E9); `land` keeps the B.2 curator feed via the injectable hook (§5.2) |
| `list` / `show <id> [--diff]` | unchanged from C — E1 diff token economy preserved |

### 5.5 Observability & attach (payoff 4)

- **Event log.** Each dispatch gets `<id>.events.jsonl` beside the sidecar: append-only `{ts, phase, kind, line}`. The library writes phase/lifecycle markers and `codex-run` forwards a projection of the codex `--json` progress lines into it (the verbatim stream still lands in C's `<id>.codexlog.jsonl`). Writers append whole lines atomically so concurrent contestants never corrupt the log.
- **`attach <id>`** live-tails that one log — for gpt cells this surfaces the model's progress *inside* the cell, independent of any UI, steerable via `resume "<feedback>"` (codex is non-interactive: steer-by-resume, not TUI takeover).
- **`console`** aggregates every sidecar's `status` + last event line into one refreshing board — the cross-model dispatch pane.
- **Harness-native surfacing.** Because cells are native, they *also* appear in Claude Code's background-agent switcher (single dispatch) and the `/workflows` live view (bake-off) for free. The ledger keeps the board uniform regardless.

### 5.6 The Workflow bake-off (Phase 2, `workflows/dispatch-bakeoff.js`)

Fan the same task to N `(backend, model)` contestants — e.g. `(claude, —)` a direct cell, `(codex, gpt-5.5)`, `(ollama, qwen2.5)` — each in its own library worktree, `pipeline(compose → codex-run/implement → verify → structured verdict)`. Each contestant calls `begin <slug> --label <model>`, so its `<id>`/branch embed the model and **parallel same-slug starts never collide** (C's id is second-granularity and its branch is unique-or-die, so an unlabelled same-slug fan-out would fail `git worktree add`). The orchestrator diff-compares survivors and lands exactly one via the **same** `land <id>`. gpt/qwen cells shell to `bin/dispatch`; the Claude contestant is a direct native cell. All write the **same ledger**, so `console` and `land` stay uniform; a concurrency cap (R5) bounds parallel worktrees/VRAM. Surfaced live via `/workflows`.

### 5.7 Back-compat (E8)

`harness=codex` — today's autonomous `dispatch`/`resume`/`land` loop — remains callable through `codex_dispatch.sh` and `/codex-implement` for Phase 1, unchanged, so nothing in flight breaks. It is retired in Phase 3 once the cell path is proven, with `/codex-implement` left as an alias to `/dispatch`.

---

## 6. Build & sequencing

- **Phase 1a (pure extraction — zero behavior change).** Move the worker-agnostic primitives **and** the orchestration commands (`land`/`abandon`/`doctor`/`verification_satisfied`/`emit_*`) into `lib/dispatch-lib.sh` behind `bin/dispatch`; rewire `codex_dispatch.sh` to consume it; thread `land`'s B.2 feed through the injectable hook (§5.2). **C's existing tests stay green** — the bisect-clean checkpoint for relocating the safety-critical land code.
- **Phase 1b (the seam + offload + observability).** Add `begin`/`codex-run`/`verify`/`record`; the sidecar `harness`/`model` fields; `console.sh` (`attach`/`console`); ship `skills/dispatch/SKILL.md` (compose→delegate→verify→report) and `/dispatch` for single dispatch at `(codex, gpt-5.5)`. Keep `harness=codex` back-compat. **Highest value, smallest blast radius.**
- **Phase 2 (multi-model quality lever).** `workflows/dispatch-bakeoff.js` — parallel fan-out across models incl. a direct-Claude contestant; orchestrator diff-compare + single land.
- **Phase 3 (portability polish).** Add-a-model recipe (one `d_backend_args` arm + doc), plugin packaging (extends D.6), contributor docs; retire the `harness=codex` autonomous loop.

Each phase ships its own implementation plan (`docs/plans/`) and lands via the Claude-plans / cell-implements workflow with green tests.

---

## 7. Acceptance criteria

E is "done" (through Phase 1) when, on this machine:

1. `lib/dispatch-lib.sh` exists and exposes `begin`/`codex-run`/`verify`/`record`/`attach`/`console`/`land`/`abandon`/`list`/`show` through the `bin/dispatch` CLI; `codex_dispatch.sh` delegates to it; **C's existing tests still pass** against the slimmed `dispatch.sh` (the Phase-1a checkpoint).
2. A dispatch cell spawned via the `Agent` tool: composes a codex prompt from repo context, calls `codex-run -m <gpt-model>`, the work lands in the **library-owned worktree** (not the live tree), verification runs, and a structured verdict returns to the orchestrator — with the **full diff NOT auto-dumped** (E1 preserved).
3. `attach <id>` live-tails the cell's event log and shows codex `--json` progress; `console` lists every in-flight dispatch with `id · harness · backend · model · status · last-activity`, defaulting `harness`/`model` for legacy sidecars.
4. `land <id>` refuses unless `needs_review` + verified; on success rebases onto HEAD, re-verifies, merges, removes the worktree, sets `landed`; clean-aborts + retains the worktree on conflict (E9 == C's C3/flag-2).
5. Pair validation (E10): an illegal `(harness, model)` combination fails loudly with the correct next command; a non-Claude model with no codex available errors cleanly.
6. `harness=codex` back-compat: the original `/codex-implement` autonomous flow still works end-to-end (E8).
7. The worker axis is two sub-axes (E6): adding a **cloud model** is a `-m <model>` passthrough with **no code change**, proven by a test; adding a **provider** is a **single `d_backend_args` arm and no new files**, proven by a separate test.

### Testing approach

- Extends C/D's **dependency-free pure-bash harness**, sandbox-isolated (`CC_PROFILE_ROOT`, `CODEX_HOME`, `CODEX_DISPATCH_CODEX_BIN`, `CODEX_DISPATCH_FAKE_STATE`, `OLLAMA_HOST` + fake-curl).
- New: `dispatch_lib_extraction_test.sh` (library primitives in isolation, C-tests-still-green, the `land` B.2 hook fires), `dispatch_codex_run_test.sh` (`codex-run` two-axis `--backend`/`-m` → event log via fake codex, plus the SKILL's `begin→codex-run→verify→record` bash spine against a fake cell), `dispatch_console_test.sh` (`attach`/`console` board from stubbed sidecars+event logs, incl. legacy-sidecar defaulting), `dispatch_pair_validation_test.sh` (E10 refusals), `dispatch_bakeoff_id_test.sh` (parallel same-slug `begin --label` yields distinct ids/branches), `dispatch_addmodel_test.sh` (cloud model = `-m` no-code; provider = one `d_backend_args` arm — AC7), `dispatch_backcompat_test.sh` (E8 loop intact).
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
- **R3 — Event-log artifacts ↔ ledger drift.** Two per-dispatch artifacts git can't see (`events.jsonl` console stream + C's `codexlog.jsonl` verbatim capture). *Mitigation:* `doctor` extended to prune orphan logs alongside sidecars/worktrees; concurrent appenders write whole lines atomically (§4) so the streams never interleave-corrupt.
- **R4 — codex CLI / oss-flag drift** (inherited C-R4 / D-R5). *Mitigation:* single call site in `dispatch.sh`; `codex-local-doctor` asserts the paths; version surfaced by `doctor`.
- **R5 — Bake-off worktree/VRAM contention** (Phase 2, many parallel cells). *Mitigation:* concurrency cap on the Workflow fan-out; local-model cells respect the model-server lifecycle (`l_ready`) before running.
- **R6 — Back-compat rot (E8).** Two dispatch paths during Phases 1–2. *Mitigation:* a hard Phase-3 retirement date for `harness=codex`; back-compat path frozen (no new features) until then.

---

## 10. Resolved micro-decisions
- **MC-A — Worktree ownership:** **library-owned** (E7).
- **MC-B — Old autonomous loop:** **keep as `harness=codex` back-compat through Phase 1; retire in Phase 3** (E8).
- **MC-C — Command name:** `/dispatch` (supersedes `/codex-implement`, which becomes an alias).
- **MC-D — Spec location:** `docs/specs/` (this repo's established subsystem-spec convention, matching A–D), not the brainstorming default.

### Resolved in spec review (2026-06-13)
- **MC-E — Worker axis is two sub-axes:** `--backend` (flag-bundle, via `d_backend_args`) × `-m <model>`. Cloud model = no code; provider = one `case` arm. Resolves the model/backend conflation (rewrote E6 / AC7 / §5.4 / §5.6).
- **MC-F — CLI entrypoint:** `bin/dispatch` sources `lib/dispatch-lib.sh` and exposes its subcommands; the cell shells to it and threads the `begin`-returned `<id>` across Bash calls.
- **MC-G — Bake-off id collision:** `begin <slug> --label <model>` embeds the contestant in the `<id>`/branch, so parallel same-slug fan-out can't collide on second-granularity ids.
- **MC-H — `land`'s subsystem-B coupling:** the curator feed survives extraction behind an injectable on-land hook (no-op when profiles absent), keeping the library portable.
- **MC-I — Two log artifacts:** `events.jsonl` (console-facing) is distinct from C's `codexlog.jsonl` (verbatim capture); concurrent appenders write whole lines atomically.
- **MC-J — E10 enforcement is library-level:** `codex-run` refuses a Claude model / a codex-less non-Claude model, loudly.
- **MC-K — Phase 1 splits into 1a (pure extraction, C-tests-green) + 1b (the seam),** de-risking the relocation of the land-safety code.

### Resolved in Phase 1b implementation (2026-06-13)
- **`d_backend_args` left unchanged; `-m` is a separately-appended axis.** `dispatch_backend_ollama_test.sh` pins the existing arm output (incl. the `ollama` arm's default `-m qwen2.5-coder`), so `codex-run` appends `-m <model>` after the transport bundle. For `(codex, *)` this is exactly `-m <model>` (empty bundle); for the one model-conflated `ollama` arm the cell's `-m` wins last (harmless redundant earlier `-m`). Keeps back-compat green while delivering the clean two-axis (AC7).
- **`bin/dispatch` sources the codex adapter** (`lib/dispatch.sh`) for `codex-run`; the portable `lib/dispatch-lib.sh` stays codex-free (the one-way seam holds). Observability readers are `lib/console.sh`; the `d_event` writer lives in the library so every verb (begin/codex-run/verify/record) can append.
- **`verify` persists `requested_checks`** (the cmds it ran) so the unchanged `land` can replay them on its post-rebase re-verify for cell-path dispatches.
- **Status line intentionally unchanged** — pending author re-read.

### Resolved in Phase 2 implementation (2026-06-13)
- **The bake-off is a `Workflow`-tool script** (`workflows/dispatch-bakeoff.js`, the first file in a new `workflows/` dir): `parallel()` fan-out of contestant cells (each the Phase-1b dispatch SKILL contract) → a judge agent ranks survivors → it **returns verdicts + a recommendation and lands nothing**. The orchestrator reviews the recommended winner's diff and runs `land` (exactly one) + `abandon` (the rest), so **E9 holds end-to-end** — landing is never inside the workflow or a cell.
- **Invocation / Workflow opt-in:** a new `/dispatch-bakeoff` command (`commands/dispatch-bakeoff.md`) is the explicit opt-in to the `Workflow` tool and parses `--models`/`--check`; it invokes the workflow by **`scriptPath`** (no dependency on Claude Code's named-workflow discovery). It ships via the installer's existing `commands/*.md` symlink loop — no installer change. *Note:* §5.1 enumerated only `commands/dispatch.md`; this companion command is additive and is the natural ergonomic + opt-in surface for the parallel form.
- **Contracts are inline JSON-Schema literals** in the `.js` (verdict + recommendation). Workflow scripts have **no filesystem access**, so a separate `.json` schema can't be read at runtime; each contestant is forced to structured output via `agent({schema})`.
- **Testability boundary (as §7 "Workflow caveat" anticipated):** the orchestrator `.js` is not bash-unit-testable. Phase 2 covers it with (a) `dispatch_bakeoff_spine_test.sh` — the **library** land-one/abandon-rest flow with fakes; (b) static-lint tests of the `.js` and the command md; (c) the existing `dispatch_bakeoff_id_test.sh`; and (d) a manual smoke checklist (`docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md`).
- **Deferred to smoke (honest gaps):** true-concurrent `git worktree add` safety (the bash tests exercise sequential begins only — R5 contention) and the default Workflow subagent's editing tools for the direct-Claude contestant. Documented fallbacks: add a lock-retry to `d_begin` (paired-review change, not blind) / set `agentType` to a coding agent. **The seam is NOT touched in Phase 2** (no changes to `lib/*.sh`, `bin/dispatch`, or `skills/dispatch/SKILL.md`).
- **Status line intentionally unchanged** (still `Approved (design); pending spec review`).

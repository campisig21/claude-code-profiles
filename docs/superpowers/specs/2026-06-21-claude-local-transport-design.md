# Design — claude-on-station dispatch transport (`claude-run`)

- **Status:** Draft (pending review)
- **Date:** 2026-06-21
- **Governing decision:** [ADR-0004](../../decisions/0004-claude-local-dispatch-transport.md)
  (this spec is that ADR's canonical-source detail; on approval ADR-0004 → Accepted)
- **Related:** [ADR-0002](../../decisions/0002-local-serving-single-llama-jinja-no-proxy.md)
  (single server, no proxy), [ADR-0003](../../decisions/0003-default-local-dispatch-model.md)
  (default model), `ergonomic-wrapper-next` auto-memory (the Phase B plan)

> **Snapshot caveat.** Concrete values below (env var names, defaults, flags) are
> *design intent*. Once `bin/claude-run` exists it is the authoritative contract
> ([ADR-0001](../../decisions/0001-record-architecture-decisions.md): contracts
> live in code). Treat this dated spec as a point-in-time snapshot, not the live
> recipe.

---

## 1. Goal

Codify "drive `claude -p` against the local station" — today an un-codified,
prose-only recipe that has drifted across six docs — into a reliable, testable
primitive that an **agent** (not a human) invokes during a session, with worker
activity surfaced the way a native `/agents` subagent is.

Two phases, sequenced:

- **Phase A (this spec, in full):** the `claude-run` primitive + reachability
  doctor + a **streaming spike** that gates the surfacing contract + de-dup of
  the prose copies + a `dispatch` skill bullet + tests.
- **Phase B (sketched §11, own spec later):** wrap the Phase-A exec core in the
  dispatch cell lifecycle (worktree → scoped commit → sidecar) and add a
  `claude-local` bake-off contestant.

### Non-goals (Phase A)

- No worktree / commit / land / sidecar (that is Phase B).
- No managed proxy lifecycle — the proxy is retired (ADR-0002); the station
  serves Anthropic natively.
- No edits to `lib/dispatch.sh` — it is the **frozen seam**. All new code lives
  outside it (`lib/claude-local.sh`, `bin/claude-run`).

---

## 2. Background & constraints

- **The drift (why a primitive at all).** Audit (2026-06-21) found the env recipe
  in six places, **none** carrying `ANTHROPIC_SMALL_FAST_MODEL`; copies disagreed
  on the default model. An executable is the single source of truth an agent
  can't fumble (ADR-0001, ADR-0004).
- **The endpoint split (why two layers to surface).** A native Agent-tool
  subagent inherits the Anthropic-tier session endpoint — it **cannot be qwen**.
  So qwen work must run in a shelled `claude -p` process; the visible "subagent"
  is an Anthropic-tier cell that *proxies* the invisible qwen worker.
- **The background hazard (proven boundary).** `claude -p` must never be nested
  in a manual `nohup`/detached shell — it resets its parent shell and silently
  kills the orchestrator. **But the harness's own `run_in_background` facility is
  safe** — verified this session (a backgrounded `claude -p` task ran without
  killing the orchestrator). The streaming design rides that safe substrate.
- **Reasoning-model budget.** Models that emit a thinking block (e.g. qwen36)
  return empty `content[]` if `max_tokens` is too small — all tokens spent
  thinking. Callers must pass a real budget; documented as a caveat, not enforced.

---

## 3. Architecture & components

Two new files, both outside the frozen seam:

### `lib/claude-local.sh` — sourced library (no side effects on source)

| Function | Contract |
|---|---|
| `claude_local_resolve` | Resolves config → echoes the effective `URL / MODEL / SMALL_FAST_MODEL` (reads `CLAUDE_DISPATCH_*` with defaults). Pure; used by `env`, `exec`, `doctor`, and tests. |
| `claude_local_exec <dir> [claude-args…]` | `cd "$dir"`; `exec env -u ANTHROPIC_API_KEY <contract> "${CLAUDE_BIN:-claude}" -p "$@"`. The **exec core** Phase B wraps. `${CLAUDE_BIN:-claude}` is the test seam. |
| `claude_local_probe` | `${CURL_BIN:-curl}` → both endpoints; `READY` only on 200/200, else `NOT READY` + the two codes; nonzero exit when not ready. |
| `claude_local_digest` | Reads stream-json NDJSON on stdin → emits one concise line per worker step (`Read X`, `Edit Y`, `Bash … (exit n)`, final `result`). Used by the surfacing layer and pinned by fixture tests. |

### `bin/claude-run` — executable CLI (mirrors `bin/dispatch` conventions)

```
claude-run [--dir P] [--model M] [--stream] "<prompt>" [-- <extra claude flags>]
claude-run doctor      # claude_local_probe
claude-run env         # claude_local_resolve (debug: print the live contract)
```

- `--model M` overrides `CLAUDE_DISPATCH_MODEL` for this call (default per ADR-0003).
- `--stream` appends `--output-format stream-json --verbose` (plus any buffering
  fix the spike mandates, §6).
- `--dir P` sets the worker cwd (default `.`).
- `[-- <extra claude flags>]` passes `--allowedTools`, `--max-turns`,
  `--dangerously-skip-permissions`, etc. straight through; the caller owns tool
  policy.

### The env contract (design intent — code becomes authoritative)

| Var | Source | Default |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `CLAUDE_DISPATCH_URL` | `http://100.64.0.4:8080` |
| `ANTHROPIC_MODEL` | `CLAUDE_DISPATCH_MODEL` / `--model` | `qwen3-coder-30b` |
| `ANTHROPIC_SMALL_FAST_MODEL` | `CLAUDE_DISPATCH_SMALL_FAST_MODEL` | `= ANTHROPIC_MODEL` |
| `ANTHROPIC_AUTH_TOKEN` | constant | `dummy` |
| `ANTHROPIC_API_KEY` | unset (`env -u`) | — |

`ANTHROPIC_SMALL_FAST_MODEL` is the knob all six prose copies omitted: Claude
Code makes background/utility calls on a "small fast model"; left at its Haiku
default the station 404s them. Pointing it at a served alias is required hygiene.

---

## 4. Data flow

```
agent (orchestrator)                      surfaced as /agents-style activity
  └─ Agent tool ─► dispatch cell  (Anthropic-tier subagent)
                    └─ Bash ─► claude-run --stream "<prompt>" -- --allowedTools …
                                 └─ harness background task (safe substrate)
                                      └─ claude -p ─► station :8080 /v1/messages ─► qwen3-coder
                                 stream-json NDJSON ─► output file (accumulates)
                    cell polls file ─► claude_local_digest ─► narrates steps
  cell returns structured verdict ◄────────────────────────────────────────────
```

Phase A proves this **orchestrator-direct** (I run `claude-run --stream`, poll,
digest, narrate) as the live smoke. Phase B formalizes the cell wrapper.

---

## 5. Streaming spike — the gate (Task #4)

**Freeze nothing about surfacing until this passes.** The risk: stdout to a file
may block-buffer, so the digest wouldn't surface incrementally.

**Procedure:** run `claude-run --stream "<small real task>"` as a harness
background task against the live coder; while it runs, poll the output file.

**Acceptance:**
1. The output file **grows incrementally** (events visible before the process
   exits), not all-at-once on completion.
2. Each line parses as a JSON event with an identifiable type (tool_use / text /
   result).
3. `claude_local_digest` renders a readable per-step trace from the live stream.

**If it buffers:** apply `stdbuf -oL`/`-o0`, or a pty wrapper (`script -q`), to
`claude-run --stream`; re-confirm. Record the working mechanism in the skill
bullet. Only then freeze the surfacing contract.

---

## 6. Surfacing model

The **dispatch cell** (Agent-tool subagent) is the visible activity — labeled,
spinnered, result returned — exactly the native-subagent UX. It shells
`claude-run --stream`, polls, runs `claude_local_digest`, and narrates a running
trace of the qwen worker's tool calls (not just "running…"). The two layers are
forced by §2's endpoint split, not incidental. Phase A delivers the primitive +
proven streaming + digest + the documented contract; Phase B wires the cell.

---

## 7. De-dup plan (fix the drift)

Once `bin/claude-run` exists, trim the **live** copies to links; leave dated
spec/plan snapshots as history.

| Copy | Action |
|---|---|
| `station/llama-jinja/README.md` (Clients §) | Replace recipe with: "drive via `bin/claude-run` — see ADR-0004." |
| `claude-harness-local-model` memory | Trim no-proxy recipe to a pointer at `claude-run`; keep the LiteLLM *fallback* recipe (still useful). |
| `llama-jinja-station` memory | Keep the endpoint fact; point the harness recipe at `claude-run`. |
| `ergonomic-wrapper-next` memory | Already a plan; add the `claude-run` pointer. |
| dated specs / plans (2026-06-15) | **Leave as-is** — point-in-time snapshots. |

---

## 8. Error handling

- **doctor:** any non-200 → `NOT READY` + both codes, nonzero exit. Connection
  refused → `000` (station down / wrong model loading).
- **exec:** `claude` not found → clear error via the `${CLAUDE_BIN}` seam;
  station unreachable → surface curl's failure.
- **empty content[]:** documented reasoning-model caveat (pass real `max_tokens`).
- **buffering:** handled by the spike's mandated mechanism (§5).
- **hazard:** never manual-`nohup` `claude -p`; use the harness background
  facility. Stated in the skill bullet.

---

## 9. Testing

- **`tests/claude_run_test.sh`** (house harness, model-free, deterministic):
  - `ps_make_fake_claude` (mirrors `ps_make_fake_codex`): a fake `claude` that
    records the env it received and emits a **canned NDJSON fixture**.
  - Asserts: env contract incl. `ANTHROPIC_SMALL_FAST_MODEL`; `--model` override;
    `--stream` adds the right flags; `claude_local_digest` renders the fixture to
    the expected step trace; `doctor` READY/NOT-READY via the fake-curl seam.
  - Seams: `${CLAUDE_BIN}`, `${CURL_BIN}` (per fake-curl-test-seam skill).
- **Live smoke** (documented, manual): `claude-run doctor` → `claude-run --stream`
  a real qwen task → observe the incremental digest. This is also the spike.

The fixture pins the digest parser without burning a real qwen run; the spike
proves the bytes stream. Independent failure modes, tested independently.

---

## 10. Skill & docs deliverables

- **`dispatch` skill:** add a `claude-local` delegate bullet to the cell's
  "Delegate by `(backend, model)`" section — names `claude-run`, the
  foreground-not-nohup hazard, the reasoning-model budget, and the stream-json
  surfacing contract.
- **README / ADR:** flip ADR-0004 → Accepted on approval; `bin/claude-run`
  becomes its canonical source.

---

## 11. Phase B sketch (own spec later)

`claude-run` grows a lifecycle path that reuses `claude_local_exec` unchanged:
resolve worktree → exec → **scoped** commit (NOT `git add -A`; do not author a
`.gitignore` — both break `land`'s `--ff-only`, per `ergonomic-wrapper-next`) →
update sidecar. `claude-local` becomes a real dispatch delegate and a bake-off
contestant (enabling codex-on-qwen vs claude-on-qwen vs claude-on-claude).
Config: `CLAUDE_DISPATCH_*` already established in Phase A.

---

## 12. Risks & open questions

- **Spike outcome unknown** — if streaming can't be made incremental on this
  substrate, surfacing falls back to "coarse: cell reports at completion." A
  superseding note to ADR-0004 would record that.
- **Cell ↔ background-task across turns** — confirm a subagent can launch a
  harness background task and poll its output file across its own turns (validate
  in the Phase A live smoke before relying on it in Phase B).

---

## 13. Revision log (append-only)

- 2026-06-21 — initial draft.

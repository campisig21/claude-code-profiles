# Codex Dispatch — Local-Model Backend (Subsystem C.1) — Design Spec

- **Date:** 2026-05-31
- **Status:** Approved (design); pending spec review
- **Subsystem:** C.1 — an additive extension of C (Codex Dev-Process Dispatch).
- **Project home:** `~/.claude/profile-system/` (this repo)
- **Predecessor:** Subsystem C — `docs/specs/2026-05-31-codex-dispatch-design.md` (decisions C1–C7, E1–E2). **C is complete and merged; C.1 layers on top, additively.**

---

## 1. Goal

Add a **second dispatch backend** — a strong quantized coding model running on the user's
remote workstation — that works **alongside** the existing codex-cloud backend and, for
quick/low-stakes tasks, **instead of** it (free, offline-from-the-cloud, no token cost).

The defining constraint is that **C already isolated codex behind one function**
(`lib/dispatch.sh` `d_codex_exec` / `d_codex_resume` / `d_codex_session_id`, see C §4.6 / R4).
C.1 exploits that seam: the local backend is **codex's own agentic harness pointed at the
local model**, not a new edit loop. The engine stays a deterministic, codex-driven mechanism;
"local" is just *which codex profile* a dispatch uses.

C.1 inherits every C invariant unchanged: Claude is the policy-maker; the engine refuses
illegal transitions (Layer 1); worktree-per-dispatch isolation; Claude-gated landing;
diffstat-by-default token economy. **No C land/verify/abandon/sidecar logic is rewritten** —
C.1 is purely additive.

---

## 2. Why reuse the codex harness (and the concerns it carries)

A quantized model served by llama.cpp only *completes text* — it does not read files, edit
them, or run commands. The **agentic loop is the hard part**, and codex already provides it.
Codex 0.135 can target a non-default model via a custom **model provider** selected by a
**config profile** (`-p/--profile <name>`, which layers `$CODEX_HOME/<name>.config.toml`).
So the local backend = `codex … -p local`, reusing 100% of C's machinery.

Verified facts (this machine, 2026-05-31):
- `codex-cli 0.135.0`. `codex exec` supports `-m`, `--oss`, `--local-provider lmstudio|ollama`,
  `-c key=value`, `-p/--profile <name>`, `-C/--cd`, `--dangerously-bypass-approvals-and-sandbox`.
- `--oss` only targets **lmstudio or ollama** — **not raw llama.cpp**. llama.cpp therefore needs
  a **custom `[model_providers.*]`** (base_url → llama.cpp `/v1`, `wire_api="responses"` — see §11), delivered
  as a codex profile.
- The user reaches the workstation over a **headscale tailnet** (`ssh greg-campisi@100.64.0.4`).
  The tailnet IP is **directly reachable**, so the endpoint is `http://100.64.0.4:<port>/v1` over
  WireGuard — **no SSH port-forward needed**; WireGuard is the encrypted transport.
- Target model: **Qwen3 ~35B-A3B, Unsloth dynamic quant UD-Q6_K_XL** (MoE, ~3B active params).
  A tool-trained model at Q6 fidelity — the "weak quant emits malformed tool calls" risk is low.

### Concerns (honest), and how the design answers each
| # | Concern | Mitigation |
|---|---------|-----------|
| K1 | llama.cpp is not an `--oss` target. | One-time custom **codex profile** `local.config.toml` (config, not engine code). |
| K2 | Tool-call fidelity is make-or-break; a weak model produces an empty diff. | Q6 tool-trained model chosen; the engine's existing "no diff / checks fail" already surfaces it. |
| K3 | Local context window is smaller; the verify→resume retry loop grows context and can overflow. | Routing reserves local for small/quick tasks; default low `--retry` for local (policy in skill). |
| K4 | Weaker model ⇒ higher verifier-gaming risk. | Routing defaults local to stronger verify/review; C's `touches_tests` warning still fires. |
| K5 | Endpoint liveness: tailnet down, or up-but-model-not-loaded. | `doctor` + a `--backend local` **preflight** that refuses with the exact `local-up` command (Layer 1). |
| K6 | Speed: remote inference is slower per token. | Validates the routing split (local = quick/cheap/offline; codex-cloud = impactful). |

**Upside:** near-zero new *engine* code and *engine* tests — the single `d_codex_*` boundary
and C's fake-codex test seam (`CODEX_DISPATCH_CODEX_BIN`) already cover the backend swap.

---

## 3. Locked decisions (resolved in brainstorming, 2026-05-31)

| # | Decision | Choice |
|---|----------|--------|
| L1 | Seam shape | **A1 + resolver.** `--backend codex\|local` resolves through a one-line `d_backend_args <backend>` helper to codex profile flags. Leaves room for a non-codex executor later without reworking call sites. |
| L2 | Scope/sequencing | **Separate C-extension spec (this doc).** C stays frozen; C.1 lands after C. |
| L3 | Default backend | **`codex`** (cloud). Absent `--backend`, behavior is identical to C today. |
| L4 | Where the model edits | **Codex harness, running locally on the Mac**, against the repo's local worktree. Only inference HTTP crosses the tailnet. The repo never leaves the Mac. |
| L5 | Connectivity | **Direct tailnet URL** (`http://100.64.0.4:<port>/v1`). No `ssh -L` tunnel. |
| L6 | Helper scope | **Remote model lifecycle helper** (`local-up`/`local-down`) that SSHes to the workstation to load/unload the GGUF via the user's own llama.cpp start/stop command, then waits for readiness. (The "tunnel" half is moot on a tailnet.) |
| L7 | Routing | **Policy lives in the skill, not the engine** (per C: Claude is policy-maker). The engine only carries the `--backend` flag + enforces the local-readiness preflight. |

---

## 4. System overview

```
Claude (skill: routing policy) ── picks backend per task
   quick/trivial/offline → --backend local      impactful → (default) codex-cloud
                              │
                              ▼
codex_dispatch.sh dispatch|quick --backend codex|local
   │  records "backend" in sidecar
   │  if backend=local: PREFLIGHT readiness (refuse w/ local-up hint if not ready)  ← Layer 1
   ▼
d_backend_args <backend>                  ← NEW resolver (lib/dispatch.sh)
   codex → ""            (cloud default — unchanged behavior)
   local → "-p <CODEX_DISPATCH_LOCAL_PROFILE>"   (default "local")
   │
   ▼
d_codex_exec / d_codex_resume  (splice backend args into the codex call)
   │
   ▼
[ unchanged C machinery: worktree · verify+retry · touches_tests · land · sidecar ]

Side channel (remote model lifecycle, NOT in the dispatch path):
codex_dispatch.sh local-up   → ssh $LOCAL_SSH "$LOCAL_UP_CMD"   → poll /v1/models until ready
codex_dispatch.sh local-down → ssh $LOCAL_SSH "$LOCAL_DOWN_CMD" → free VRAM
codex_dispatch.sh doctor     → probe endpoint: unreachable | up-not-loaded | ready
```

The local backend's inference endpoint is the only thing that goes remote. Codex, git,
the worktree, and verification all run on the Mac against the local repo.

---

## 5. Detailed design

### 5.1 Components & file structure (additive over C)
```
~/.claude/profile-system/
├── codex_dispatch.sh                 # EXTEND — add --backend to dispatch/quick; add local-up/local-down; extend doctor
├── lib/dispatch.sh                   # EXTEND — d_backend_args(); thread backend args through d_codex_exec/d_codex_resume
├── lib/local.sh                      # NEW — remote model lifecycle: probe, ssh load/unload, readiness wait
├── install.sh                        # EXTEND — idempotently write $CODEX_HOME/local.config.toml if absent
└── tests/
    ├── lib.sh                        # EXTEND — fake ssh + endpoint-probe override; argv-capturing fake codex
    ├── dispatch_backend_test.sh      # NEW — resolver + flag threading + sidecar field
    ├── local_lifecycle_test.sh       # NEW — local-up/local-down/doctor state machine (stubbed ssh+probe)
    └── dispatch_local_preflight_test.sh  # NEW — --backend local refuses when not ready
```

### 5.2 The codex profile artifact (the only real "setup")
`install.sh` writes `$CODEX_HOME/local.config.toml` **only if absent** (never clobbers user edits):
```toml
model          = "qwen36-35b"                  # MUST equal the router alias at /v1/models
model_provider = "llamacpp"

[model_providers.llamacpp]
name     = "llama.cpp (workstation)"
base_url = "http://100.64.0.4:8080/v1"        # headscale IP; override via CODEX_DISPATCH_LOCAL_ENDPOINT at install
wire_api = "responses"                         # see §10 update — codex 0.135 requires Responses API; router serves /v1/responses
# NO env_key — codex demands the named env var EXIST; omitting it sends no auth (router accepts)
```
The `model` string and the provider `base_url` are derived from the env knobs (§5.6) at install
time. If the file exists, `install.sh` prints a note and leaves it untouched.

### 5.3 The resolver (L1) — `lib/dispatch.sh`
```sh
# d_backend_args <backend> -> echoes extra codex flags for that backend (space-separated).
#   codex -> (nothing)        local -> -p <profile>
d_backend_args() {
  case "$1" in
    codex|"") : ;;                                   # cloud default — no extra flags
    local)    printf '%s %s' -p "${CODEX_DISPATCH_LOCAL_PROFILE:-local}" ;;
    *)        return 1 ;;                             # unknown backend — caller dies
  esac
}
```
`d_codex_exec` / `d_codex_resume` gain a **leading backend-args parameter** (an array or
word-split string) spliced into the `codex` invocation immediately after the subcommand. The
parameter is threaded from `cmd_dispatch`/`cmd_quick` → `finish_verify` → the codex calls. When
backend=codex the args are empty and the invocation is byte-identical to C today (protects L3).

### 5.4 Engine CLI changes — `codex_dispatch.sh`
- `dispatch` and `quick` accept **`--backend codex|local`** (default `codex`). Validated against
  the same enum the resolver accepts; unknown value → `die` with the valid list.
- The sidecar gains **`"backend": "codex|local"`** (written at creation).
- `emit_result` and `list` surface the backend (one extra column / line).
- **Preflight (Layer 1):** when `--backend local`, before creating the worktree (`dispatch`) or
  editing in place (`quick`), call `l_ready` (§5.5). If not ready, **refuse** and print the exact
  `codex_dispatch.sh local-up` command. Refusal is factual (endpoint state), not judgment, so it
  belongs in the engine.
- **New subcommands** `local-up` / `local-down` (thin wrappers over `lib/local.sh`).
- `doctor` (C Task 8) is **extended** to call `l_probe` and report the three-state result
  alongside the codex version it already reports.

### 5.5 Remote model lifecycle — `lib/local.sh`
All remote/network calls go through injectable bins so tests can stub them
(`CODEX_DISPATCH_SSH_BIN` default `ssh`, `CODEX_DISPATCH_CURL_BIN` default `curl`).

- `l_probe` → echoes one of `unreachable | up-not-loaded | ready` by GET-ing
  `${CODEX_DISPATCH_LOCAL_ENDPOINT}/models`:
  - connection error / timeout → `unreachable`
  - HTTP 2xx but `CODEX_DISPATCH_LOCAL_MODEL` not in the returned model ids (or 503) → `up-not-loaded`
  - 2xx and the model id present → `ready`
- `l_ready` → returns 0 iff `l_probe` == `ready`.
- `l_up` → `ssh $LOCAL_SSH "$LOCAL_UP_CMD"`; then poll `l_probe` every N s up to a timeout until
  `ready`; print readiness or a timeout error. Idempotent (already-ready → no-op success).
- `l_down` → `ssh $LOCAL_SSH "$LOCAL_DOWN_CMD"` to free VRAM; best-effort.

The helper is **agnostic to how the model loads**. On this workstation llama.cpp runs **under
Docker**, so `LOCAL_UP_CMD` / `LOCAL_DOWN_CMD` will be docker invocations (e.g. `docker start
<container>` / `docker stop <container>`, or `docker compose up -d <svc>` / `down`). The exact
syntax is **pending verification** (§9 MC2) and supplied via env (§5.6); the helper only runs the
command and waits for `/v1/models` readiness — it never assumes a particular loader.

### 5.6 Configuration knobs (env, with defaults)
| Var | Default | Purpose |
|---|---|---|
| `CODEX_DISPATCH_LOCAL_PROFILE` | `local` | codex profile name the resolver passes to `-p`. |
| `CODEX_DISPATCH_LOCAL_SSH` | `greg-campisi@100.64.0.4` | SSH target for lifecycle commands. |
| `CODEX_DISPATCH_LOCAL_ENDPOINT` | `http://100.64.0.4:8080/v1` | OpenAI-compatible base URL probed for readiness; also written into the profile at install. |
| `CODEX_DISPATCH_LOCAL_MODEL` | `qwen3-35b-a3b-ud-q6_k_xl` *(pending verification)* | Model id; must equal the profile `model` and the Docker llama.cpp `/v1/models` id. Confirm against the live server. |
| `CODEX_DISPATCH_LOCAL_UP_CMD` | (unset → error in `local-up`) | Remote command that loads/starts the model. **Docker-based** on this station; exact syntax pending. |
| `CODEX_DISPATCH_LOCAL_DOWN_CMD` | (unset → no-op warning) | Remote command that unloads/stops the model. **Docker-based**; exact syntax pending. |
| `CODEX_DISPATCH_SSH_BIN` / `CODEX_DISPATCH_CURL_BIN` | `ssh` / `curl` | Test-injection seams. |

### 5.7 Routing policy (skill, not engine)
The `codex-implement` SKILL.md decision table (C §4.4 Layer 3) gains a **backend column**:
- **`quick --backend local`** — the headline path: fast, free, offline in-place edits for trivial
  / low-stakes tasks ("instead of codex").
- **`dispatch --backend local`** — isolated local run when a worktree is wanted but free/offline.
- **default `codex` (cloud)** — impactful work, large diffs, anything beyond the local context budget.
- Local defaults the skill applies: **low `--retry` (0–1)** and **verify leaning to `both`/`review`**
  (K3, K4). The engine enforces none of this — it only carries the flags and the readiness preflight.
- One new red-flag-table candidate (subject to C's ≤7 cap / category-phrasing rule): *"routed an
  impactful or large-context task to `--backend local`."* This is judgment Layer 1 cannot see, so it
  earns a red-flag slot; if the cap is hit, it merges with the existing verify-mode guidance.

---

## 6. Acceptance criteria

C.1 is "done" when, on this machine (with C already landed):
1. `dispatch --backend local --check '<cmd>' "<prompt>"` runs codex **with `-p local`** (verified via
   the argv-capturing fake), creates the worktree, verifies, and stops at `needs_review` — identical
   flow to C, only the backend differs; the sidecar records `"backend":"local"`.
2. `dispatch "<prompt>"` (no `--backend`) is **byte-identical** to C: no `-p` flag, `"backend":"codex"`.
3. `quick --backend local "<prompt>"` edits in place via the local model (clean-tree / `--snapshot`
   rules from C unchanged) and records the backend.
4. **Preflight:** `--backend local` **refuses** when `l_probe` ≠ `ready`, printing the `local-up`
   command; it proceeds when `ready`.
5. `local-up` runs the configured remote load command and polls to readiness (stubbed in tests);
   `local-down` runs the unload command; both are idempotent/best-effort.
6. `doctor` reports `unreachable | up-not-loaded | ready` for the local endpoint alongside the codex
   version.
7. `--backend bogus` is refused with the valid backend list; unknown backend never reaches codex.
8. `install.sh` writes `$CODEX_HOME/local.config.toml` when absent and **leaves an existing one
   untouched**.
9. All new `tests/*_test.sh` pass via `tests/run.sh`, and **all of C's and A's existing tests still
   pass** (L3 regression guard).

### Testing approach
- Extends C's dependency-free pure-bash harness; sandbox-isolated; **no real network or ssh**.
- `tests/lib.sh` gains: an **argv-capturing fake codex** (records the exact flags it was called with,
  so tests assert `-p local` presence/absence), and **stub `ssh`/probe** bins driven by an env var
  (`FAKE_LOCAL_STATE=unreachable|up-not-loaded|ready`) so `l_probe`/`l_up`/`l_down`/preflight are
  unit-testable deterministically.
- Each acceptance criterion maps to at least one `*_test.sh`.
- **Boundary note** (like A's keychain smoke / C's real-codex smoke): the stubs prove orchestration,
  not real inference. A short **manual smoke checklist** covers the real path on the workstation:
  `local-up` loads the GGUF and reaches `ready`; `dispatch --backend local` produces a real diff via
  the Qwen model; `resume` continues context; `land` merges; `local-down` frees VRAM.

---

## 7. Out of scope
- **Non-codex executors** (aider / opencode / a custom loop) — the A2 executor table. C.1 ships only
  `codex` and `local`, both codex-driven; the resolver leaves room to add one later.
- **Auto-routing by task difficulty** — choosing backend is Claude's judgment (skill), not an engine
  heuristic.
- **Multi-endpoint / multi-model selection, load-balancing, GPU/perf tuning.**
- **SSH tunnels / port-forwarding** — unnecessary on the headscale tailnet (L5).
- **Subsystem B** — later learning of backend-routing heuristics with provenance; C.1 ships a
  hand-curated routing rule only.
- **Subsystem C internals** — C.1 does not modify C's land/verify/abandon/sidecar logic beyond the
  additive `--backend` flag, the `backend` field, and the local preflight.

---

## 8. Risks & mitigations
- **R1 — Codex profile/provider schema drift.** Codex moves fast (0.130→0.135 mid-C). The custom
  `model_providers` + profile surface could change. *Mitigation:* all codex calls remain behind C's
  single `d_codex_*` boundary; the profile is a plain file `doctor` can validate; `wire_api`/`base_url`
  are the only provider fields relied on.
- **R2 — Model id mismatch.** If `CODEX_DISPATCH_LOCAL_MODEL` ≠ the `/v1/models` id, codex errors and
  `l_probe` reports `up-not-loaded`. *Mitigation:* single source of truth via the env knob, written into
  both the profile and the probe; `doctor` surfaces the mismatch.
- **R3 — Tool-call fidelity / empty diff.** A model that can't drive codex's tools yields no changes.
  *Mitigation:* Q6 tool-trained model; C's "no diff / checks fail → failed" makes it loud, not silent.
- **R4 — Context overflow on retry.** Local context is smaller; the resume loop grows it. *Mitigation:*
  routing reserves local for small tasks + low retry budget (skill policy, K3).
- **R5 — Verifier gaming by a weaker model.** *Mitigation:* local defaults to stronger verify/review;
  C's `touches_tests` warning still fires (K4).
- **R6 — VRAM left allocated.** Forgetting `local-down` holds VRAM. *Mitigation:* `local-down` helper +
  `doctor` visibility; non-fatal (no correctness impact).
- **R7 — Full-access blast radius unchanged.** Local dispatch still runs codex
  `--dangerously-bypass-approvals-and-sandbox`; the worktree isolates the tree (C R3). No new posture.

---

## 9. Open micro-decisions (defaulted; revisable)
- **MC1:** local-up readiness poll = every 3 s, timeout 240 s (model load + preset-switch restart can be slow).
- **MC2:** `local-down` with `CODEX_DISPATCH_LOCAL_DOWN_CMD` unset → warn, no-op (don't fail).
- **MC3:** default local `--retry` lives in skill guidance (0), not an engine default — engine keeps
  C's default of 1 regardless of backend.
- **MC4:** profile name default `local`; provider name `llamacpp`.
- **MC5:** `doctor` reports local state but never auto-loads the model (no hidden SSH side effects).

---

## 10. Addendum — workstation reality (post-approval, from `docs/local-docs/`)

Verified against the user's `llama-control.sh` + fleet doc. These refine §5 without changing the L1 seam:

- **Router mode.** `/v1/models` lists the **whole fleet**, each entry carrying `status.value` (`loaded`/unloaded); models auto-load on first request and LRU-evict at `MODELS_MAX`. There is **no unload endpoint**.
- **Readiness correction (was a bug).** `l_probe` MUST check the target alias's `status.value == "loaded"` via `jq` — **not** mere id presence (the id is always listed, loaded or not). Three states: curl fails → `unreachable`; alias loaded → `ready`; otherwise → `up-not-loaded`.
- **Model alias.** Codex `model` = the router alias **`qwen36-35b`** *(pending live verification at `/v1/models`)*, not the GGUF filename. The dedicated `qwen36-only` preset gives it the full 48 GB; it **can't coexist** with other models (OOM → ~27-min retry trap), so it needs that preset.
- **Load path (decision: dedicated preset).** `local-up` switches to the **qwen36-only preset over SSH**, then polls to loaded. Default `LOCAL_UP_CMD = cd ~/docker/llama && sed -i 's/^MODE=.*/MODE=qwen36-only/' .env && docker compose up -d llama-server` (mirrors `llama_preset`). A best-effort HTTP **preload** nudge covers on-demand presets; the poll tolerates the brief restart-window unreachability.
- **Container (decision: always running).** SSH is on the hot path only for the preset switch.
- **Unload (decision: stop container).** Default `LOCAL_DOWN_CMD = cd ~/docker/llama && docker compose stop llama-server` — guaranteed full VRAM free (stops the whole fleet; overridable to `llama_unload` for targeted eviction).
- **R8 — thinking-model tool-call fidelity.** Qwen3.x emit `<think>` reasoning; this *could* interleave with tool calls and break codex's parser. *Mitigation:* the manual smoke check verifies real tool-driven edits; the engine's "empty diff / checks fail" makes a parser breakdown loud, not silent. **Outcome (§11): did NOT bite** — Qwen36-35b drove codex's command_execution tool cleanly with `reasoning_output_tokens: 0` on the smoke task.

---

## 11. First real run — verified findings (2026-06-02)

The fake-codex suite can't catch a codex-version API change; the first real `--backend local`
dispatch surfaced **R1 (codex CLI drift)** as three required corrections, now folded into
`install.sh` / `lib/dispatch.sh`:

1. **`wire_api = "responses"`, not `"chat"`.** Codex **0.135 dropped `wire_api="chat"`** for
   custom providers ("no longer supported"; requires the Responses API). The workstation's
   llama.cpp router build (b9209+) **does serve `POST /v1/responses` (→ 200)**, so the fix is a
   profile flag, not a re-architecture. *(This invalidated the 2026-05-31 "llama.cpp speaks chat
   only" assumption — that older codex builds accepted chat is what made it look safe.)*
2. **No `env_key`.** Codex requires the env var named by `env_key` to **exist** (errored
   `Missing environment variable: LLAMACPP_API_KEY`). Omitting `env_key` makes codex send no auth,
   which the local router accepts. (Setting a dummy `LLAMACPP_API_KEY` also works; omitting is cleaner.)
3. **`codex exec` needs stdin closed (`< /dev/null`).** Headless/non-interactive, codex blocks
   forever on `Reading additional input from stdin...`. Already fixed in `lib/dispatch.sh`
   (`157b8ef`, landed via dogfooding) — critical for autonomous runs.

**End-to-end result:** `dispatch --backend local --verify checks` on a throwaway repo →
Qwen36-35b edited the file via codex's tool, the check passed, dispatch stopped at `needs_review`,
diff was real (`def add(a,b): return a+b`). The C.1 backend is functional on the live workstation.

**Operating note:** the workstation stays powered with models loaded for autonomous runs; the
backend never auto-`local-down`s (only on explicit request).

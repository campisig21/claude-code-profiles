# local-llama profile — local-inference steward (design)

**Date:** 2026-06-02 (rev. 2026-06-03)
**Status:** approved (brainstorming), pending implementation plan
**Profile:** `local-llama` (`~/.claude/profiles/local-llama/`)

## Purpose

Equip the `local-llama` Claude Code profile to understand, operate, and maintain
the user's local inference stack and its relationship to the codex harness. The
profile is the *steward* of local inference: it knows the fleet, picks the right
model for a task, owns the load/select lifecycle, and makes the codex `local`
backend trivially usable from any session.

This is primarily a **knowledge/skill layer** over infrastructure that already
exists and is verified live (see "Verified ground truth"). The codex-side changes
are small and additive (a second profile + two convenience entry points), not a
rewrite.

## Verified ground truth (2026-06-03)

**Workstation** — `greg-campisi@100.64.0.4` over a headscale tailnet:
- 2× RTX 3090 (24 GB each = 48 GB VRAM), NVLink (NV4, ~56 GB/s).
- Docker: `llama-server` (`ghcr.io/ggml-org/llama.cpp:server-cuda`) in **router
  mode** (build b9209+), OpenAI-compatible `/v1` on host port 8080; `open-webui`
  on 3001; a separately-managed `ollama` on 11434 (not in this compose).
- Models: GGUFs in `/models/gguf/`, aliased via preset `.ini` files. Router
  auto-loads on demand and LRU-evicts at `MODELS_MAX`. **No unload endpoint.**
- Presets: `concurrent`, `sequential`, `qwen36-only`. Current `.env`:
  `MODE=qwen36-only`, `MODELS_MAX=1`.
- Live now: `qwen36-35b` **loaded**, `DEFAULT` unloaded; ~19 GB used per card.
- Canonical operator doc: `~/docker/llama/AGENTS.md` (roster table + 10 gotchas);
  helpers in `~/docker/llama/llama-control.sh`.

**Mac (this machine)** — M1 Pro / 16 GB; client + orchestration node only:
- `codex-cli 0.136.0`. `-p <name>` *layers* `$CODEX_HOME/<name>.config.toml` on
  top of base `config.toml` (codex v2 profiles). Today `local` →
  `~/.codex/local.config.toml`: `model = "qwen36-35b"`,
  `model_provider = "llamacpp"`, `base_url = http://100.64.0.4:8080/v1`,
  `wire_api = "responses"`, no auth.
- `profile-system/` provides the codex dispatch engine: `codex_dispatch.sh` with
  `quick` (in-place) and `dispatch` (worktree + Claude-gated land) commands, both
  accepting `--backend codex|local`; `lib/local.sh` (`l_probe`/`l_ready`/`l_up`/
  `l_down`/`l_preload`) manages remote lifecycle over SSH+HTTP. The backend
  resolver `d_backend_args local` emits `-p ${CODEX_DISPATCH_LOCAL_PROFILE:-local}`
  (already env-overridable).
- All headless codex calls go through one wrapper (`d_codex_exec`/`d_codex_resume`)
  using `codex exec --dangerously-bypass-approvals-and-sandbox --json -C <dir> …`.

## The two access types (and how they map to what exists)

Both ride codex against the local model; they differ in *who drives* and in
*harness wrapping* — **not** in the codex profile beyond interactive-vs-headless.

1. **Type-2 — interactive (the user, hands-on):** `codex -p local`. Full TUI,
   human-in-the-loop approval, richer tool/plugin group.
2. **Type-1 — Claude-driven (one-shot / delegated):** an existing capability —
   the same headless `codex exec` the dispatch engine already uses:
   - **in-repo code task:** `codex_dispatch.sh quick --backend local "…"`
     (edits in place, uncommitted) or `dispatch --backend local "…"`
     (isolated worktree + checks + Claude-gated land).
   - **no-repo one-shot inference:** `local-ask "…"` (new thin wrapper).

   *Key realization:* `quick` vs `dispatch` differ only at the harness level
   (in-place vs worktree+lifecycle), making the **identical** codex call. They do
   **not** need separate codex profiles — both use the single Claude-driven
   profile. Adding "local" was just `-p <profile>`.

## Approach

A **focused set of single-purpose skills** (not one mega-skill), each teaching
the *mental model + procedure + gotchas* and **pulling live specifics over
SSH/HTTP at use time** ("thin + pull live"). The workstation `AGENTS.md` +
presets remain canonical; skills cross-reference them and never copy the roster
table (no drift).

## Components

### 1. Profile persona — `CLAUDE.md`
Rewrite the stub to make the identity explicit: steward of the local inference
stack (2×3090/48 GB workstation at `100.64.0.4`, llama.cpp router mode) and its
codex `local` backend. Encode cross-cutting invariants: tailnet endpoint, SSH
target, "`AGENTS.md` is canonical," the two access types, and the dev-process
note (Claude plans, codex implements). Preserve the `@curator/INDEX.md` include.

### 2. Two codex profiles (interactive vs Claude-driven)
Split the conflated single `local` profile into two overlay files. A profile is
a full overlay, so each can independently set plugin/tool group, approval policy,
sandbox mode, and TUI.

| Profile (`-p`) | File | Role | TUI/NUX | Approval/sandbox | Tool/plugin group |
|---|---|---|---|---|---|
| `local` | `~/.codex/local.config.toml` | **interactive** (Type-2) | kept | `on-request` / workspace-write (human in loop) | richer (user's choice) |
| `local-headless` | `~/.codex/local-headless.config.toml` | **Claude-driven** (Type-1: quick, dispatch, local-ask) | stripped | autonomous (`never`; exec also passes `--dangerously-bypass-approvals-and-sandbox`) | lean, task-focused |

Both target the same `model_providers.llamacpp` + `qwen36-35b`. Repoint the
dispatch default: `CODEX_DISPATCH_LOCAL_PROFILE` default `local` → `local-headless`
(env still overrides). Update `install.sh` + tests accordingly.

Startup-prompt differentiation (codex 0.136 has no guaranteed per-profile
system-prompt key): interactive gets a persona via a cwd/`AGENTS.md`; headless
gets a preamble injected by the entry points ("one-shot subagent driven by
another Claude session; concise, machine-usable output; never ask interactive
questions"). If a native per-profile instructions-file knob is confirmed at
implementation time, prefer it.

### 3. Two convenience entry points (the only new code on top of the engine)
- **`--ensure-up` flag** on `quick`/`dispatch` (opt-in): when `--backend local`
  and not ready, run `l_up` first instead of refusing. Default stays
  refuse-and-tell (preserves the "engine is the seatbelt" contract; no surprise
  ~30-90s preset swap + eviction). Reuses `lib/local.sh`; no new lifecycle logic.
- **`local-ask` wrapper** (new, tiny): `bin/local-ask` (+ thin `/local-ask`
  command). Runs `codex -p local-headless exec --skip-git-repo-check` with the
  headless preamble and a readiness preflight (`l_ready || l_up`). For no-repo,
  non-code one-shot delegation from any session.

### 4. Skill set — `profiles/local-llama/skills/`

| Skill | Purpose | Pulls live | Triggers on |
|---|---|---|---|
| `local-fleet-ops` | Operate the running fleet | `/v1/models`, `llama_status`, `llama_vram` | what's loaded / load / swap / restart / VRAM |
| `local-model-selection` | Pick the right model for a task | live roster | which local model for X |
| `local-codex-backend` | Drive codex on local (both types) | `l_probe` readiness | use local with codex / offload to local |
| `local-model-acquisition` | Add/update models from HuggingFace | free VRAM | add model / new GGUF / download from HF |

**`local-fleet-ops`** — router mode, LRU, `MODELS_MAX`, NVLink row-split,
presets; live inspection over SSH; lifecycle (preset switch, preload, the
no-unload reality + LRU-eviction workaround, restart); the **qwen36 fatal-OOM
coexistence trap** (`--tensor-split 1,1` → OOM is fatal not adaptive; give big
models their own `MODELS_MAX=1` preset).

**`local-model-selection`** — roster *roles* (thinking vs no-think, ctx,
fine-tune quirks); the **thinking-template gotcha** (`enable_thinking:false` is
inert on the custom Qwen3.5/Qwopus fine-tunes; `reasoning.effort=none` can worsen
it; use `llama31-8b`/`qwen25-7b` for genuine no-think work); `max_tokens`
budgeting (size to ~100-300 reasoning + content). Pulls the live roster, maps
task→alias.

**`local-codex-backend`** — the spine of the two access types. Interactive
(`codex -p local`); Claude-driven in-repo (`quick`/`dispatch --backend local`,
with `--ensure-up`); no-repo (`local-ask`). Explains quick-vs-dispatch (harness
difference), the readiness model, and local-vs-codex-cloud guidance. Documents
config locations (`~/.codex/local.config.toml`, `~/.codex/local-headless.config.toml`,
`lib/local.sh`, `codex_dispatch.sh`).

**`local-model-acquisition`** — bartowski / unsloth **UD quant** guidance
(UD-Q6_K_XL / UD-Q8_K_XL for accuracy-per-byte), VRAM-budget quant sizing,
download → preset alias block → restart → smoke → update `AGENTS.md`.

### 5. Source-of-truth boundary
- **Canonical (workstation):** roster, presets, gotchas → `~/docker/llama/
  AGENTS.md`, `presets/*.ini`, `llama-control.sh`.
- **Canonical (Mac):** codex wiring → `~/.codex/local.config.toml`,
  `~/.codex/local-headless.config.toml`, `profile-system/lib/local.sh`,
  `codex_dispatch.sh`.
- **Profile skills own:** how-to-think + how-to-pull + cross-references. Each
  skill ends with a "Source of truth" footer pointing at the canonical file.

## Out of scope (YAGNI)
- No new MCP server.
- No embedded roster snapshots in skills.
- No changes to the workstation Docker setup.
- No Hermes-routing changes (cross-reference only).
- No new `local-exec` subsystem — superseded by existing `quick`/`dispatch
  --backend local` + `--ensure-up` + `local-ask`.
- No rewrite of the dispatch engine — only additive flag/wrapper/profile + repoint.

## Implementation split
- **Claude writes directly:** the 4 skill markdown files, the `CLAUDE.md`
  persona, the headless preamble text, and the two codex profile overlays (config
  + interactive `AGENTS.md` persona).
- **codex implements (via `/codex-implement`):** the `--ensure-up` flag, the
  `local-ask` wrapper (+ command), the `CODEX_DISPATCH_LOCAL_PROFILE` default
  repoint, and `install.sh`/test updates — honoring the profile dev process.

## Success criteria
- From a fresh `local-llama` session, the four skills trigger on their intents
  and produce accurate, live-data-backed guidance.
- `codex -p local` gives an interactive local session; `quick --backend local`
  and `dispatch --backend local` use the autonomous `local-headless` profile.
- `quick/dispatch --backend local --ensure-up` loads the model when needed; the
  default still refuses with a clear "run local-up" message.
- `local-ask "<question>"` runs a no-repo one-shot on the local model from any
  session, ensuring readiness first.
- A new model can be added end-to-end via `local-model-acquisition`.
- No roster/gotcha content is duplicated from the workstation `AGENTS.md`.

## Spec / artifact locations
- This spec: `profile-system/docs/specs/2026-06-02-local-llama-profile-design.md`.
- Skills: `~/.claude/profiles/local-llama/skills/<skill>/SKILL.md`.
- Persona: `~/.claude/profiles/local-llama/CLAUDE.md`.
- Codex profiles: `~/.codex/local.config.toml`, `~/.codex/local-headless.config.toml`.
- New code: `profile-system/bin/local-ask` (+ command); `--ensure-up` in
  `codex_dispatch.sh`; default repoint in `lib/dispatch.sh`/`install.sh`.

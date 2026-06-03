# local-llama profile — local-inference steward (design)

**Date:** 2026-06-02
**Status:** approved (brainstorming), pending implementation plan
**Profile:** `local-llama` (`~/.claude/profiles/local-llama/`)

## Purpose

Equip the `local-llama` Claude Code profile to understand, operate, and maintain
the user's local inference stack and its relationship to the codex harness. The
profile is the *steward* of local inference: it knows the fleet, picks the right
model for a task, owns the load/select lifecycle, and makes the codex `local`
backend trivially usable from any session.

This is a **knowledge/skill layer** over infrastructure that already exists and
is verified live (see "Verified ground truth"). The only new *code* is one small
ergonomic wrapper (`local-exec`).

## Verified ground truth (2026-06-02)

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
- `codex-cli 0.136.0`. `codex -p local` loads `~/.codex/local.config.toml`:
  `model = "qwen36-35b"`, `model_provider = "llamacpp"`,
  `base_url = http://100.64.0.4:8080/v1`, `wire_api = "responses"`, no auth.
- `profile-system/` provides the codex dispatch engine: `codex_dispatch.sh`
  (`--backend codex|local`) and `lib/local.sh` (`l_probe`/`l_ready`/`l_up`/
  `l_down`/`l_preload`) — remote lifecycle over SSH+HTTP.
- `codex -p local exec "…"` works today (model is loaded).

## The two access types (converge on one mechanism)

Both ride the codex `local` profile:
1. **Type-1 — called from other Claude sessions:** one-shot delegation of a
   cheap subtask via `codex -p local exec "<task>"`.
2. **Type-2 — interactive local:** the user drives codex against the local model
   interactively (`codex -p local`), with codex tools/skills available.

The only difference is interactive vs. one-shot; the wiring is identical.

## Approach

A **focused set of single-purpose skills** (not one mega-skill). Each skill
teaches the *mental model + procedure + gotchas* and **pulls live specifics over
SSH/HTTP at use time** ("thin + pull live"). The workstation `AGENTS.md` +
presets remain canonical; skills cross-reference them and never copy the roster
table (no drift). Rejected: a single monolithic skill (weak triggering, becomes
a drift magnet).

## Components

### 1. Profile persona — `CLAUDE.md`
Rewrite the stub to make the identity explicit: steward of the local inference
stack (2×3090/48 GB workstation at `100.64.0.4`, llama.cpp router mode) and its
codex `local` backend. Encode the cross-cutting invariants: tailnet endpoint,
SSH target, "`AGENTS.md` is canonical," and the dev-process note (Claude plans,
codex implements). Preserve the existing `@curator/INDEX.md` include.

### 2. Skill set — `profiles/local-llama/skills/`

| Skill | Purpose | Pulls live | Triggers on |
|---|---|---|---|
| `local-fleet-ops` | Operate the running fleet | `/v1/models`, `llama_status`, `llama_vram` | what's loaded / load / swap / restart / VRAM |
| `local-model-selection` | Pick the right model for a task | live roster | which local model for X |
| `local-codex-backend` | Drive codex on local (both types) | `l_probe` readiness | use local with codex / offload to local |
| `local-model-acquisition` | Add/update models from HuggingFace | free VRAM | add model / new GGUF / download from HF |

**`local-fleet-ops`** — mental model (router mode, LRU, `MODELS_MAX`, NVLink
row-split, presets); live inspection over SSH; lifecycle (preset switch,
preload, the no-unload reality + LRU-eviction workaround, restart); the
**qwen36 fatal-OOM coexistence trap** (`--tensor-split 1,1` makes OOM fatal, not
adaptive — give big models their own `MODELS_MAX=1` preset rather than relying on
eviction).

**`local-model-selection`** — roster *roles* (thinking vs no-think, ctx,
fine-tune quirks); the **thinking-template gotcha** (`enable_thinking:false` is
inert on the custom Qwen3.5/Qwopus fine-tunes; `reasoning.effort=none` can make
it worse; use `llama31-8b`/`qwen25-7b` for genuine no-think work); `max_tokens`
budgeting (reasoning eats budget — size to ~100-300 reasoning + content). Pulls
the live roster and maps task→alias.

**`local-codex-backend`** — both access types. Interactive (`codex -p local`),
one-shot (`codex -p local exec "…"`), the readiness preflight, and
`codex_dispatch.sh --backend local` for verified worktree dispatch. Documents
config locations (`~/.codex/local.config.toml`, `lib/local.sh`). Guidance on
local vs. codex-cloud.

**`local-model-acquisition`** — bartowski / unsloth **UD quant** guidance
(UD-Q6_K_XL / UD-Q8_K_XL for accuracy-per-byte), VRAM-budget quant sizing,
download → preset alias block → restart → smoke → update `AGENTS.md`.

### 3. Type-1 ergonomics — `local-exec` wrapper (the only new code)
A raw `codex -p local exec` against an unloaded/wrong-preset workstation hits the
OOM trap or an unreachable container. A tiny wrapper closes the gap:

```
local-exec "<task>"   ≈   l_ready || l_up;  codex -p local exec "<task>"
```

- Implemented as a `bin/` script (and a thin `/local-exec` command) that reuses
  `lib/local.sh` (`l_ready`/`l_up`) — **no new lifecycle logic**.
- Ensures readiness (container up + `qwen36-only` loaded) then runs the one-shot.
- The `local-codex-backend` skill teaches both the raw command (when known-ready)
  and the wrapper (safe default).

### 4. Source-of-truth boundary
- **Canonical (workstation):** roster, presets, gotchas → `~/docker/llama/
  AGENTS.md`, `presets/*.ini`, `llama-control.sh`.
- **Canonical (Mac):** codex wiring → `~/.codex/local.config.toml`,
  `profile-system/lib/local.sh`, `codex_dispatch.sh`.
- **Profile skills own:** how-to-think + how-to-pull + cross-references. Each
  skill ends with a "Source of truth" footer pointing at the canonical file, so
  maintenance is single-source.

## Out of scope (YAGNI)
- No new MCP server.
- No embedded roster snapshots in skills.
- No changes to the workstation Docker setup.
- No Hermes-routing changes (cross-reference only).
- No rewrite of `codex_dispatch.sh` — only the `local-exec` wrapper on top.

## Implementation split
- **Claude writes directly:** the 4 skill markdown files + the `CLAUDE.md`
  persona (prose/knowledge is the point of this profile).
- **codex implements (via `/codex-implement`):** the `local-exec` wrapper script
  + its test, honoring the profile dev process.

## Success criteria
- From a fresh `local-llama` session, the four skills trigger on their intents
  and produce accurate, live-data-backed guidance.
- `local-exec "<task>"` runs a one-shot codex job on the local model from any
  session, ensuring readiness first.
- A new model can be added end-to-end by following `local-model-acquisition`.
- No roster/gotcha content is duplicated from the workstation `AGENTS.md`;
  skills pull or cross-reference it.

## Spec / artifact locations
- This spec: `profile-system/docs/specs/2026-06-02-local-llama-profile-design.md`.
- Skills: `~/.claude/profiles/local-llama/skills/<skill>/SKILL.md`.
- Persona: `~/.claude/profiles/local-llama/CLAUDE.md`.
- Wrapper: `profile-system/bin/local-exec` (+ command).

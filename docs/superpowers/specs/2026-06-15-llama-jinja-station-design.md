# `llama-jinja` Station Server — Design

**Goal:** Stand up a new, self-contained docker stack on the station
(`greg-campisi-station` / `100.64.0.4`) that serves **qwen36-35b** from a single
plain `llama-server` exposing **both** the OpenAI (`/v1/chat/completions`) and
native Anthropic (`/v1/messages`) APIs on port 8080 — so Claude Code / `claude -p`
drive the local model **with no LiteLLM proxy**, while codex and any OpenAI client
keep working unchanged. Daily model is qwen36-35b; occasional swap to another
model is a one-command, few-second restart.

**Non-goals:** Multi-model live routing (LRU). Touching or migrating the existing
`~/docker/llama/` stack. A managed proxy daemon. Browser UI (open-webui) in the
new stack.

**Architecture (one sentence):** A single `llama-server` container (jinja
default-on serves both APIs at once), parameterized by one `LLAMA_ARGS` env var
sourced from a per-model registry file, controlled by a small `llama-control.sh`.

---

## Background / Why

- The station currently runs llama.cpp in **router mode** on `:8080`
  (`~/docker/llama/docker-compose.yaml`, `--models-preset … --models-max …`).
  Router mode is experimental, requires an on-demand worker-spawn that OOM'd and
  wedged on 2026-06-15, and **does not expose `/v1/messages`** (probed: HTTP 000).
- Claude Code speaks only the Anthropic Messages API. To drive the local model we
  had been running a LiteLLM Anthropic→OpenAI proxy. That proxy is a moving part
  we can delete.
- **Verified empirically (2026-06-15, image build b9209):** a plain (non-router)
  `llama-server` with `--jinja` (default-on in b9209) serves `/v1/chat/completions`
  **and** `/v1/messages` simultaneously from one process/port. The Anthropic probe
  returned a proper `{type:message, content:[…], stop_reason, usage}` payload,
  including native `thinking` blocks for the reasoning model.

This design replaces the proxy + router (for the daily path) with one server that
natively speaks both APIs.

---

## Component 1 — Directory layout (current stack untouched)

New dir `~/docker/llama-jinja/`, fully independent of `~/docker/llama/`:

```
~/docker/llama-jinja/
  docker-compose.yaml      # one service: llama-jinja
  .env                     # active selection — holds LLAMA_ARGS + LLAMA_IMAGE (git-ignored / generated)
  models/                  # registry: one file per model
    qwen36-35b.env
    qwopus-27b.env
    qwen-9b.env
  llama-control.sh         # use | up | down | restart | status | logs | models | upgrade
  README.md                # usage + old<->new switch + verification
```

The existing `~/docker/llama/` is **never edited**. Both share GPUs and port 8080,
so exactly one runs at a time. Container name `llama-jinja` (distinct from the old
`llama-server`) guarantees no name collision even if both are accidentally up.

## Component 2 — `docker-compose.yaml`

```yaml
services:
  llama-jinja:
    image: ${LLAMA_IMAGE}                 # pinned digest, e.g. ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:c4d2aaf10abd…
    container_name: llama-jinja
    restart: unless-stopped
    ports: ["8080:8080"]
    volumes: ["/models/gguf:/models:ro"]
    env_file: .env                        # provides LLAMA_ARGS (+ LLAMA_IMAGE via interpolation)
    entrypoint: ["/bin/sh", "-c"]
    command: ['exec /app/llama-server --host 0.0.0.0 --port 8080 $LLAMA_ARGS']
    healthcheck:
      test: ["CMD", "sh", "-c", "curl -fsS http://localhost:8080/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 180s                  # 35B cold-load headroom
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

**Why `sh -c … $LLAMA_ARGS`:** a single env var carries a variable-length arg list
that the container's shell word-splits at runtime — no YAML list splatting and no
dependence on which `LLAMA_ARG_*` env mappings exist in a given build. `exec`
keeps llama-server as PID 1 (clean signals/shutdown). The healthcheck curls the
**actual** serving port (8080) — explicitly avoiding the `maestro-qwen36`
false-`unhealthy` bug (its check curled in-container `:8080` while it served `:8095`).

**Implementation notes (compose/env gotchas — get these right in the plan):**
- `.env` does **double duty**: it is compose's default interpolation source (so
  `${LLAMA_IMAGE}` resolves at parse time) **and** is injected into the container
  via `env_file:` (so `$LLAMA_ARGS` exists at runtime). Same file, two roles.
- Write the command as `$$LLAMA_ARGS` (escaped) in the compose YAML so **the
  container shell expands it at runtime**, not compose at parse time — predictable
  quoting/word-splitting. (`$$` → literal `$` after compose interpolation.)
- `LLAMA_ARGS` must be a **single physical line** in the `.env`/`models/*.env`
  files — docker's env-file parser has no backslash line-continuation. (It is shown
  wrapped with `\` below for readability only; the real file is one line.)
- Pin the **full** digest in `LLAMA_IMAGE` (the verified b9209 is
  `sha256:c4d2aaf10abd9130d77d117be10dee86699fd5daa4550e9385733ba173ccc334`); the
  `…` truncations elsewhere in this doc are for readability.

## Component 3 — Model registry (`models/*.env`)

Each model is one file setting a complete `LLAMA_ARGS`. `qwen36-35b.env` carries
over the tuned flags from the old `qwen36-only.ini` plus the maestro MTP experiment:

```sh
# models/qwen36-35b.env
LLAMA_IMAGE='ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:c4d2aaf10abd…'
LLAMA_ARGS='--model /models/Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf --alias qwen36-35b \
  -ngl -1 --ctx-size 262144 --cache-type-k q8_0 --cache-type-v q8_0 \
  --flash-attn on --split-mode row --tensor-split 1,1 \
  --spec-type draft-mtp --spec-draft-n-max 2 --slots'
```

Other entries (`qwopus-27b.env`, `qwen-9b.env`, …) follow the same shape with
their own model path / ctx / quant. `LLAMA_IMAGE` lives in the registry too so a
model can pin a different image if ever needed (default: same verified digest).

## Component 4 — `llama-control.sh`

Mirrors the existing control script's style. Commands:

- `use <alias>` — `cp models/<alias>.env .env` then `docker compose up -d`
  (recreates the container with the new model; ~few-second reload). Errors if the
  alias has no registry file.
- `up` / `down` / `restart` — compose lifecycle for the current `.env`.
- `status` — `docker compose ps` + a live readiness line: curl `/v1/models` and a
  1-token `/v1/messages` probe (so "loaded" is never trusted blindly — the
  wedged-instance lesson).
- `logs` — `docker compose logs -f llama-jinja`.
- `models` — list registry aliases (the `models/*.env` basenames) + which is active.
- `upgrade` — `docker pull ghcr.io/ggml-org/llama.cpp:server-cuda`, print the new
  digest, remind the operator to run the verification probes, then (on confirm)
  rewrite `LLAMA_IMAGE` in the active registry file(s) to the new digest. Makes
  upgrades deliberate, not accidental.

## Data flow

```
codex (local-headless)  ─┐
open-webui / OpenAI客户端 ─┼─►  POST :8080/v1/chat/completions  ─►  llama-server (qwen36-35b)
Claude Code / claude -p  ─┘     POST :8080/v1/messages         ─►  (same process, jinja)
```

No proxy in any path. `claude -p` env: `ANTHROPIC_BASE_URL=http://100.64.0.4:8080`,
`ANTHROPIC_MODEL=qwen36-35b`, `ANTHROPIC_AUTH_TOKEN=dummy` (Claude Code requires a
non-empty token; the server ignores it).

## Error handling / operational concerns

- **One-at-a-time enforcement:** bringing the new stack up while the old is up will
  fail fast on the `:8080` port bind (and/or VRAM) — an explicit, loud failure, not
  a silent wedge. README documents the switch order (old `down` → new `up`).
- **Cold-load:** 35B load is covered by `start_period: 180s`; `status`/`logs`
  surface progress. First `/v1/messages` after `up` may take seconds.
- **VRAM:** single model owns all 48 GB (same regime as `qwen36-only.ini`); no
  second copy can contend (that was today's root cause).
- **Reasoning blocks:** qwen emits `thinking`; the Anthropic endpoint returns them
  as `thinking` content blocks (Claude Code handles these). Keep
  `--reasoning-format` at default (matches today's working codex behavior); revisit
  only if a consumer mis-parses.
- **Rollback:** new `down`, old `up` — the old stack is byte-for-byte unchanged.

## Testing / verification (acceptance)

Run after `llama-control.sh use qwen36-35b && up`:

1. `curl :8080/v1/chat/completions` (1 short message) → **HTTP 200**, OpenAI JSON.
2. `curl :8080/v1/messages` (Anthropic headers) → **HTTP 200**, `{type:message,…}`.
3. `llama-control.sh status` → readiness line green (both probes pass).
4. **Proxy-free `claude -p` smoke:** with **no LiteLLM running**, point `claude -p`
   at `:8080` (env above) on a trivial task in a scratch dir → exit 0, sane output.
5. `llama-control.sh models` lists the registry; `use <other>` swaps and the same
   probes pass for that model (validates the swap path).

## Out of scope / follow-ups

- Retiring the LiteLLM proxy from the ergonomic-wrapper plan (the wrapper's
  decision #2 "drop the proxy" is now answered: yes, native — the wrapper points
  `claude -p` straight at `:8080`).
- Whether the old `~/docker/llama/` router stack is eventually deleted or kept as a
  multi-model fallback — operator's call later; this design just stops depending on it.

---

## Appendix A — Task→model registry roster (research-derived, 2026-06-15)

> **Status of this appendix: additive only.** The base stack (Components 1–4) is being
> implemented as written and ships `models/qwen36-35b.env` as the daily driver. The
> entries below are *additional* `models/*.env` files to drop into the same registry
> once the base is up — they exercise the existing `use <alias>` swap path and change
> nothing in Components 1–4. Derived from a deep-research pass over current HuggingFace
> GGUF availability (see auto-memory `station-model-roster`). Quant/VRAM figures are
> **weights-only**; re-verify live on HF before download (this landscape moves weekly).

**Lane → model → fit (within 48 GB, weights-only):**

| Lane / dispatch | Alias | Model | Arch | Quant | Notes |
|---|---|---|---|---|---|
| Agentic coding (`claude -p`, codex `--backend local`) | `qwen3-coder-30b` | Qwen3-Coder-30B-A3B-Instruct | MoE 30.5B / 3.3B-act | Q6_K ~25 GB | tool-calling needs build ≥ PR #16932 |
| Reasoning / planning | `glm-z1-32b` | GLM-Z1-32B-0414 | dense 32B | UD-Q4_K_XL ~20 GB | reasoning only, **not** tool-loops; max-ctx unconfirmed |
| Utility — judge / dedup verdicts | `qwen3-judge-4b` | Qwen3-4B-Instruct-2507 | dense 4B | Q8_0 ~5 GB | single-GPU; verdict-quality utility |
| Utility — classify / throughput | `qwen3-0.6b` | Qwen3-0.6B | dense 0.6B | Q8_0 ~0.8 GB | single-GPU + `--parallel`; drive with `/no_think` |
| General / daily *(base — already Component 3)* | `qwen36-35b` | Qwen3.6-35B-A3B | MoE 35B / ~3B-act | Q6_K_XL | unchanged |

`LLAMA_ARGS` is shown wrapped with `\` for readability; the **real file is one physical
line** (docker's env parser has no line-continuation — same rule as Component 3).

### A.1 `models/qwen3-coder-30b.env`
```sh
# Agentic-coding lane — "Qwen3-Coder-Flash". Drives claude -p (/v1/messages) AND codex --backend local (/v1/chat/completions).
# REQUIRES a llama.cpp image whose build includes PR #16932 (XML tool-call parser, merged 2025-11-18) + the *corrected* unsloth quants.
# If the verified base digest (b9209) predates 2025-11-18, run `llama-control.sh upgrade` BEFORE first use of this alias.
LLAMA_IMAGE='ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:<digest from a build ≥ 2025-11-18>'
LLAMA_ARGS='--model /models/Qwen3-Coder-30B-A3B-Instruct-UD-Q6_K_XL.gguf --alias qwen3-coder-30b \
  -ngl -1 --ctx-size 262144 --cache-type-k q8_0 --cache-type-v q8_0 \
  --flash-attn on --split-mode row --tensor-split 1,1 \
  --jinja --reasoning-format auto --slots'
```

### A.2 `models/glm-z1-32b.env`
```sh
# Reasoning / planning lane — dense 32B, deep chain-of-thought. Reserve for planning; do NOT point an agentic tool-loop at it.
# ctx-size held at 128K: GLM-Z1's true llama.cpp max context is unconfirmed (the "8K-native + YaRN-to-32K" claim was REFUTED in research) — check /props before raising.
# Q4_K_XL keeps weights ~20 GB so 128K KV cache fits; move to Q6_K only if you shorten context.
LLAMA_IMAGE='ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:c4d2aaf10abd…'
LLAMA_ARGS='--model /models/GLM-Z1-32B-0414-UD-Q4_K_XL.gguf --alias glm-z1-32b \
  -ngl -1 --ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 \
  --flash-attn on --split-mode row --tensor-split 1,1 \
  --jinja --reasoning-format auto --slots'
# Alt for known-context reasoning: DeepSeek-R1-Distill-Qwen-32B (Qwen2.5-32B base). Same dense-32B fit; also reasoning-only (R1 tool-calling is unstable).
```

### A.3 `models/qwen3-judge-4b.env`
```sh
# Utility lane (verdict quality) — bake-off judge, dedup adjudication, classification needing nuance.
# tensor-split omitted on purpose: a 4B fits one GPU; row-splitting it only adds inter-GPU latency for no capacity gain.
LLAMA_IMAGE='ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:c4d2aaf10abd…'
LLAMA_ARGS='--model /models/Qwen3-4B-Instruct-2507-Q8_0.gguf --alias qwen3-judge-4b \
  -ngl -1 --ctx-size 32768 --flash-attn on --jinja --slots'
```

### A.4 `models/qwen3-0.6b.env`
```sh
# Utility lane (throughput) — high-volume classification / dedup pre-filter where latency beats peak quality.
# Single GPU + 8 parallel slots for batching; drive with `/no_think` (or enable_thinking=false) to skip reasoning for speed.
LLAMA_IMAGE='ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:c4d2aaf10abd…'
LLAMA_ARGS='--model /models/Qwen3-0.6B-Q8_0.gguf --alias qwen3-0.6b \
  -ngl -1 --ctx-size 16384 --flash-attn on --parallel 8 --jinja --slots'
```

### A.5 Operational prerequisites (validate before trusting any lane)
1. **Image freshness (coding lane):** `qwen3-coder-30b` tool-calling needs a build ≥ PR #16932
   (2025-11-18) **plus** the corrected/re-uploaded unsloth quants. Confirm `chat_template_tool_use`
   is present at `:8080/props`.
2. **OpenAI-compat arg bug (#20198):** some builds serialize tool arguments as a JSON *object*, not a
   *string*. Verify one real tool call round-trips through **both** drivers (`claude -p` and codex
   local) before relying on the lane.
3. **`--reasoning-format auto`** is set on the coding/reasoning lanes per research (separates
   `reasoning_content` so the tool call survives). This *diverges* from the base's "keep default"
   guidance (§ Error handling) — if a consumer mis-parses, revert to default for that alias.
4. **KV-at-256K is weights-plus-cache:** the "fits" figures are weights-only. Keep the dense-32B
   reasoning lane at Q4_K_M/Q6_K if long context must be resident simultaneously.
5. **Generational check:** the daily model is Qwen3.**6** but the verified coder pick is Qwen**3**
   (Jul 2025). Check live HF for a `Qwen3.6-Coder` GGUF; if it ships with corrected quants, prefer it
   for the `qwen3-coder-30b` slot.

### A.6 Open questions — settle in the bake-off (subsystem E), not via web research
- Measured tool-call success rate of `qwen3-coder-30b` under each driver.
- Does codex-local double-execution (the `codex-local-dedup-guard` quirk) persist with Qwen3-Coder,
  or was it qwen36-specific?
- `qwen3-0.6b` vs `qwen3-judge-4b` as judge — quality vs latency.
- **Devstral-Small** (dense ~24B agentic coder) as a Qwen3-Coder challenger — unverified in research,
  an ideal extra bake-off contestant (dense models often tool-call more steadily than MoE).

### A.7 Coding-lane bake-off contenders (candidates — verify before committing)

> Added 2026-06-16 from live search (snippet-level; confirm primary cards + mainline
> llama.cpp support before download). These are **not** drop-in roster slots like A.1–A.4 —
> each carries an open compatibility/fit question the bake-off (subsystem E) must settle.
> The committed coding slot stays `qwen3-coder-30b` (Flash, A.1) until one of these wins.

#### A.7.1 `models/qwen3-coder-next.env` — stronger on paper, TIGHT 48 GB fit
```sh
# Qwen3-Coder-Next — 80B-A3B on the Qwen3-Next hybrid (Gated-DeltaNet linear-attn + MoE) arch. Non-thinking; ~Claude-Sonnet-4.5 on coding; 256K native.
# FIT IS TIGHT: ~40–45 GB of weights at Q4 on a 48 GB box. Use a ~Q3–Q4 quant and EXPECT reduced context (256K KV will NOT fit alongside Q4 weights).
# VERIFY FIRST (any can be a hard blocker): (a) mainline llama.cpp supports the Qwen3-Next hybrid/linear-attention arch; (b) the tool-call parser covers Qwen3-Coder-Next's format; (c) --flash-attn behaves with linear attention.
LLAMA_IMAGE='ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:<recent build — Qwen3-Next-aware>'
LLAMA_ARGS='--model /models/Qwen3-Coder-Next-UD-Q3_K_XL.gguf --alias qwen3-coder-next \
  -ngl -1 --ctx-size 65536 --cache-type-k q8_0 --cache-type-v q8_0 \
  --flash-attn on --split-mode row --tensor-split 1,1 \
  --jinja --reasoning-format auto --slots'
# If weights+KV overflow VRAM: smaller quant first, then shorten --ctx-size. If still tight, it just doesn't fit VRAM-only on 48 GB (the GLM-4.6 outcome, milder) → keep Flash.
```

#### A.7.2 `models/gemma4-26b-a4b.env` — MoE + native tool-use + vision
```sh
# Gemma 4 26B-A4B — MoE (4B active), native structured tool-use, reasoning, 256K ctx, and VISION (only vision-capable option in the roster). Official QAT-q4 GGUF ≈ 15 GB → comfortable 48 GB fit.
# VERIFY FIRST: llama.cpp tool-call parser coverage for Gemma 4's function-call format (PR #16932 covers Qwen3/GLM/etc., NOT necessarily Gemma 4) — confirm tool calls round-trip under both drivers before trusting the agentic lane.
LLAMA_IMAGE='ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:<recent build — Gemma-4-aware>'
LLAMA_ARGS='--model /models/gemma-4-26B-A4B-it-qat-Q4_0.gguf --alias gemma4-26b-a4b \
  -ngl -1 --ctx-size 262144 --cache-type-k q8_0 --cache-type-v q8_0 \
  --flash-attn on --split-mode row --tensor-split 1,1 \
  --jinja --reasoning-format auto --slots'
# Vision is OFF unless the multimodal projector is loaded. To enable image input, add:  --mmproj /models/gemma-4-26B-A4B-mmproj.gguf
```

#### A.7.3 Three-way (or four-way) coding bake-off
Settle the committed coding slot empirically (subsystem E), judged first on tool-call
round-trip reliability under both drivers (`claude -p`, codex local), then code quality:
- `qwen3-coder-30b` (Flash) — comfortable fit, proven baseline.
- `qwen3-coder-next` — strongest on paper; open question is usable-context-at-fit (A.7.1).
- `gemma4-26b-a4b` — MoE speed + vision; open question is tool-call parser coverage (A.7.2).
- *(optional 4th)* `devstral-small` — dense ~24B, per A.6.

---

## Appendix B — Model switching: `use <alias>` now, routing later

> **Status: decided (2026-06-16).** `llama-control.sh use <alias>` is the **primary
> switching mechanism** for now — manual, deliberate, zero added processes,
> `/v1/messages` guaranteed. Automatic request-driven routing (llama-swap / router mode)
> is a **documented future evolution**, not in the current build. The "multi-model live
> routing = non-goal" line (see Non-goals) stands; this appendix just records the path
> *if* that ever changes.

### B.1 The working set — what `use` actually rotates between

Day-to-day, switching is **three models, one resident at a time**:

| `use <alias>` | Model | Lane |
|---|---|---|
| `qwen36-35b` | Qwen3.6-35B-A3B | daily / general — the default (Component 3) |
| `qwen3-coder-30b` | Qwen3-Coder-30B-A3B-Instruct | agentic coding — `claude -p`, codex local (A.1) |
| `glm-z1-32b` | GLM-Z1-32B-0414 | reasoning / planning (A.2) |

Mechanism: `use <alias>` → `cp models/<alias>.env .env` → `docker compose up -d` (recreate)
→ ~few-second reload. One model owns all 48 GB at a time; the `:8080` bind enforces
single-occupancy. The tiny utility models (A.3/A.4) are **not** in this rotation — see B.3.

### B.2 Why `use` is the right primary driver (not routing, for now)
- **Zero moving parts** — the deleted LiteLLM proxy stays deleted; nothing new to wedge.
- **`/v1/messages` is guaranteed** — it's a plain `--jinja` server, not a router coordinator
  (router mode is what probed HTTP 000 on the Anthropic endpoint).
- **Matches reality** — a session knows which model it needs; you swap deliberately, not per-request.

**"Ensure `use` works" = acceptance:** after `use <alias>` for **each** of the three aliases,
run testing probes 1–3 (OpenAI 200, Anthropic 200, `status` green). All three passing the
swap path *is* the done-bar for this phase.

### B.3 Future evolution — request-driven routing (when/if wanted)
If the pattern ever shifts from "one model per session" to "mixed traffic that should
auto-route," the path is:

| Option | Switch trigger | `/v1/messages`? | Note |
|---|---|---|---|
| **llama-swap** (preferred) | request `model` name; starts/stops backends | ✓ Anthropic-aware (verify passthrough) | external Go binary; YAML can be generated from `models/*.env` |
| llama.cpp router mode | request `model`; LRU + `--models-max 1` | ⚠️ re-probe — was HTTP 000 | in-process, no extra binary, but the Anthropic endpoint is the open question |

**Hybrid sweet spot (the actual target if we evolve):** the utility models are tiny
(0.6B ~0.8 GB, 4B ~5 GB). A ~25 GB big model + both utility models ≈ 31 GB < 48 GB — so
keep the **utility lane resident permanently and swap only the big slot** (the B.1 three).
The judge/classifier stays available while the big model works; cold-load latency is paid
only on big-model changes. llama-swap expresses this as a concurrency group; router mode as
`--models-max 2` with the small model pinned.

### B.4 Gate before adopting ANY routing layer
Run acceptance probe #2 (Anthropic-headers `curl /v1/messages` → HTTP 200) **through the
switching layer**, not against a bare server. llama-swap almost certainly passes; router
mode must be re-verified (prior probe: HTTP 000). If the layer can't serve `/v1/messages`,
it is a non-starter for `claude -p` — no exceptions.

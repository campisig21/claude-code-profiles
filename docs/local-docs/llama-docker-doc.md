# Local llama.cpp Model Fleet

Multi-model llama.cpp server in router mode, fronting several GGUFs over an
OpenAI-compatible API at `http://localhost:8080/v1`. Models load on demand
and evict via LRU at `MODELS_MAX` capacity.

For context (architecture, gotchas, fine-tune quirks, hermes routing):
see [`AGENTS.md`](./AGENTS.md).

## Files

| File | Purpose |
|---|---|
| `docker-compose.yaml` | Service definitions, GPU passthrough, server flags |
| `presets/concurrent.ini` | Multi-model preset (default; LRU evicts at cap) |
| `presets/sequential.ini` | One-at-a-time preset (full VRAM per model) |
| `.env` | `MODE` (preset selector) and `MODELS_MAX` (LRU cap) |
| `llama-control.sh` | Shell helper functions (source from `.bashrc`) |
| `AGENTS.md` | Operator notes and learned-the-hard-way gotchas |

## Quick setup

```bash
# Source helpers (add to ~/.bashrc to persist)
source ~/docker/llama/llama-control.sh
```

After sourcing, all `llama_*` functions are available in your shell.

## Lifecycle

```bash
llama_up          # docker compose up -d
llama_stop        # stop container
llama_restart     # restart container (only true way to evict everything)
llama_pull        # docker compose pull && up -d (refresh :server-cuda image)
llama_logs [n]    # tail -f last N lines (default 50)
```

Raw equivalents:
```bash
cd ~/docker/llama
docker compose up -d llama-server
docker compose restart llama-server
docker compose logs -f llama-server
```

## Inspection

```bash
llama_status      # all models + loaded/unloaded status
llama_loaded      # just the loaded ones
llama_vram        # per-GPU memory used/free
```

Raw equivalents:
```bash
curl -s http://localhost:8080/v1/models | python3 -m json.tool
curl -s http://localhost:8080/health
curl -s http://localhost:8080/props        # router config: max_instances, autoload
nvidia-smi --query-gpu=memory.used,memory.free --format=csv
```

## Per-model control

```bash
llama_preload <alias>          # load into memory (one-token request)
llama_ping <alias> [prompt]    # smoke test with reasoning-safe max_tokens
llama_unload <alias>           # best-effort LRU eviction (see caveats below)
```

Raw inference call:
```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwopus-27b",
       "messages":[{"role":"user","content":"ping"}],
       "max_tokens":400}'   # ≥200 for thinking models; see gotcha #3 in AGENTS.md
```

## LRU eviction model — the unload story

Router mode (build b9209+, marked experimental) has **no unload endpoint**.
No `POST /unload`, no `DELETE /model`, no CLI flag. The router auto-loads
models on first request and evicts the least-recently-used model when
`MODELS_MAX` is reached.

`llama_unload <alias>` works around this by:
1. Touching every *other* currently-loaded model (cheap 1-token request)
   to push the target into LRU position.
2. Loading an unloaded model from the preset to force an eviction at the
   `MODELS_MAX` cap.

**Caveats:**
- Only works when `MODELS_MAX` is already reached. Below cap, loading another
  model doesn't evict anything.
- Requires at least one unloaded model in the preset to use as evictor.
- If neither holds, the only honest path is `llama_restart`.

To shrink the cap instead (kills everything, restarts with fewer hot):
```bash
sed -i 's/^MODELS_MAX=.*/MODELS_MAX=1/' ~/docker/llama/.env
llama_up
```

## Switching presets

```bash
llama_preset                  # list available presets
llama_preset concurrent       # multi-model with LRU eviction
llama_preset sequential       # one-at-a-time, full VRAM per model
llama_preset qwen36-only      # dedicated qwen36-35b, full 48 GB to itself
```

Each preset has different `ctx-size` budgets and `load-on-startup` choices
— see the `.ini` files.

## Changing MODELS_MAX (LRU cap)

```bash
llama_models_max 1            # single-model mode
llama_models_max 3            # standard concurrent cap
```

Both `llama_preset` and `llama_models_max` rewrite `.env` and restart the
container. The container only reads env vars at startup, so a restart is
mandatory.

**Trap:** `MODELS_MAX` is *just an LRU cap*, not a pre-eviction trigger.
When you try to load the (cap+1)th model, the router tries to *add* it
first, and only evicts if that succeeds. With `--tensor-split 1,1` set
(disabling auto-fit), an OOM at this point is **fatal, not adaptive** —
the load fails and the router retries for ~27 minutes before giving up.
If you have one model that can't coexist with the others, give it its
own preset with `MODELS_MAX=1` (see `qwen36-only.ini`) instead of relying
on eviction.

## Adding a new model

Workflow per [`AGENTS.md`](./AGENTS.md):

1. Download GGUF to `/models/gguf/` with `curl -L` (bartowski / unsloth preferred).
2. Add `[alias]` block to `presets/concurrent.ini`:
   ```ini
   [your-alias]
   model = /models/your-file.gguf
   ctx-size = 16384
   load-on-startup = true       ; or omit for on-demand
   ```
3. `llama_restart`
4. `llama_ping your-alias` to verify
5. Update the model lineup table in `AGENTS.md`.

## Server-level flags worth knowing

Set in `docker-compose.yaml` `command:` block (global, applies to all models):

| Flag | Current value | Effect |
|---|---|---|
| `--models-preset` | `/presets/${MODE}.ini` | Which preset to load |
| `--models-max` | `${MODELS_MAX:-3}` | LRU cap |
| `--split-mode` | `row` | Row-sharding across GPUs; exploits NVLink |
| `--tensor-split` | `1,1` | Equal split between the two 3090s |
| `--slots` | (flag set) | Expose `/slots` endpoint for diagnostics |

Per-model `[DEFAULT]` flags in each preset `.ini`:

| Flag | Value | Effect |
|---|---|---|
| `n-gpu-layers` | `-1` | Offload all layers to GPU |
| `flash-attn` | `on` | Always enable FlashAttention |

## Known limits

- Router mode is **experimental** (the server prints this on startup).
  Behavior around manual lifecycle may change in future builds.
- No way to unload without either LRU eviction or a restart.
- `--split-mode` is server-wide; cannot be set per-model.
- See `AGENTS.md` "Known gotchas" for thinking-model and template quirks.

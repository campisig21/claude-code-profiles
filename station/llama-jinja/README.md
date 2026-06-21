# llama-jinja

One `llama-server` (jinja default-on) serving **both** OpenAI `/v1/chat/completions`
and native Anthropic `/v1/messages` on `:8080`. Single model at a time; **qwen3-coder-30b**
is the default driver (agentic coding via `claude -p` / codex); swap with `use <alias>`.
Replaces the LiteLLM proxy and router mode for daily use.

Lives alongside the original `~/docker/llama/` (router) stack — **only one may run
at a time** (they share port 8080 and the GPUs).

## Switch from the old stack to this one
```bash
cd ~/docker/llama && docker compose down        # stop the router stack
cd ~/docker/llama-jinja && ./llama-control.sh use qwen3-coder-30b
./llama-control.sh status                        # wait for READY (200/200)
```

## Rollback to the old stack
```bash
cd ~/docker/llama-jinja && ./llama-control.sh down
cd ~/docker/llama && docker compose up -d
```

## Working set

Day-to-day, `use` rotates between three aliases (one resident at a time):

| alias | model | lane |
|---|---|---|
| `qwen3-coder-30b` | Qwen3-Coder-30B-A3B-Instruct | agentic coding (`claude -p`, codex) — **default** |
| `qwen36-35b` | Qwen3.6-35B-A3B | general chat / daily fallback |
| `glm-z1-32b` | GLM-Z1-32B-0414 | reasoning / planning |
| `qwen35-4b` | Qwen3.5-4B | utility — judge / dedup verdicts |
| `qwen3-0.6b` | Qwen3-0.6B | utility — fast classification |

(`qwopus-27b`, `qwen-9b` are example registry entries, not part of the working set.)

## Swap models
```bash
./llama-control.sh models             # list registry aliases (active marked *)
./llama-control.sh use qwen3-coder-30b  # cp models/qwen3-coder-30b.env .env + force-recreate
./llama-control.sh status             # wait for READY (200/200)
```

## Clients
- **codex / OpenAI:** `http://100.64.0.4:8080/v1` (unchanged).
- **Claude Code / `claude -p`:** drive via `bin/claude-run` — it owns the full
  env contract (incl. `ANTHROPIC_SMALL_FAST_MODEL`, which a hand-typed recipe
  omits). See [ADR-0004](../../docs/decisions/0004-claude-local-dispatch-transport.md).

## Add a model
Create `models/<alias>.env` with `# alias: <alias>`, `LLAMA_IMAGE=...`, and a
single-line `LLAMA_ARGS=...` (must include `--model /models/<file>.gguf` and
`--alias <alias>`). Then `./llama-control.sh use <alias>`.

`LLAMA_ARGS` is word-split by the container shell — use plain space-separated
flags, **no quotes or shell-special characters** (`;`, `|`, `$`, globs, spaces in paths).

## Upgrade the image (deliberate)
```bash
./llama-control.sh upgrade   # pulls :server-cuda, shows digest, re-pins after you confirm
```
Pinned to a digest so upstream tag bumps never change behavior silently.

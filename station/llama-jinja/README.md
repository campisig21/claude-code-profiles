# llama-jinja

One `llama-server` (jinja default-on) serving **both** OpenAI `/v1/chat/completions`
and native Anthropic `/v1/messages` on `:8080`. Single model at a time; qwen36-35b
is the daily driver. Replaces the LiteLLM proxy and router mode for daily use.

Lives alongside the original `~/docker/llama/` (router) stack — **only one may run
at a time** (they share port 8080 and the GPUs).

## Switch from the old stack to this one
```bash
cd ~/docker/llama && docker compose down        # stop the router stack
cd ~/docker/llama-jinja && ./llama-control.sh use qwen36-35b
./llama-control.sh status                        # wait for READY (200/200)
```

## Rollback to the old stack
```bash
cd ~/docker/llama-jinja && ./llama-control.sh down
cd ~/docker/llama && docker compose up -d
```

## Swap models
```bash
./llama-control.sh models           # list registry aliases
./llama-control.sh use qwopus-27b   # cp models/qwopus-27b.env .env + force-recreate
./llama-control.sh status
```

## Clients
- **codex / OpenAI:** `http://100.64.0.4:8080/v1` (unchanged).
- **Claude Code / `claude -p`:** no proxy —
  `ANTHROPIC_BASE_URL=http://100.64.0.4:8080`, `ANTHROPIC_MODEL=<alias>`,
  `ANTHROPIC_AUTH_TOKEN=dummy`.

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

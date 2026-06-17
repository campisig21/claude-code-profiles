# llama-jinja-utility

Always-on **resident** utility server: one small model (`qwen3-0.6b`) kept loaded in
VRAM on `:8090`, independent of the swappable `~/docker/llama-jinja` stack (`:8080`).

**Why a separate stack:** the main stack's `llama-control.sh use <alias>` force-recreates
its container on every model swap. Keeping the utility model in its *own* stack means
those swaps never cold-load it — it stays available for classification/judging *while*
any big model is loaded (the resident-small + swap-big hybrid, design Appendix B.3).

- Endpoint: `http://100.64.0.4:8090` — OpenAI `/v1/chat/completions` + Anthropic `/v1/messages` (jinja).
- Model: `qwen3-0.6b` (`Qwen3-0.6B-UD-Q8_K_XL`, ~1GB VRAM on GPU0).
- Shares the 2 GPUs with the main stack; reserves ~1GB so the big slot keeps ~47GB.

## Lifecycle
```bash
cd ~/docker/llama-jinja-utility
docker compose up -d                 # start (always-on; restart: unless-stopped)
docker compose ps                    # health
curl -s localhost:8090/v1/models     # confirm serving qwen3-0.6b
docker compose down                  # stop
```

Pinned to the same llama.cpp digest as the main stack. If you `llama-control.sh upgrade`
the main stack, bump the digest here too.

## Adding the judge (qwen35-4b)
The 0.6b classifier loads near-instantly, so residency mostly buys *concurrency*. The 4B
judge (~5.6GB) is the bigger cold-load win and the better always-available verdict model —
add it as a second service on `:8091` (same shape, `--model /models/Qwen3.5-4B-UD-Q8_K_XL.gguf
--alias qwen35-4b`) if you want the judge resident too. Combined VRAM ~6.4GB.

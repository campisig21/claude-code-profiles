# ADR-0003: Default local dispatch model is qwen3-coder-30b

- **Status:** Accepted
- **Date:** 2026-06-20
- **Canonical source:** `station/llama-jinja/` active `.env` (the `use`d alias);
  working-set table in `station/llama-jinja/README.md`.
- **Supersedes / Superseded by:** supersedes the earlier `qwen36-35b` default.

## Context

The agentic-coding lane is the point of the local roster. `qwen3-coder-30b`
(Qwen3-Coder-30B-A3B-Instruct, UD-Q6_K_XL) is purpose-built for tool-using
loops. An earlier blocker — HTTP 400 "Unable to generate parser for this
template" on the Anthropic path — was root-caused (2026-06-17) to a broken chat
template baked into an *old* GGUF; the re-downloaded quant carries the fixed
template and generates the tool parser (`peg-native`) for every request shape.
Validated end-to-end on GPU: a `claude -p` tool loop read an unguessable secret
from a file via the coder.

## Decision

`qwen3-coder-30b` is the **default** resident model on `:8080`. `qwen36-35b`
remains a `use`-swap fallback for general chat; `glm-z1-32b` for reasoning. A
`claude-run` / dispatch cell may override per-dispatch with `--model`.

## Consequences

- `claude-run` and dispatch default to the coder unless overridden (see
  [ADR-0004](0004-claude-local-dispatch-transport.md)).
- The container is `restart: unless-stopped`, so the `.env` alias persists across
  reboots — the default survives without re-`use`.

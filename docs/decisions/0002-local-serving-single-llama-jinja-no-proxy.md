# ADR-0002: Local model serving is one llama-jinja server, no proxy

- **Status:** Accepted
- **Date:** 2026-06-15
- **Canonical source:** `station/llama-jinja/` (compose + `llama-control.sh`);
  operational notes in the `llama-jinja-station` auto-memory.
- **Supersedes / Superseded by:** supersedes the LiteLLM-proxy recipe previously
  documented for the Claude harness (now a fallback only).

## Context

Claude Code speaks the Anthropic `/v1/messages` protocol; the original station
served only OpenAI `/v1`, so driving `claude -p` against a local model needed a
LiteLLM proxy translating Anthropic→OpenAI (Python 3.11 venv, wildcard model
map). That was an extra moving part with its own failure modes.

## Decision

The canonical local serving path is a **single** `llama-server` run with
`--jinja` (image pinned to llama.cpp b9209 `c4d2aaf…`) that serves **both**
OpenAI `/v1/chat/completions` and native Anthropic `/v1/messages` on `:8080`
from one process. The LiteLLM proxy is **retired** — kept only as a documented
fallback if the jinja stack is down. One model is resident at a time; swap with
`llama-control.sh use <alias>`.

## Consequences

- `claude -p` and `codex` both point straight at `:8080` with no proxy.
- The env contract for the Claude harness is owned by the forthcoming
  `bin/claude-run` (see [ADR-0004](0004-claude-local-dispatch-transport.md)),
  not by prose.
- The old OpenAI-only router stack (`~/docker/llama/`) returns HTTP 000 on
  `/v1/messages` and cannot serve Claude; it remains only as a multi-model
  fallback.

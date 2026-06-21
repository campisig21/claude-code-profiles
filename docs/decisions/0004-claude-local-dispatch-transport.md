# ADR-0004: claude-on-station as a first-class dispatch transport

- **Status:** Proposed
- **Date:** 2026-06-21
- **Canonical source (forthcoming):** `bin/claude-run` + `lib/claude-local.sh`;
  design spec `docs/superpowers/specs/2026-06-21-claude-local-transport-design.md`.
- **Supersedes / Superseded by:** none (extends the dispatch stack of
  [ADR-0002](0002-local-serving-single-llama-jinja-no-proxy.md) /
  [ADR-0003](0003-default-local-dispatch-model.md)).

## Context

`claude -p` (Claude Code's own harness) drives the station's native Anthropic
endpoint with working tool loops — proven for both `qwen36-35b` and, as of
ADR-0003, `qwen3-coder-30b`. This is the third dispatch *delegate transport*
alongside codex (`codex-run`) and in-session Claude-direct, but it is currently
**uncodified**: it lives only in prose, the env recipe drifted (ADR-0001), and
the required `ANTHROPIC_SMALL_FAST_MODEL` knob appears in none of the copies.

A native Agent-tool subagent cannot *be* qwen — it inherits the Anthropic-tier
session endpoint — so qwen work must run in a shelled `claude -p` process.

## Decision (proposed — detail in the spec)

1. A `claude-run` primitive owns the env contract — `ANTHROPIC_BASE_URL`,
   `ANTHROPIC_MODEL` (default qwen3-coder-30b, ADR-0003), and
   `ANTHROPIC_SMALL_FAST_MODEL` — as the **single executable source of truth**.
   Prose links to it instead of restating it.
2. It exposes a reachability `doctor` (expects 200/200 on both endpoints) and a
   `--stream` passthrough (`claude -p --output-format stream-json`).
3. Local-qwen dispatch **surfaces as a two-layer cell**: an Agent-tool subagent
   (the visible, `/agents`-style activity) shells `claude-run` and narrates a
   stream-json digest of the qwen worker's steps. The two layers are forced by
   the constraint above, not incidental.
4. **Gated on a streaming spike** proving the digest surfaces incrementally
   before the surfacing contract is frozen.

## Consequences

- Phase A builds the primitive + doctor + spike + tests; Phase B adds the cell
  lifecycle (worktree → scoped commit → sidecar) and a bake-off contestant,
  reusing Phase A's exec core.
- The env recipe's six prose copies (ADR-0001) get trimmed to links/pointers at
  `bin/claude-run`.
- This ADR moves to `Accepted` when the spec is approved. If the spike forces a
  different surfacing mechanism, a superseding ADR records the change.

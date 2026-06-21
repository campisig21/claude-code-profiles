# ADR-0001: Record architecture decisions as ADRs

- **Status:** Accepted
- **Date:** 2026-06-21
- **Canonical source:** `docs/decisions/` (this directory)
- **Supersedes / Superseded by:** none

## Context

Operational facts in this repo drifted because they were restated in many
places. Concrete example (2026-06-21 audit): the `claude -p` → station env
recipe appeared in **six** locations — `station/llama-jinja/README.md`, three
auto-memory files, a dated spec, and a dated plan — and **none** of them
included the `ANTHROPIC_SMALL_FAST_MODEL` knob that is actually required. The
copies also disagreed on the default model (`qwen36-35b` vs `qwen3-coder-30b`).
There was no canonical place to look, so each new doc copied a stale neighbour.

## Decision

Adopt lightweight ADRs under `docs/decisions/`, governed by the four rules in
the [index README](README.md): one decision per ADR, link don't copy, contracts
live in code, append-and-supersede.

## Consequences

- New specs reference ADRs instead of re-inlining facts.
- Prose that currently duplicates a contract gets trimmed to a link (tracked as
  the de-dup task in the claude-local transport work, [ADR-0004](0004-claude-local-dispatch-transport.md)).
- A small upkeep cost: a changed decision needs a new superseding ADR, not an
  in-place edit. That cost is the point — it preserves the *why*.

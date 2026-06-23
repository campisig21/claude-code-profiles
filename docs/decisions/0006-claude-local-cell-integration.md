# ADR-0006: Non-codex dispatch delegates integrate via their own wrapper, not the frozen seam

- **Status:** Proposed
- **Date:** 2026-06-22
- **Canonical source (forthcoming):** `bin/claude-run` `cell` mode +
  `lib/claude-local.sh`; design spec
  `docs/superpowers/specs/2026-06-22-claude-local-cell-design.md`.
- **Supersedes / Superseded by:** none (extends
  [ADR-0004](0004-claude-local-dispatch-transport.md); applies the dispatch-stack
  frozen-seam rule of the subsystem-E design).

## Context

The dispatch cell lifecycle (begin → delegate → verify → record → land) lives in
the delegate-agnostic library `lib/dispatch-lib.sh`; codex integration lives in
the **frozen** adapter `lib/dispatch.sh` — the single codex call site, kept stable
so the codex contract can't drift. `tests/dispatch_lib_extraction_test.sh` proves
`lib/dispatch-lib.sh` is sourceable standalone (`has_codex=no`).

Phase B (ADR-0004) makes `claude-local` a first-class dispatch delegate: it must
run a qwen worker inside a `dispatch begin`-returned worktree, commit, and update
the sidecar, exactly as `codex-run` does. The question is *where that code lives* —
a new `dispatch claude-run` verb inside the frozen codex adapter, or an
integration that reaches the lifecycle from outside it.

## Decision

Non-codex delegate transports integrate via their **own executable** that sources
`lib/dispatch-lib.sh` (+ `lib/jsonutil.sh`) and reuses its public functions
(`d_sc_get`, `d_commit_worktree`, `d_sc_set`, …) — **never** by adding code to the
frozen codex adapter `lib/dispatch.sh`. Concretely, `claude-local` integrates as
**`bin/claude-run cell <id>`**. The seam-extraction test guarantees this is
possible; it becomes a regression guard for the boundary.

## Consequences

- `lib/dispatch.sh` stays the codex-only adapter; the library stays
  delegate-agnostic. Future non-codex transports follow the same pattern (own
  wrapper + `dispatch-lib.sh` reuse).
- `claude-local` commits via the shared `d_commit_worktree` (`git add -A`), uniform
  with `codex-run`; the cell never authors a `.gitignore` (breaks `land --ff-only`).
- The `cell` worker step needs a non-`exec` run path (`claude_local_run`) so control
  returns for the commit/sidecar steps — see the spec.
- Flips to `Accepted` when Phase B is implemented and its tests pass.

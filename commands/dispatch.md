---
description: Run a single dispatch at a (backend, model) worker via a native Agent cell — compose, delegate to codex (gpt/qwen) or implement Claude directly, verify, report; you (the orchestrator) land
argument-hint: [--model <model>] [--backend codex|ollama] [--verify mode] [--check 'cmd'] "<task>"
allowed-tools: Bash, Read, Agent, Task
---

Spawn a **dispatch cell** (driven by the dispatch skill) to carry out the user's task
on a `(backend, model)` worker, then review its verdict and land.

Task: `$ARGUMENTS`

- Default worker is `(codex, gpt-5.5)`. Parse `--model`/`--backend`/`--verify`/`--check`
  from `$ARGUMENTS` to override; the rest is the task description.
- Spawn the cell with the `Agent` tool (default `run_in_background: true`). The cell
  follows the dispatch skill: `begin` → compose → `codex-run -m <model>` (or implement
  a Claude model directly) → `verify` once → `record` → return a structured verdict.
  Drive the CLI at `~/.claude/profile-system/bin/dispatch`.
- When the cell returns: if its verify mode includes review, run `dispatch show <id> --diff`
  and actually review the diff (watch for weakened/deleted tests). Then take exactly one of
  `dispatch land <id>` / re-dispatch with feedback / `dispatch abandon <id>`. **Only the
  orchestrator lands** — the cell never does.
- Never run raw git/codex yourself; always go through the `dispatch` CLI.

> Supersedes `/codex-implement`, which remains as a back-compat alias driving the
> `harness=codex` autonomous loop (`codex_dispatch.sh`) for in-flight work (E8).

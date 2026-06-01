---
description: Dispatch a change to codex (isolated, verified, Claude-gated) or --quick in place
argument-hint: [--quick] [--verify mode] [--check 'cmd'] "<task>"
allowed-tools: Bash, Read
---

Invoke the `codex-implement` skill and drive `~/.claude/profile-system/codex_dispatch.sh`
to implement the user's task with codex.

Arguments: `$ARGUMENTS`

- If `$ARGUMENTS` starts with `--quick`, use the engine's `quick` path (in-place, no worktree)
  — for trivial edits. Otherwise use the full isolated `dispatch` flow (worktree + verify +
  Claude-gated land).
- Choose `--verify`/`--retry` and the `--check` commands per the skill's decision table and
  the task's impact. Always read the result and the `ALLOWED NEXT ACTIONS` block, review the
  diff when the verify mode includes review, then land / resume / abandon.
- Never run raw git/codex yourself; always go through the engine.

# Subsystem C — manual smoke checklist

The test suite uses a **fake `codex`**, so it proves the engine's *orchestration*,
not real codex behavior. Run this once against the REAL `codex` in a throwaway git
repo to cover what can't be unit-tested.

Engine: `~/.claude/profile-system/codex_dispatch.sh`

- [ ] In a scratch repo with a real test command, run:
      `~/.claude/profile-system/codex_dispatch.sh dispatch --verify checks --check '<real test cmd>' "<small real task>"`
      → a worktree is created, real `codex exec` runs (full-access), the check runs,
        and it stops at `needs_review` printing a **diffstat** (not the full diff) and
        an `ALLOWED NEXT ACTIONS` block.
- [ ] `codex_dispatch.sh show <id> --diff` shows codex's real diff on demand.
- [ ] Force a failing check (a task you know fails once) with `--retry 1` and confirm a
      real `codex exec resume` continues the SAME session and fixes it (status →
      `needs_review`, `retries_used` → 1).
- [ ] `codex_dispatch.sh land <id>` rebases onto HEAD, merges into the working branch,
      removes the worktree. Verify the change is in your working tree.
- [ ] Make a conflicting commit on the working branch, then `land` another dispatch and
      confirm it **aborts cleanly** (worktree retained, status stays `needs_review`).
- [ ] `codex_dispatch.sh quick "<trivial task>"` edits the working tree in place and shows
      the diff (including any new files); `--quick` on a dirty tree refuses without
      `--snapshot`, and `--snapshot` records a restore point.
- [ ] `codex_dispatch.sh list` shows active dispatches; `codex_dispatch.sh doctor` reports
      the real codex version and reconciles a hand-deleted worktree to `lost`.
- [ ] **Activation:** after `bash ~/.claude/profile-system/install.sh`, the `codex-implement`
      skill and `/codex-implement` command resolve inside an active profile session, and
      the engine path the skill references is reachable.

## Notes
- Full-access posture (`--dangerously-bypass-approvals-and-sandbox`, decision C5): the
  worktree isolates the working *tree*, not the machine. Run the smoke test somewhere you're
  comfortable letting codex execute freely.
- If the `--json` session-id capture ever breaks on a codex upgrade, resume still works via
  the cwd-scoped `codex exec resume --last` fallback (spec R4). `doctor` surfaces the version.

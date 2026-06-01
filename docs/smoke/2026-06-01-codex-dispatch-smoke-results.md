# Codex dispatch smoke — results (2026-06-01)

Ran `docs/smoke/2026-05-31-codex-dispatch-smoke.md` against **real codex-cli 0.135.0**
in a throwaway `/tmp` git repo (Python+pytest). All 8 items pass functionally.

| # | Item | Result |
|---|------|--------|
| 1 | `dispatch --verify checks` | ✓ worktree + real `codex exec`, check passed, `needs_review` w/ diffstat + next-actions |
| 2 | `show <id> --diff` | ✓ real diff on demand |
| 3 | forced fail + `--retry 1` resume | ✓ `retries_used → 1`, resume-fix commit, `needs_review` |
| 4 | `land <id>` | ✓ rebase→ff-merge→worktree removed, change in working tree |
| 5 | conflicting commit then `land` | ✓ aborts cleanly (exit 1), worktree retained, stays `needs_review` |
| 6 | `quick` / dirty-refusal / `--snapshot` | ✓ in-place diff incl. new files; refuses dirty w/o snapshot; snapshot ref recorded |
| 7 | `list` / `doctor` | ✓ list ok; doctor reports `0.135.0` + reconciles deleted worktree to `lost` |
| 8 | activation after `install.sh` | ◑ skill + engine path ok; `/codex-implement` command not wired (finding 2) |

## Findings

**1. `--json` session-id capture broken on codex 0.135.**
Stream now emits `{"type":"thread.started","thread_id":"019e…"}` — no `session_id` key.
`lib/dispatch.sh:d_codex_session_id` greps `"session_id":"…"` → returns empty → sidecar
`session_id=null` → resume always uses the `codex exec resume --last` fallback (spec R4).
Retry/resume still works; explicit-id path is dormant.
**Fix:** also match `"thread_id"` in `d_codex_session_id`; confirm `resume <id>` accepts a thread_id.

**2. `install.sh` doesn't install the `/codex-implement` command.**
Step 4 hardcodes only `profile.md` into `$ROOT/commands/` (loops skills, not commands).
The `codex-implement` *skill* resolves and `/codex-implement` works via it, but
`commands/codex-implement.md` is never symlinked into `~/.claude/commands/`.
**Fix:** loop over `$SHARED/commands/*.md` like the skills loop.

## Resolution (2026-06-01)

Both findings fixed with regression coverage (suite: 20/20):
- **1.** `lib/dispatch.sh:d_codex_session_id` now matches `"session_id"` *or*
  `"thread_id"` (codex 0.135+). New assertion in `tests/dispatch_lib_test.sh`.
- **2.** `install.sh` step 4 now loops `$SHARED/commands/*.md` instead of hardcoding
  `profile.md`, so `/codex-implement` is symlinked into the default profile. New
  assertion in `tests/install_test.sh`.

## Notes
- Item 3 used a toggling check (fail first invocation, real pytest on retry) to make the
  single failure deterministic against a capable real codex.
- `install.sh` left one expected `settings.json.bak.*` backup.

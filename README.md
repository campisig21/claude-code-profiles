# profile-system

Hermes-style **profiles** + (later) **self-improvement learning** for Claude Code,
preserving the Claude-plans / codex-implements dev process.

## Subsystems
- **A — Profile layer** (this) — `CLAUDE_CONFIG_DIR`-per-profile, `ccp` launcher,
  SessionStart wakeup, `/profile` management, default-profile adoption.
- **B — Self-improvement learning** (planned) — launchd daemon + headless Sonnet curation.
- **C — Codex dev-process dispatch** (planned) — auto-select exec/resume + worktree + verify.

## Install
```bash
bash ~/.claude/profile-system/install.sh
# ensure ~/.local/bin is on PATH
```
Installation is additive and non-destructive: your existing `~/.claude/settings.json`
is backed up to `settings.json.bak.<timestamp>` and only added to (existing plugins,
hooks, and keys are preserved). `~/.claude` itself becomes the structured **default**
profile.

## Use
```bash
ccp                     # default profile (~/.claude)
ccp work                # launch the 'work' profile
/profile create work    # interview + create a new profile (inside a session)
/profile list|show|status|doctor|archive|switch|provision
```

## Test
```bash
bash tests/run.sh
```

## Notes
- The repo is expected to live at `~/.claude/profile-system`. Hooks are registered in
  `settings.json` by absolute path through `profiles/_shared`, so **moving the repo**
  after install requires re-running `install.sh` and removing any stale hook entries
  that point at the old path (the installer dedups by exact path, so a moved repo
  produces a new entry rather than replacing the old one).
- Run `/profile doctor` to validate and self-heal a profile's shared symlinks.

See `docs/specs/2026-05-28-profile-layer-design.md` for the full design and
`docs/plans/2026-05-28-profile-layer.md` for the implementation plan.

# Subsystem B — manual smoke checklist

The suite uses a **fake `claude`**, proving orchestration, not real Sonnet curation
quality or real launchd timing. Run this once against the REAL `claude -p` and launchd.

- [ ] `bin/learn-flag --type auto --title … --body …` → a candidate appears in
      `<active profile>/curator/inbox/`.
- [ ] `bin/curator run default` with the real `claude` (`CURATOR_CLAUDE_BIN` unset) →
      drains the inbox, files a real skill or memory, regenerates `curator/INDEX.md`,
      writes a `notifications/` entry, bumps `.curator_state`.
- [ ] Start a new session → the `CURATOR UPDATE` block lists what changed; the entry
      moves to `notifications/shown/`; `@curator/INDEX.md` shows the new skill.
- [ ] Dispatch + `land` a codex task → a `codex_run` candidate lands in the inbox; next
      curator run bumps `skill-stats.json` for any skill codex used and may mine a
      `new_skill_candidate` (tagged `source_backend` for local runs).
- [ ] Force a prune: set a learned skill's `runs_since_used` past 100 in `skill-stats.json`,
      run → it is **archived** (not deleted) under `curator/archive/`, with a notification.
- [ ] `bin/curator restore <name>` locates the archived artifact.
- [ ] `launchctl load ~/Library/LaunchAgents/com.profile-system.curator.plist` → after the
      interval (or `launchctl start com.profile-system.curator`), a run happens unattended.
- [ ] `bin/curator pause` → a run is skipped; `resume` re-enables.

## Notes
- The daemon only writes agent-created artifacts (skills/, projects/*/memory/, curator/);
  confirm `CLAUDE.md`, `settings.json`, and the persona are untouched after a run.
- Backend asymmetry: a `--backend local` dispatch's non-use of a skill must NOT advance its
  `runs_since_used`; verify on a local-backed run.

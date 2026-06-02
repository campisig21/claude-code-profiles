---
name: curator
description: Inspect and control the background learning curator — status, recent decisions, skill usage stats, pending notifications, restore archived artifacts, pause/resume, or force a run.
---

# /curator — operator surface for subsystem B

Run the curator CLI:

```bash
~/.claude/profile-system/bin/curator <subcommand> [profile]
```

Subcommands:
- `status [profile]` — last run, pending candidates, paused state, metrics
- `log [-n N]` — recent run log lines
- `stats` — per-skill usage table (prune candidates have times_triggered 0 and high runs_since_used)
- `pending` — notifications not yet surfaced at a session start
- `restore <name>` — locate an archived skill/memory to recover
- `pause` | `resume [profile]` — toggle curation
- `run [profile]` — force a foreground curation run now

Profile defaults to `default` when omitted.

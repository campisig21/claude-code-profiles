# profile-system

Hermes-style **profiles** + (later) **self-improvement learning** for Claude Code,
preserving the Claude-plans / codex-implements dev process.

## Subsystems
- **A — Profile layer** (this) — `CLAUDE_CONFIG_DIR`-per-profile, `ccp` launcher,
  SessionStart wakeup, `/profile` management, default-profile adoption.
- **B — Self-improvement learning** (planned) — periodic curator daemon (launchd
  on macOS / systemd user timer on Linux) + headless Sonnet curation.
- **C — Codex dev-process dispatch** (planned) — auto-select exec/resume + worktree + verify.

## Install

One auto-detecting entry point works on both **macOS** and **Linux**:

```bash
bash install.sh
# ensure ~/.local/bin is on PATH
```

Installation is additive and non-destructive: your existing `settings.json`
is backed up to `settings.json.bak.<timestamp>` and only added to (existing plugins,
hooks, and keys are preserved). `~/.claude` itself becomes the structured **default**
profile.

The cross-platform core (symlinks, hooks, `ccp`, codex config) lives in
`lib/install-common.sh`; the background-curator daemon (subsystem B) is the only
OS-specific part and is dispatched by `uname`:

| OS    | Daemon module          | Installs                                  | Enable with                                             |
|-------|------------------------|-------------------------------------------|---------------------------------------------------------|
| macOS | `lib/daemon-macos.sh`  | launchd agent → `~/Library/LaunchAgents`  | `launchctl load <plist>`                                |
| Linux | `lib/daemon-linux.sh`  | systemd **user** service + timer → `~/.config/systemd/user` | `systemctl --user enable --now profile-system-curator.timer` |

Both modules **write the unit but do not auto-enable it** — you opt in with the
printed command. On a headless Linux box also run `loginctl enable-linger "$USER"`
so the timer fires without an active login session.

### Prereqs
- `bash`, `jq` (the `settings.json` helpers), `python3` (the curator), `git`.
- `~/.local/bin` on `PATH` (the installer links `ccp` there).

### Env knobs
- `PS_OS=macos|linux` — force the daemon path (auto-detected otherwise; useful
  for WSL/containers/CI).
- `CCP_SKIP_PATH=1` — skip the `ccp` PATH symlink.
- `CODEX_DISPATCH_LOCAL_ENDPOINT=http://localhost:8080/v1` — point the codex
  local-model provider at this host (defaults to a Tailscale IP).
- `CURATOR_INTERVAL_SECONDS` (default `1800`), and the sandbox overrides
  `LAUNCH_AGENTS_DIR` / `SYSTEMD_USER_DIR` used by the tests.

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

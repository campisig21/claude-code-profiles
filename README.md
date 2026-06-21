# claude-code-profiles

**Hermes-style profiles, background self-improvement, and codex dev-process
dispatch for [Claude Code](https://docs.claude.com/en/docs/claude-code) — while
preserving a strict Claude-plans / codex-implements workflow.**

One machine, many isolated Claude Code configs. Switch between a work persona, a
side-project persona, and a throwaway sandbox the way you'd switch shells — each
with its own `CLAUDE.md`, skills, memory, and learned behavior. A background
curator quietly turns what you learn in a session into durable skills and
memories. And a codex dispatch layer lets Claude plan while codex implements in
an isolated, verified, Claude-gated worktree.

Runs on **macOS** (launchd) and **Linux** (systemd) from a single
auto-detecting installer.

---

## Why

Claude Code keeps all its state in one `~/.claude`. That's fine until you want
a clean identity per context — different instructions, different skills,
different memory, no cross-contamination. This project adds a **profile layer**
on top of Claude Code's native `CLAUDE_CONFIG_DIR`, plus two optional
subsystems that build on it.

```
ccp            ->  default profile   (~/.claude)
ccp work       ->  work profile      (~/.claude/profiles/work)
ccp vpn        ->  vpn profile       (~/.claude/profiles/vpn)
```

Each profile is a full, independent Claude Code config directory. Your existing
`~/.claude` is adopted **in place** as the `default` profile — nothing is moved
or destroyed.

---

## Subsystems

| | Subsystem | What it gives you |
|---|---|---|
| **A** | **Profile layer** | `CLAUDE_CONFIG_DIR`-per-profile, the `ccp` launcher, a SessionStart wakeup hook, `/profile` management, and additive default-profile adoption. |
| **B** | **Self-improvement learning** | A periodic curator daemon (launchd / systemd) running headless Claude that promotes session learnings into skills and memories. Drive it with the `learn` skill and the `/curator` operator surface. |
| **C** | **Codex dev-process dispatch** | `/codex-implement` — hand an approved change to codex in an isolated git worktree, auto-verify it, and land it only on Claude's approval. Optional local-model backend (Ollama or llama.cpp). |

Subsystem A is the foundation; B and C are independently useful on top of it.

---

## Architecture decisions

Architectural decisions live in [`docs/decisions/`](docs/decisions/) as ADRs —
the single source of truth, kept drift-free by a *link-don't-copy* rule
(contracts live in code; ADRs point at them). Start with the
[index](docs/decisions/README.md).

---

## Install

One auto-detecting entry point works on both macOS and Linux:

```bash
git clone git@github.com:campisig21/claude-code-profiles.git ~/.claude/profile-system
bash ~/.claude/profile-system/install.sh
# ensure ~/.local/bin is on PATH
```

Installation is **additive and non-destructive**: your existing `settings.json`
is backed up to `settings.json.bak.<timestamp>` and only added to (existing
plugins, hooks, and keys are preserved). `~/.claude` becomes the structured
`default` profile.

The cross-platform core (symlinks, hooks, `ccp`, codex config) lives in
`lib/install-common.sh`. The background-curator daemon is the only OS-specific
part, dispatched by `uname`:

| OS    | Daemon module         | Installs                                                    | Enable with                                                  |
|-------|-----------------------|------------------------------------------------------------|--------------------------------------------------------------|
| macOS | `lib/daemon-macos.sh` | launchd agent → `~/Library/LaunchAgents`                   | `launchctl load <plist>`                                     |
| Linux | `lib/daemon-linux.sh` | systemd **user** service + timer → `~/.config/systemd/user` | `systemctl --user enable --now profile-system-curator.timer` |

Both modules **write the unit but do not auto-enable it** — you opt in with the
printed command. On a headless Linux box also run `loginctl enable-linger
"$USER"` so the timer fires without an active login session.

### Prereqs
- `bash`, `jq` (the `settings.json` helpers), `python3` (the curator), `git`.
- `~/.local/bin` on `PATH` (the installer links `ccp` and `local-ask` there).
- For subsystem C: `codex` CLI. For the optional local backend: [Ollama](https://ollama.com)
  (default) or a reachable llama.cpp OpenAI-compatible endpoint (advanced).

### Local LLM (optional)
A bare `install.sh` writes **no** codex/local-model config. Opt in explicitly:

```bash
bash install.sh --with-local              # auto: Ollama if installed, else llama.cpp
bash install.sh --with-local=ollama       # codex --oss --local-provider ollama (default model qwen2.5-coder)
bash install.sh --with-local=llamacpp     # custom provider for a llama.cpp endpoint (advanced)
```

- **Ollama** is the portable default — runs locally on `localhost:11434`, no SSH/docker.
  codex consumes it natively (`--backend ollama` → `--oss --local-provider ollama`).
- **llama.cpp** is the advanced, env-driven path: set `CODEX_DISPATCH_LOCAL_ENDPOINT`,
  `CODEX_DISPATCH_LOCAL_MODEL`, and (for remote control) `CODEX_DISPATCH_LOCAL_SSH` +
  `CODEX_DISPATCH_LOCAL_UP_CMD`/`_DOWN_CMD`. See `templates/local-headless.config.toml.example`.

The chosen backend is recorded in `<config>/local.env`; switch at runtime with
`CODEX_DISPATCH_LOCAL_BACKEND=ollama|llamacpp`.

### Env knobs
| Variable | Effect |
|---|---|
| `PS_OS=macos\|linux` | Force the daemon path (auto-detected otherwise; useful for WSL/containers/CI). |
| `PS_WITH_LOCAL` / `--with-local` | Opt into the local-model backend (off by default). |
| `CCP_SKIP_PATH=1` | Skip the `ccp` PATH symlink. |
| `CODEX_DISPATCH_LOCAL_BACKEND` | `ollama` (default) or `llamacpp` — selects the local backend at runtime. |
| `CODEX_DISPATCH_LOCAL_ENDPOINT` / `_MODEL` | Override the local endpoint/model (defaults: `localhost:8080/v1` + `local-model` for llama.cpp; `localhost:11434` + `qwen2.5-coder` for Ollama). |
| `CURATOR_INTERVAL_SECONDS` | Curator cadence (default `1800`). |
| `LAUNCH_AGENTS_DIR` / `SYSTEMD_USER_DIR` | Sandbox the unit dir (used by the tests). |

Re-running `install.sh` is idempotent. **Moving the repo** after install
requires re-running it, since hooks are registered in `settings.json` by
absolute path through `profiles/_shared` (the installer dedups by exact path, so
a moved repo adds a new entry rather than replacing the old one).

---

## Usage

### Launch a profile — `ccp`
```bash
ccp                     # default profile (~/.claude)
ccp work                # launch the 'work' profile
ccp work --resume       # flags after the name fall through to `claude`
```

### Manage profiles — `/profile`
Run inside a Claude Code session:
```
/profile list           # all profiles (* = active)
/profile create <name>  # short interview, then scaffold a new profile
/profile show <name>    # persona, skills, memory at a glance
/profile status         # active profile + curator state
/profile provision <name>   # scaffold non-interactively
/profile doctor         # validate + self-heal a profile's shared symlinks
/profile archive <name> # retire a profile (recoverable)
/profile switch <name>  # prints the `ccp <name>` relaunch line
```

`/profile create` runs a lightweight interview (purpose, voice, must-have
workflows), then writes a persona `CLAUDE.md`, authors one skill per reusable
procedure, seeds memory pointers for facts, and symlinks any shared library
skills you want — applying a simple triage: **procedure → skill, fact → memory.**

### Background learning — `/curator` + the `learn` skill
The `learn` skill flags a learning candidate mid-session; the curator daemon
later validates, dedupes, and files it as a skill or memory. Inspect and control
it with:
```
/curator status | stats | inbox | notifications | pause | resume | restore | run
```

### Codex dispatch — `/codex-implement`
```
/codex-implement "add retry/backoff to the upload client"
/codex-implement --quick "fix the typo in config.yaml"   # in-place, no worktree
```
Claude plans the change and the verification; codex implements it in an isolated
worktree; Claude reviews and gates the merge. The `codex-local-doctor` skill
audits/repairs the local-model backend before you rely on it.

---

## A profile's anatomy

```
~/.claude/profiles/<name>/
  CLAUDE.md                       # the persona / operating contract
  skills/<slug>/SKILL.md          # authored procedures + symlinked shared skills
  projects/_profile/memory/
    MEMORY.md                     # the memory index
    <slug>.md                     # one fact or skill-pointer per file
  commands/                       # /profile, /curator, /codex-implement (symlinked)
  curator/inbox/                  # learning candidates awaiting curation
  settings.json                   # this profile's hooks, plugins, permissions
```

Profiles **link** into shared machinery rather than copying it: `profiles/_shared/`
points at this repo, so editing a hook or skill here propagates to every profile.

---

## Repository layout

```
install.sh              # auto-detecting entry: core + OS daemon dispatch
profile_mgmt.sh         # /profile backend (list/create/provision/…)
codex_dispatch.sh       # /codex-implement backend (exec/resume/worktree/verify)
bin/
  ccp                   # the profile launcher
  curator / curator.py  # subsystem B daemon + operator CLI
  local-ask / learn-flag
lib/
  install-common.sh     # cross-platform install core
  daemon-macos.sh       # launchd agent installer
  daemon-linux.sh       # systemd user service + timer installer
  paths.sh jsonutil.sh dispatch.sh local.sh curator_paths.py
commands/               # /profile, /curator, /codex-implement
skills/                 # codex-implement, codex-local-doctor, learn
hooks/                  # profile-wakeup (SessionStart), learn-capture (Stop)
templates/              # curator.plist (macOS), curator.service + curator.timer (Linux)
tests/                  # 42 bash test files (run.sh)
docs/                   # specs/ + plans/ + smoke results
```

---

## Tests

```bash
bash tests/run.sh
```

42 hermetic bash test files covering the installer (both daemon paths), `ccp`,
`/profile` lifecycle, the curator, and codex dispatch. Each test sandboxes
`CC_PROFILE_ROOT`, `CODEX_HOME`, and the daemon dirs so it never touches your
real config. The Linux daemon path is exercised on any host via `PS_OS=linux`.

---

## Design docs

Full specifications and implementation plans live in `docs/`:

- `docs/specs/2026-05-28-profile-layer-design.md` — subsystem A
- `docs/specs/2026-06-01-subsystem-b-learning-design.md` — subsystem B
- `docs/specs/2026-05-31-codex-dispatch-design.md` — subsystem C
- `docs/specs/2026-05-31-codex-dispatch-local-backend-design.md` — local backend

---

## Status

Personal infrastructure, in active use. Subsystem A is stable; B and C are
functional and evolving.

## License

[MIT](LICENSE) © 2026 Gregory Campisi

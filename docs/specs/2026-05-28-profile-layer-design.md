# Profile Layer (Subsystem A) — Design Spec

- **Date:** 2026-05-28
- **Status:** Approved (design); pending spec review
- **Subsystem:** A of 3 (A = Profiles · B = Self-improvement learning · C = Codex dev-process dispatch)
- **Project home:** `~/.claude/profile-system/` (this repo)

---

## 1. Goal

Rewire the Claude Code harness to replicate two systems observed in the local
hermes agent (`~/.hermes`):

1. **Profiles** — switchable, fully isolated agent environments, each with its
   own identity, memories, learned skills, and configuration.
2. **Self-improvement learning** — an autonomous loop that grows and curates a
   profile's memories and skills over time.

…while preserving the user's existing **dev process**: Claude is the
reasoning / brainstorming / planning agent and dispatches **codex** for the
actual implementation.

This spec covers **only Subsystem A (the Profile Layer)** — the foundation the
other two subsystems operate inside. B and C get their own spec → plan →
implement cycles.

The **gateway** (hermes's multi-channel server) is explicitly **out of scope**.

---

## 2. Locked decisions (project-wide decision log)

These were resolved during brainstorming and govern all three subsystems:

| # | Decision | Choice |
|---|----------|--------|
| D1 | "Two types" refers to… | **Codex dispatch modes**: one-shot `codex exec` vs. resumable `codex resume`. |
| D2 | What a profile is | **Full isolated environment**, hermes-style. |
| D3 | Learning autonomy | **Fully autonomous, background.** |
| D4 | Where the system lives | **In `~/.claude` global config** (runtime artifacts); source in this repo. |
| D5 | Relationship to claude-peers roles | **Kept entirely separate.** The `CLAUDE_PEER_ROLE` role framework is untouched. |
| D6 | Learning trigger | **Dedicated background daemon** (not hook-only). |
| D7 | Curation engine | **Headless Sonnet** (`claude -p --model sonnet`) for heavy synthesis, **fed by learning-candidates the main session emits while it works** (the main model has full context and flags *what* was learned; the daemon validates / dedupes / consolidates / files it). |
| D8 | Codex dispatch flow | **Auto-select** exec vs. resume **+ auto-verify** the diff before reporting done. |
| D9 | Codex workspace | **Git worktree per dispatch.** |
| D10 | Daemon flavor (B) | **Lean Python daemon on launchd** — small orchestrator; intelligence lives in `claude -p`; JSON sidecar state with file locks. |
| D11 | Build order | **A → C → B.** |
| D12 | Default profile | **`~/.claude` itself is the structured default profile** (hermes's `~/.hermes` model). `ccp` (no arg) activates it; `ccp <name>` activates `~/.claude/profiles/<name>`. The default profile is **adopted** into the structure additively (gains `curator/inbox/`, `.curator_state`, the shared SessionStart+Stop hooks, and machinery-skill symlinks) without destroying existing config. |

### Environment facts (verified 2026-05-28)
- `codex` CLI present: `codex-cli 0.130.0`.
- `claude` CLI present: `2.1.156` (supports headless `-p`).
- `CLAUDE_CONFIG_DIR` relocates the **entire** Claude Code config dir — the
  exact analog of hermes's `HERMES_HOME`. This is the mechanism profiles use.
- **Credentials live in the macOS Keychain** (`Claude Code-credentials`),
  machine-level → **auth is shared across all profiles automatically**;
  creating a profile never requires re-login.
- Native flags already enabled in `~/.claude/settings.json`:
  `autoMemoryEnabled`, `autoDreamEnabled`. Subsystem B builds on these, not
  around them.
- Existing SessionStart hook: `role-wakeup.sh` (claude-peers). Existing
  PreToolUse hook: `worktree-discipline.sh`. Both remain untouched.

---

## 3. System overview (context for A)

```
ccp <profile> ──exports CLAUDE_CONFIG_DIR──▶ claude  (interactive session)
                                               │
                 SessionStart: profile-wakeup.sh  (A.4)
                                               │
   ┌───────────────────────────────────────────┼─────────────────────────────┐
   │ Active profile = ~/.claude/profiles/<name>/ (own memory, skills, persona) │
   │                                            │                              │
   │   Dev loop (C): Claude plans ─▶ codex (exec│resume) in a worktree ─▶ verify│
   │                                            │                              │
   │   Stop hook: learn-capture.sh ─▶ profile's curator/inbox/   (B feed)      │
   └────────────────────────────────────────────┼─────────────────────────────┘
                                                 ▼
                       launchd daemon (B): drains inbox + idle timer,
                       runs `claude -p --model sonnet` to curate
                       memories + skills into the active profile.
```

Subsystem A delivers everything above the dashed daemon: profile isolation,
activation, wakeup, and management. It also lays down the **inbox directory and
curator-state file shape** that B will consume, so B can be added without
re-touching A.

---

## 4. Subsystem A — detailed design

### A.0 Project home & install model
- Source (machinery, hooks, skills, daemon, installer, specs) lives in this
  repo: `~/.claude/profile-system/`.
- `install.sh` wires the repo into the live config: creates
  `~/.claude/profiles/_shared/`, symlinks shared hooks + skills, and (for B)
  drops the launchd plist. Idempotent and re-runnable.
- Rationale: keeps D4 true (runtime artifacts under `~/.claude`) while giving a
  clean, versioned, testable source tree.

### A.1 Directory layout (mirrors `~/.hermes` ↔ `~/.hermes/profiles/<name>`)
```
~/.claude/                      ← THE DEFAULT PROFILE (today's config, adopted into the structure)
│                                 + curator/inbox/, .curator_state, shared hooks
│                                 registered in settings.json, machinery skills
│                                 symlinked into skills/  (all additive)
├── profile-system/             ← THIS repo (source)
├── profiles/
│   ├── _shared/                ← canonical machinery (symlink source)
│   │   ├── hooks/                profile-wakeup.sh, learn-capture.sh
│   │   └── skills/               codex-implement/, profile-mgmt/, learn/
│   ├── <name>/                 ← a named profile = a full CLAUDE_CONFIG_DIR
│   │   ├── CLAUDE.md             ← persona (SOUL.md analog) + ops instructions  [isolated]
│   │   ├── settings.json         ← model / perms / hooks / enabledPlugins       [isolated]
│   │   ├── skills/               ← LEARNED / curated skills                     [isolated]
│   │   ├── agents/               ← per-profile subagents (optional)            [isolated]
│   │   ├── plugins  → ~/.claude/plugins        (symlink)                        [shared]
│   │   ├── hooks/   → ../_shared/hooks          (symlink)                       [shared]
│   │   ├── projects/             ← sessions + todos + MEMORY (native)           [isolated]
│   │   ├── .curator_state        ← per-profile scheduler (consumed by B)        [isolated]
│   │   └── curator/inbox/        ← learning-candidate queue (consumed by B)     [isolated]
│   └── …
└── active_profile              ← sticky pointer: name of last-activated profile
```

### A.2 Isolation boundary
- **Isolated (real dirs/files, per profile):** persona `CLAUDE.md`,
  `settings.json`, learned `skills/`, `agents/`, `projects/` (memory + sessions
  + todos), `.curator_state`, `curator/inbox/`.
- **Shared (symlinked in for *named* profiles):** `plugins/` → the default
  profile's real `~/.claude/plugins` (the canonical plugin set), `hooks/` →
  `_shared/hooks/`, plus `_shared/skills/` machinery. Auth is shared for free
  via the keychain. (The default profile owns the real `plugins/` and `hooks/`;
  named profiles point back at them.)
- **Invariant (from hermes):** the curator (B) only ever mutates **agent-created
  skills in the profile's own `skills/`** — never the symlinked machinery.
  Symlinked skill dirs are treated as read-only/bundled.

### A.3 Activation — the `ccp` wrapper (the `hermes -p` analog)
A zsh function installed into the user's shell rc:
- `ccp` (no arg) → activates the **default profile** (= `~/.claude`):
  `unset CLAUDE_CONFIG_DIR`, `export CLAUDE_PROFILE=default`, write `default`
  to `active_profile`, then `exec claude "$@"`. The session reads `~/.claude`,
  which now carries the profile structure (D12).
- `ccp <name> [args…]` →
  1. resolve `~/.claude/profiles/<name>`; error if missing (suggest `ccp create`).
  2. `export CLAUDE_CONFIG_DIR=~/.claude/profiles/<name>`
  3. `export CLAUDE_PROFILE=<name>`
  4. write `<name>` to `~/.claude/active_profile` (sticky; used by daemon B).
  5. `exec claude "$@"`.
- `-p` is unavailable (it is claude's `--print`), hence the distinct `ccp` name.
  *(Micro-decision M1: name = `ccp`. Revisable.)*
- **Mid-session switching is impossible** (the config dir is read once at
  launch). `/profile switch <name>` therefore only prints/launches the correct
  `ccp` invocation; it does not mutate the running session.

### A.4 Wakeup — `profile-wakeup.sh` (SessionStart, independent of roles)
- Registered as an **additional** SessionStart hook entry in each profile's
  `settings.json` (including the default profile's `~/.claude/settings.json`);
  does not replace `role-wakeup.sh`.
- **Profile resolution:** active profile = `CLAUDE_PROFILE` if set, else derived
  from `CLAUDE_CONFIG_DIR` (path under `profiles/<name>` ⇒ `<name>`; unset or
  `~/.claude` ⇒ `default`). So a plain `claude` launch (no `ccp`) still resolves
  to and wakes the default profile.
- Always emits a `===== PROFILE WAKEUP =====` block (default profile included):
  - active profile name + one-line persona summary (first heading of `CLAUDE.md`),
  - curator status: last-run timestamp + `# pending` items in `curator/inbox/`,
  - learned-skill count (real dirs in `skills/`).
- The persona itself loads **natively** — it is the profile's `CLAUDE.md`,
  which Claude Code reads as global instructions for that config dir. The hook
  only adds live status a static file cannot.
- Timeout-bounded (≤10s); pure read-only; never blocks the session.

### A.5 `/profile` management skill (`_shared/skills/profile-mgmt/`)
Subcommands:
- `list` — all profiles + which is active (from `active_profile`).
- `show <name>` — persona summary, skill/memory counts, symlink health.
- `status` — curator state for the active profile (last run, pending, paused).
- `create <name> [--from <template>]` — scaffold (see A.6).
- `archive <name>` — move to `profiles/.archived/<name>/`; **never hard-delete**.
- `switch <name>` — print the `ccp <name>` line (cannot switch in place).
- `doctor` — validate + self-heal shared symlinks; report drift.

### A.6 `create` scaffolding
`ccp create <name>` / `/profile create <name>` produces:
- the profile dir + `skills/`, `agents/`, `projects/`, `curator/inbox/`.
- a starter persona `CLAUDE.md` (from `_shared/templates/persona.md`).
- a base `settings.json` from `_shared/templates/settings.json`, which registers:
  the shared **SessionStart** hook (`profile-wakeup.sh`) **alongside any existing
  entries**, the shared **Stop** hook (`learn-capture.sh` — a stub in A, the
  B feed), the user's current `enabledPlugins`, and
  `autoMemoryEnabled`/`autoDreamEnabled`. *(Micro-decision M2: per-profile
  settings copied from template — lets profiles diverge on model/permissions.)*
- symlinks: `plugins → ~/.claude/plugins`, `hooks → ../_shared/hooks`.
- an initial `.curator_state` (`{"last_run_at": null, "paused": false, "run_count": 0}`).
- `agents/` is per-profile/isolated. *(Micro-decision M3.)*

### A.7 Persona / identity (SOUL.md analog)
- Per-profile persona = the profile's `CLAUDE.md`. Loaded natively as global
  instructions for that config dir; no extra wiring needed for the static part.
- Output-style-based persona swaps are **deferred** — `CLAUDE.md` is sufficient.

### A.8 Safety / error handling
- **Sticky-profile mismatch guard:** the guard keys off the env pair that
  `ccp` always sets together — if `CLAUDE_PROFILE=<name>` is set but
  `CLAUDE_CONFIG_DIR` does **not** resolve to the expected dir
  (`~/.claude/profiles/<name>`, or `~/.claude`/unset when `<name>=default`),
  `profile-wakeup.sh` prints a loud warning (the lesson from hermes's
  `HERMES_HOME` silent-fallback bug, issue #18594). Plain `claude` (no
  `CLAUDE_PROFILE`) never warns. `active_profile` is a separate, daemon-facing
  pointer (B reads it to know which profile to curate); `ccp` keeps it in sync,
  setting it to `default` on a no-arg launch.
- **Symlink self-heal:** wakeup + `/profile doctor` validate and repair the
  shared symlinks; broken/missing links are recreated from `_shared`.
- **Archive-not-delete:** profiles are archived, never removed, by tooling.
- **Write locks:** memory/skill writes use `.lock` files (mirroring hermes's
  `MEMORY.md.lock`) so B's daemon and the live session never corrupt each other.
  A lays the lock convention (A.8) even though the daemon arrives in B.
- **Default-profile adoption is additive & non-destructive:** `install.sh`
  adopts `~/.claude` as the default profile by *adding* `curator/inbox/`,
  `.curator_state`, the two shared hook entries (merged into the existing
  `hooks` block alongside `role-wakeup.sh`/`worktree-discipline.sh`), and
  machinery-skill symlinks into `skills/`. It never removes or rewrites existing
  settings, plugins, skills, or hooks. The pre-adoption `settings.json` is
  backed up. Re-running `install.sh` is idempotent.

---

## 5. Acceptance criteria

A is "done" when, on this machine:
1. `ccp create demo` scaffolds `~/.claude/profiles/demo/` with all dirs, a
   persona `CLAUDE.md`, a base `settings.json`, valid `plugins`/`hooks`
   symlinks, and an initial `.curator_state`.
2. `ccp demo` launches a session whose `CLAUDE_CONFIG_DIR` is the demo profile;
   `CLAUDE_PROFILE=demo`; `active_profile` contains `demo`.
3. In that session: new memory and the session transcript/todos are written
   **under `profiles/demo/projects/…`**, not under `~/.claude/projects/…`.
4. Shared skills (e.g. `codex-implement`) and all `enabledPlugins` resolve and
   are invocable inside the demo profile.
5. Keychain auth works with no re-login prompt.
6. The PROFILE WAKEUP block appears at session start with correct profile name,
   persona summary, and curator status (0 pending on a fresh profile).
7. The default profile is `~/.claude` adopted additively: existing
   `enabledPlugins`, skills, settings keys, and the `role-wakeup.sh` /
   `worktree-discipline.sh` hooks are all preserved and still fire. Both plain
   `claude` and `ccp` (no arg) resolve to the default profile and emit its
   PROFILE WAKEUP block. (Adoption is non-destructive, not byte-for-byte: it
   adds `curator/`, `.curator_state`, two hook entries, and skill symlinks.)
8. `/profile list|show|status|doctor|archive|switch` behave as specified;
   `doctor` repairs a deliberately-broken symlink.
9. The sticky-profile mismatch guard fires when `active_profile` and the
   resolved config dir disagree.

### Testing approach
- A `tests/` dir with a bats/shell harness that uses a **sandbox HOME**
  (`CLAUDE_PROFILE_TEST_ROOT`) so tests never touch the real `~/.claude`.
- Each acceptance criterion maps to at least one test.
- A manual smoke checklist for the keychain/native-load items that can't be
  unit-tested headlessly.

---

## 6. Out of scope (this spec)
- **Subsystem B** internals (daemon code, headless-Sonnet curation prompts,
  skill lifecycle/provenance/usage, consolidation). A only lays the
  `curator/inbox/` + `.curator_state` shapes and the `learn-capture.sh` Stop
  hook stub that feeds them.
- **Subsystem C** internals (codex auto-select, worktree orchestration,
  auto-verify). A only ships the placeholder `codex-implement` skill dir under
  `_shared/skills/` so the symlink target exists.
- The hermes **gateway** / multi-channel server.
- Any change to the **claude-peers role framework** (D5).

## 7. Risks & mitigations
- **R1 — A relocated `CLAUDE_CONFIG_DIR` doesn't pick up plugins/skills as
  expected.** Mitigation: verified symlink-in approach + acceptance test #4
  before building dependent tooling; fall back to copying `plugins/` if symlink
  resolution misbehaves.
- **R2 — `ccp` shell-rc edit conflicts with existing rc content.** Mitigation:
  idempotent, clearly-delimited managed block; `install.sh` never edits inside
  it twice.
- **R3 — Per-profile `settings.json` drift from the template over time.**
  Mitigation: `/profile doctor` reports drift; template versioned in-repo.
- **R4 — Concurrent writes once B exists.** Mitigation: lock convention
  established now (A.8) so B inherits it.

## 8. Open micro-decisions (defaulted; revisable)
- **M1:** wrapper name `ccp`.
- **M2:** per-profile `settings.json` copied from a template (vs shared single file).
- **M3:** `agents/` per-profile/isolated (vs shared symlink).

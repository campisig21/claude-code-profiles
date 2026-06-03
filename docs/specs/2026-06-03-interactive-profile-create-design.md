# Interactive `/profile create` — Design

**Date:** 2026-06-03
**Status:** Approved (brainstorming) → ready for implementation plan
**Component:** `profile-system` (`profile_mgmt.sh`, `_shared/commands/profile.md`, `templates/`)

## Problem

`/profile create <name>` scaffolds an empty profile *immediately* at command-expansion
time, then drops a stub `persona.md` full of `(Describe…)` placeholders for the user to
fill in by hand. Two problems:

1. **No configuration step.** Creating a profile gives you an inert shell. The user wants
   to *describe what the profile is for* — like creating an agent — and have that baked
   into the persona, baseline skills, and seed memory.
2. **Phantom "already exists" error.** The `/profile` command runs
   `!`bash profile_mgmt.sh $ARGUMENTS`` at prompt-expansion time (the `!`-prefix executes
   before Claude sees the prompt). That first run creates the profile and prints
   "Created…". Claude — because `/profile` is also a Skill and the body says "Execute:" —
   then re-runs the same script, which now hits `cmd_create`'s
   `[ -e "$P" ] && die "already exists"` guard. The profile *was* created; the error is a
   redundant second run.

## Goals

- `create` launches a **Claude-driven interview** that configures the profile before
  anything is written to disk.
- **Nothing is written until the user approves** the assembled persona. Aborting
  mid-interview leaves zero files — no cleanup needed.
- The interview produces three distinct kinds of output, routed by the system's existing
  **"memory = pointer, skill = detail"** philosophy (the same split the curator/`learn`
  system uses).
- Fix the double-execution phantom-error bug as a side effect.

## Non-goals (YAGNI)

- Tailoring `settings.json` / permissions — keep copying from the default profile.
- Draft/auto-clean logic — unnecessary, since nothing is written before approval.
- A pure-bash interactive wizard — the interview is Claude-driven, not `read -p`.

## Design

### Approach: `create` reserves, `provision` builds

Split the single immediate-scaffold `create` into two phases.

#### `profile_mgmt.sh create <name>` — reserve only

- Validates the name (`valid_name` + not already present).
- Writes **nothing** to disk.
- On success, prints a structured cue:
  ```
  PROFILE_INTERVIEW_READY name=<name>
  Name '<name>' is available. Begin the profile-creation interview.
  ```
- Because it no longer writes, re-running it is idempotent → **the phantom
  "already exists" bug disappears** for `create`.
- If the name is taken or invalid, it still `die`s with the existing message (correct —
  you cannot create over an existing profile).

#### `profile_mgmt.sh provision <name>` — build the skeleton (new subcommand)

- Performs exactly today's mechanical scaffolding, factored out of the old `cmd_create`:
  - `mkdir -p` the profile dirs (`skills`, `agents`, `projects`, `curator/inbox`,
    `commands`).
  - `settings.json` derived from the default profile (same `jq` projection as today),
    plus the two registered command hooks (`profile-wakeup.sh`, `learn-capture.sh`).
  - Curator state init.
  - Symlinks: `plugins`, `hooks`, `commands/profile.md`, and the `_shared/skills/*` set.
- Lays down the stub `persona.md` **only as a fallback** (so a provision that is never
  followed by a persona write still has *something*). Normal flow overwrites it.
- Guarded by the existing `[ -e "$P" ] && die "already exists"`.
- Prints `Provisioned '<name>'`.

> Implementation note: keep the shared scaffolding in one helper so `create`'s old body
> and `provision` don't drift. The old `cmd_create` becomes `cmd_provision` (minus the
> "Created…" / `ccp` epilogue, which moves to the post-write step), and the new
> `cmd_create` is the thin reserve-and-cue function.

### Command markdown (`_shared/commands/profile.md`)

Rewritten so behavior branches on the subcommand:

- **All subcommands except `create`** → present the `!`backtick output **verbatim**, then
  an optional one-line interpretation. **Explicitly instruct: do not re-invoke the
  script.** This kills the double-run for every subcommand, not just `create`.
- **`create`** → the `PROFILE_INTERVIEW_READY` cue instructs Claude to:
  1. Run the interview (below).
  2. Present the assembled persona for approval.
  3. **Only after approval**, run `profile_mgmt.sh provision <name>` and write the
     authored artifacts.
  - Claude never re-runs `create`.

### The interview (Claude-driven) — lightweight, propose-then-confirm

**This must NOT be a 15-question interrogation.** The model is *propose, you agree or
edit* — like reviewing a generated agent, not filling out a form.

1. **One intake prompt.** Claude asks a single open question: *what is this profile for,
   and any must-haves?* (purpose + voice + any processes/skills the user already knows
   they want). The user answers in free form, as much or as little as they like.
2. **Claude proposes the whole bundle at once**, derived from that answer:
   - the assembled persona (identity, operating style, dev process — defaults filled in:
     Claude plans/brainstorms, codex implements via `/codex-implement`, unless the intake
     says otherwise),
   - the list of **skills** it intends to author (procedures), each with a one-line
     description,
   - the list of **memory pointers** it intends to seed (facts + skill pointers),
   - any extra existing `_shared`/library skills to symlink.
3. **One approval pass.** The user agrees, or edits inline ("drop that skill", "rename
   this", "add X"). At most one short round of edits is expected — not a long dialogue.

Only ask a follow-up question if the intake is genuinely too thin to propose anything
sensible. Default to proposing with reasonable defaults and letting the user correct.

### Memory = pointer, skill = detail (triage)

The interview output is routed by an **automatic rule** (no per-item confirmation):

- **Procedure / workflow / "how to"** (has steps, is reusable) → authored as a **skill**:
  `$P/skills/<slug>/SKILL.md` with `name` + `description` frontmatter tuned for correct
  triggering. This is the *detail*.
- **Fact** (no procedure — a domain truth, a constraint, the profile's purpose) → a
  **memory pointer**: a one-fact file in `$P/projects/_profile/memory/` plus its one-line
  entry in `MEMORY.md`. This is the *pointer*.
- Every authored **skill also gets a memory pointer** whose body links `[[<slug>]]`, so
  the skill is discoverable from the memory index.
- The **persona stays lean** — identity/style only, not facts or procedures.

Formats follow the existing standards verbatim:
- **Memory:** frontmatter `name` / `description` / `metadata.type`
  (`project` | `reference` | `feedback` | `user`); body is one fact; `MEMORY.md` carries
  one `- [Title](file.md) — hook` line per memory.
- **Skill:** `<slug>/SKILL.md` with `--- name: … / description: … ---` frontmatter.

### Post-approval provisioning sequence (Claude performs)

1. `profile_mgmt.sh provision <name>` → skeleton on disk.
2. **Write `$P/CLAUDE.md`** — the filled-in persona, **zero `(Describe…)` placeholders**.
3. **Author baseline skills** — for each procedure identified, write
   `$P/skills/<slug>/SKILL.md`.
4. **Seed memory** — ensure `$P/projects/_profile/memory/` exists; write/update
   `MEMORY.md` (index) plus one memory file per fact and per skill-pointer.
5. **Existing baseline skills** — symlink any additional chosen `_shared`/library skills
   beyond the default set.
6. Print the final `Activate it with:  ccp <name>` line.

## Data flow

```
/profile create recipe
  → !`profile_mgmt.sh create recipe`           (expansion-time; writes nothing)
  → prints PROFILE_INTERVIEW_READY name=recipe
  → Claude asks ONE intake question (purpose + must-haves)
  → Claude proposes the whole bundle (persona + skills + memory pointers + extra skills)
  → user agrees or edits inline (≤1 short round)  ──reject──▶ stop (nothing written)
        │ approve
        ▼
  → profile_mgmt.sh provision recipe           (skeleton: dirs, settings, symlinks)
  → Write $P/CLAUDE.md                          (persona — no placeholders)
  → Write $P/skills/<slug>/SKILL.md  …          (procedures = detail)
  → Write $P/projects/_profile/memory/{MEMORY.md, *.md}   (facts + skill pointers)
  → symlink extra baseline skills
  → print "Activate it with: ccp recipe"
```

## Error handling

- **Name taken / invalid** → `create` `die`s before any interview; Claude surfaces the
  message and stops.
- **User rejects persona** → no `provision` call; nothing on disk.
- **`provision` fails** (e.g. race: dir appeared) → `die`s on the `[ -e "$P" ]` guard;
  Claude surfaces it and does not attempt the Write steps.
- **Double-run of any subcommand** → `create` is now idempotent; read-only subcommands
  were always idempotent; the markdown forbids the redundant re-invocation regardless.

## Testing

The repo has a `tests/` suite. Add/extend:
- `create <name>` writes nothing to disk and emits `PROFILE_INTERVIEW_READY`.
- `create <existing>` still `die`s (`already exists`); `create <invalid>` still `die`s.
- `provision <name>` produces the same skeleton the old `create` did (dirs, `settings.json`
  keys, hook registration, curator state, all four symlink classes).
- `provision <existing>` `die`s on the guard.
- Re-running `create <name>` twice in a row does **not** error (regression test for the
  phantom bug).

## Files touched

- `profile_mgmt.sh` — split `cmd_create`; add `cmd_provision`; register `provision` in
  `main()` dispatch.
- `_shared/commands/profile.md` — branch on subcommand; forbid re-invocation; drive the
  interview + post-approval sequence for `create`.
- `templates/persona.md` — unchanged content, but now consumed as the *provision fallback*
  rather than the user-facing artifact (Claude's authored persona replaces it on the
  normal path).
- `tests/` — new cases above.

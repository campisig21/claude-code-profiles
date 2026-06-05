---
description: Manage Claude Code profiles (list, show, status, create, archive, switch, doctor)
argument-hint: <subcommand> [name]
allowed-tools: Bash
---

Run the profile-system management script and act on its output.

Execute:

!`bash ~/.claude/profile-system/profile_mgmt.sh $ARGUMENTS`

## How to respond, by subcommand

**For every subcommand EXCEPT `create`** (`list`, `show`, `status`, `switch`,
`provision`, `doctor`, `archive`, or empty → `list`): the script already ran above.
Present its output verbatim, then add at most one line of interpretation. **do not re-run
the script** — the `!`-prefixed line above already executed it; running it again
would double-create or error.

For `switch`: surface the printed `ccp <name>` line so the user can relaunch (mid-session
switching is impossible).

**For `create <name>`:** the output above is a `PROFILE_INTERVIEW_READY name=<name>` cue.
The profile does NOT exist yet and nothing was written. Run a lightweight interview, then
provision on approval. **Never re-run `create`.**

### Interview (keep it short — propose, don't interrogate)

1. Ask ONE open intake question: *what is this profile for, and any must-haves?*
   (purpose, voice, any processes or skills the user already wants). Let them answer freely.
2. From that answer, propose the whole bundle in one message:
   - the **persona** (identity, operating style, dev process — default: Claude
     plans/brainstorms, codex implements via `/codex-implement`, unless they said otherwise);
   - **skills** to author — one per reusable *procedure/workflow* (the detail), each with a
     one-line description;
   - **memory pointers** to seed — one per *fact* (the pointer), plus one pointer per skill;
   - any extra existing `_shared`/library skills to symlink.
   Apply the triage automatically: procedure → skill, fact → memory. Keep the persona lean
   (identity/style only — no facts, no procedures).
3. Let the user agree or edit inline. Expect at most one short round of edits.

**On rejection:** stop — nothing has been written (provision has not run).

### On approval — provision and author (in this order)

1. Run: `bash ~/.claude/profile-system/profile_mgmt.sh provision <name>` (builds the skeleton).
   It prints `Provisioned '<name>' at <ABSOLUTE_PATH>` — use that printed `<ABSOLUTE_PATH>` as
   the profile directory `<P>`, the base for ALL subsequent writes below.
2. **Write** `<P>/CLAUDE.md` — the authored persona, with NO `(Describe…)` placeholders left.
3. For each procedure, **Write** `<P>/skills/<slug>/SKILL.md` with frontmatter:
   `---`/`name: <slug>`/`description: <trigger-oriented one-liner>`/`---` then the steps.
4. **Seed memory** under `<P>/projects/_profile/memory/`:
   - `MEMORY.md` — a `# Memory Index` with one `- [Title](file.md) — hook` line per memory;
   - one `<slug>.md` per fact and per skill-pointer, each with frontmatter `name` /
     `description` and, under `metadata`, both `type` (`project`|`reference`|`feedback`|`user`)
     and `node_type: memory`; a skill-pointer's body links the skill with `[[<slug>]]`.
5. Relay the script's `Activate it with: ccp <name>` line.

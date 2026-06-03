# Interactive `/profile create` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/profile create <name>` reserve-only (write nothing until approved), add a `provision` subcommand that builds the skeleton, and rewrite the command markdown so Claude runs a lightweight interview that authors the persona + baseline skills + memory pointers — also fixing the phantom "already exists" double-run bug.

**Architecture:** Split `cmd_create` (mechanical scaffold) into `cmd_create` (validate + print an interview cue, no disk writes) and a new `cmd_provision` (the old scaffold body). The Claude-driven interview lives entirely in `_shared/commands/profile.md`: one intake question → propose the whole bundle → on approval call `provision`, then `Write` the persona, skills, and `_profile` memory. Spec: `docs/specs/2026-06-03-interactive-profile-create-design.md`.

**Tech Stack:** Bash (`profile_mgmt.sh`, `lib/paths.sh`, `lib/jsonutil.sh`), `jq`, the repo's `tests/lib.sh` assertion harness, Markdown slash-command file.

---

## File Structure

- `profile_mgmt.sh` — split `cmd_create`; add `cmd_provision`; register `provision` in `main()`.
- `commands/profile.md` — source of truth for the `/profile` slash command (symlinked into `_shared/commands/` then `~/.claude/commands/`). Rewrite to branch on subcommand and drive the interview.
- `tests/profile_mgmt_create_test.sh` — rewrite: `create` now writes nothing and prints the cue; keep the validation/reserved-name cases; add a double-run regression case.
- `tests/profile_mgmt_provision_test.sh` — NEW: asserts the skeleton (the file-creation assertions that used to live in the create test) + duplicate-provision guard.
- `tests/profile_command_md_test.sh` — NEW: lightweight grep checks that the markdown branches on `create` and forbids re-invocation.
- `templates/persona.md` — UNCHANGED (now consumed as the provision fallback).

Run the whole suite at any point with: `bash ~/.claude/profile-system/tests/run.sh`

---

## Task 1: Split `create` → reserve-only + new `provision` (the bash core)

**Files:**
- Modify: `~/.claude/profile-system/profile_mgmt.sh` (`cmd_create` ~lines 32-85; `main()` ~lines 173-186)
- Test (rewrite): `~/.claude/profile-system/tests/profile_mgmt_create_test.sh`
- Test (new): `~/.claude/profile-system/tests/profile_mgmt_provision_test.sh`

- [ ] **Step 1: Rewrite the create test to expect reserve-only behavior**

Replace the entire contents of `tests/profile_mgmt_create_test.sh` with:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
MGMT="$PS_REPO_ROOT/profile_mgmt.sh"

# Pre-stage _shared so symlink targets exist (install.sh does this for real).
mkdir -p "$CC_PROFILE_ROOT/profiles/_shared"
ln -sfn "$PS_REPO_ROOT/hooks"     "$CC_PROFILE_ROOT/profiles/_shared/hooks"
ln -sfn "$PS_REPO_ROOT/commands"  "$CC_PROFILE_ROOT/profiles/_shared/commands"
ln -sfn "$PS_REPO_ROOT/skills"    "$CC_PROFILE_ROOT/profiles/_shared/skills"
ln -sfn "$PS_REPO_ROOT/templates" "$CC_PROFILE_ROOT/profiles/_shared/templates"

# create now RESERVES ONLY: it validates and prints an interview cue, writes nothing.
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work 2>&1)"; rc=$?
assert_eq "$rc" "0" "create succeeds"
assert_contains "$out" "PROFILE_INTERVIEW_READY name=work" "create prints interview cue"
P="$CC_PROFILE_ROOT/profiles/work"
[ -e "$P" ] && assert_eq exists nothing "create must NOT create the profile dir" || assert_eq ok ok "create wrote nothing"

# create is idempotent now (regression: the old phantom 'already exists' double-run bug).
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work >/dev/null 2>&1; r_again=$?
assert_eq "$r_again" "0" "re-running create does not error (no phantom 'already exists')"

# create over an ALREADY-PROVISIONED profile still fails.
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" provision taken >/dev/null 2>&1
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create taken >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "create over existing profile fails"

# reserved names fail
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create default >/dev/null 2>&1; r1=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create _shared >/dev/null 2>&1; r2=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create "bad/name" >/dev/null 2>&1; r3=$?
set -e 2>/dev/null || true
assert_eq "$r1" "1" "reserved: default"
assert_eq "$r2" "1" "reserved: _shared"
assert_eq "$r3" "1" "invalid: slash"

# unsafe / metacharacter names rejected (allowlist)
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create "foo&bar" >/dev/null 2>&1; ra=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create ".." >/dev/null 2>&1; rb=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create "-x" >/dev/null 2>&1; rc2=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create ".hidden" >/dev/null 2>&1; rd=$?
set -e 2>/dev/null || true
assert_eq "$ra" "1" "reject ampersand name"
assert_eq "$rb" "1" "reject dotdot name"
assert_eq "$rc2" "1" "reject leading-dash name"
assert_eq "$rd" "1" "reject leading-dot name"

ps_report
```

- [ ] **Step 2: Run the create test to verify it fails**

Run: `bash ~/.claude/profile-system/tests/profile_mgmt_create_test.sh`
Expected: FAIL — `create` still scaffolds (so "create must NOT create the profile dir" fails) and `provision` is an unknown subcommand.

- [ ] **Step 3: Add the new provision test (the skeleton assertions, moved from old create)**

Create `tests/profile_mgmt_provision_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
MGMT="$PS_REPO_ROOT/profile_mgmt.sh"

# Pre-stage _shared so symlink targets exist (install.sh does this for real).
mkdir -p "$CC_PROFILE_ROOT/profiles/_shared"
ln -sfn "$PS_REPO_ROOT/hooks"     "$CC_PROFILE_ROOT/profiles/_shared/hooks"
ln -sfn "$PS_REPO_ROOT/commands"  "$CC_PROFILE_ROOT/profiles/_shared/commands"
ln -sfn "$PS_REPO_ROOT/skills"    "$CC_PROFILE_ROOT/profiles/_shared/skills"
ln -sfn "$PS_REPO_ROOT/templates" "$CC_PROFILE_ROOT/profiles/_shared/templates"

out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" provision work 2>&1)"; rc=$?
assert_eq "$rc" "0" "provision succeeds"
assert_contains "$out" "Provisioned 'work'" "provision announces"
assert_contains "$out" "ccp work" "provision prints activate hint"
P="$CC_PROFILE_ROOT/profiles/work"
assert_file "$P/CLAUDE.md" "fallback persona created"
assert_contains "$(cat "$P/CLAUDE.md")" "work Profile" "persona name substituted"
assert_file "$P/settings.json" "settings created"
assert_eq "$(jq -r '.enabledPlugins["superpowers@official"]' "$P/settings.json")" "true" "inherited plugins"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | any(test("profile-wakeup"))' "$P/settings.json")" "true" "wakeup hook registered"
assert_eq "$(jq '[.hooks.Stop[].hooks[].command] | any(test("learn-capture"))' "$P/settings.json")" "true" "stop hook registered"
assert_file "$P/.curator_state" "curator state created"
assert_eq "$(jq -r '.run_count' "$P/.curator_state")" "0" "curator state init"
assert_symlink "$P/plugins" "plugins symlinked"
assert_symlink "$P/commands/profile.md" "command symlinked"
[ -d "$P/skills" ] && assert_eq ok ok "skills dir" || assert_eq no ok "skills dir missing"
[ -d "$P/curator/inbox" ] && assert_eq ok ok "inbox dir" || assert_eq no ok "inbox missing"

# duplicate provision fails
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" provision work >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "duplicate provision fails"

# valid dotted/dashed name still provisions
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" provision "my-profile.2" >/dev/null 2>&1
[ -d "$CC_PROFILE_ROOT/profiles/my-profile.2" ] && assert_eq ok ok "valid dotted/dashed name" || assert_eq no ok "valid name should provision"

ps_report
```

- [ ] **Step 4: Run the provision test to verify it fails**

Run: `bash ~/.claude/profile-system/tests/profile_mgmt_provision_test.sh`
Expected: FAIL — `provision` is an unknown subcommand (rc=1, "Provisioned" never printed).

- [ ] **Step 5: Implement the split in `profile_mgmt.sh`**

Replace the entire `cmd_create() { ... }` function (currently ~lines 32-85) with these TWO functions:

```bash
cmd_create() {
  local name="${1:-}"
  valid_name "$name" || die "invalid or reserved profile name: '${name}'"
  local P; P="$(profile_dir "$name")"
  [ -e "$P" ] && die "profile '$name' already exists at $P"
  # Reserve-only: write NOTHING. Emit a cue that tells the /profile command's
  # Claude flow to run the interview, then call `provision` after approval.
  cat <<EOF
PROFILE_INTERVIEW_READY name=$name
Name '$name' is available. Begin the profile-creation interview.
EOF
}

cmd_provision() {
  local name="${1:-}"
  valid_name "$name" || die "invalid or reserved profile name: '${name}'"
  local P; P="$(profile_dir "$name")"
  [ -e "$P" ] && die "profile '$name' already exists at $P"

  local shared; shared="$(shared_dir)"
  mkdir -p "$P/skills" "$P/agents" "$P/projects" "$P/curator/inbox" "$P/commands"

  # persona from template, with {{PROFILE_NAME}} substituted (fallback; the
  # /profile create flow overwrites this with the authored persona).
  if [ -f "$shared/templates/persona.md" ]; then
    sed "s/{{PROFILE_NAME}}/$name/g" "$shared/templates/persona.md" > "$P/CLAUDE.md"
  else
    printf '# %s Profile\n' "$name" > "$P/CLAUDE.md"
  fi

  # settings.json: inherit enabledPlugins + flags from the default profile,
  # then register the two profile hooks by absolute _shared path.
  local def_settings; def_settings="$(cc_root)/settings.json"
  if [ -f "$def_settings" ]; then
    jq '{
          enabledPlugins: (.enabledPlugins // {}),
          extraKnownMarketplaces: (.extraKnownMarketplaces // {}),
          autoMemoryEnabled: (.autoMemoryEnabled // true),
          autoDreamEnabled: (.autoDreamEnabled // true),
          permissions: {defaultMode: (.permissions.defaultMode // "default")}
        }
        + (if .statusLine then {statusLine: .statusLine} else {} end)' \
      "$def_settings" > "$P/settings.json"
  else
    echo '{"permissions":{"defaultMode":"default"}}' > "$P/settings.json"
  fi
  js_merge_command_hook "$P/settings.json" SessionStart "bash $shared/hooks/profile-wakeup.sh"
  js_merge_command_hook "$P/settings.json" Stop          "bash $shared/hooks/learn-capture.sh"

  # curator state
  js_init_curator_state "$P/.curator_state"

  # shared-machinery symlinks
  ln -sfn "$(cc_root)/plugins" "$P/plugins"
  ln -sfn "$shared/hooks"      "$P/hooks"
  [ -f "$shared/commands/profile.md" ] && ln -sfn "$shared/commands/profile.md" "$P/commands/profile.md"
  if [ -d "$shared/skills" ]; then
    local s
    for s in "$shared/skills"/*/; do
      [ -d "$s" ] || continue
      ln -sfn "${s%/}" "$P/skills/$(basename "$s")"
    done
  fi

  echo "Provisioned '$name' at $P"
  echo "Activate it with:  ccp $name"
}
```

- [ ] **Step 6: Register `provision` in the `main()` dispatch**

In `main()`, add the `provision` case right after the `create` case:

```bash
    create)  cmd_create "$@" ;;
    provision) cmd_provision "$@" ;;
```

- [ ] **Step 7: Run both tests to verify they pass**

Run: `bash ~/.claude/profile-system/tests/profile_mgmt_create_test.sh && bash ~/.claude/profile-system/tests/profile_mgmt_provision_test.sh`
Expected: both PASS (ps_report prints all-pass for each).

- [ ] **Step 8: Run the full suite (catch lifecycle/query regressions)**

Run: `bash ~/.claude/profile-system/tests/run.sh`
Expected: `=== N/N test files passed ===`. If `profile_mgmt_lifecycle_test.sh` or `profile_mgmt_query_test.sh` calls `create` expecting a scaffold, update those calls to `provision` (same args) and re-run.

- [ ] **Step 9: Commit**

```bash
cd ~/.claude/profile-system
git add profile_mgmt.sh tests/profile_mgmt_create_test.sh tests/profile_mgmt_provision_test.sh
git commit -m "feat(profile): split create into reserve-only create + provision

create now validates and prints a PROFILE_INTERVIEW_READY cue without
touching disk; the new provision subcommand does the scaffold. Fixes the
phantom 'already exists' double-run and is the basis for the interview flow.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Rewrite the `/profile` command markdown to drive the interview

**Files:**
- Modify: `~/.claude/profile-system/commands/profile.md` (the repo source; symlinked into `_shared/commands/` and `~/.claude/commands/`)
- Test (new): `~/.claude/profile-system/tests/profile_command_md_test.sh`

- [ ] **Step 1: Write the markdown contract test**

Create `tests/profile_command_md_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MD="$PS_REPO_ROOT/commands/profile.md"

assert_file "$MD" "command markdown exists"
body="$(cat "$MD")"
assert_contains "$body" "profile_mgmt.sh \$ARGUMENTS" "still runs the mgmt script at expansion"
assert_contains "$body" "PROFILE_INTERVIEW_READY" "handles the create interview cue"
assert_contains "$body" "provision" "create flow calls provision after approval"
assert_contains "$body" "_profile/memory" "seeds profile-global memory pointers"
assert_contains "$body" "do not re-run" "forbids redundant re-invocation"

ps_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash ~/.claude/profile-system/tests/profile_command_md_test.sh`
Expected: FAIL — current markdown lacks `PROFILE_INTERVIEW_READY`, `provision`, `_profile/memory`, and the "do not re-run" guard.

- [ ] **Step 3: Replace the body of `commands/profile.md`**

Keep the YAML frontmatter as-is, but replace everything below it with:

````markdown
Run the profile-system management script and act on its output.

Execute:

!`bash ~/.claude/profile-system/profile_mgmt.sh $ARGUMENTS`

## How to respond, by subcommand

**For every subcommand EXCEPT `create`** (`list`, `show`, `status`, `switch`,
`provision`, `doctor`, `archive`, or empty → `list`): the script already ran above.
Present its output verbatim, then add at most one line of interpretation. **Do not
re-run the script** — the `!`-prefixed line above already executed it; running it again
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

### On approval — provision and author (in this order)

1. Run: `bash ~/.claude/profile-system/profile_mgmt.sh provision <name>` (builds the skeleton).
2. **Write** `<profiles>/<name>/CLAUDE.md` — the authored persona, with NO `(Describe…)`
   placeholders left.
3. For each procedure, **Write** `<profiles>/<name>/skills/<slug>/SKILL.md` with frontmatter:
   `---`/`name: <slug>`/`description: <trigger-oriented one-liner>`/`---` then the steps.
4. **Seed memory** under `<profiles>/<name>/projects/_profile/memory/`:
   - `MEMORY.md` — a `# Memory Index` with one `- [Title](file.md) — hook` line per memory;
   - one `<slug>.md` per fact and per skill-pointer, each with frontmatter
     `name` / `description` / `metadata.type` (`project`|`reference`|`feedback`|`user`); a
     skill-pointer's body links the skill with `[[<slug>]]`.
5. Relay the script's `Activate it with: ccp <name>` line.

`<profiles>` is `~/.claude/profiles` (or `$CLAUDE_CONFIG_DIR`-derived if a profile is active).
If the user rejects the persona, stop — nothing has been written.
````

- [ ] **Step 4: Run the contract test to verify it passes**

Run: `bash ~/.claude/profile-system/tests/profile_command_md_test.sh`
Expected: PASS.

- [ ] **Step 5: Verify the symlink chain still resolves to the new content**

Run: `diff <(cat ~/.claude/commands/profile.md) ~/.claude/profile-system/commands/profile.md && echo SYMLINK_OK`
Expected: `SYMLINK_OK` (the `~/.claude/commands/profile.md` → `_shared/commands/profile.md` → repo `commands/profile.md` chain shows the edited content).

- [ ] **Step 6: Run the full suite**

Run: `bash ~/.claude/profile-system/tests/run.sh`
Expected: `=== N/N test files passed ===`.

- [ ] **Step 7: Commit**

```bash
cd ~/.claude/profile-system
git add commands/profile.md tests/profile_command_md_test.sh
git commit -m "feat(profile): drive interactive create via command markdown

create now runs a lightweight interview (one intake → propose bundle →
approve), then provisions and authors persona + skills + _profile memory
pointers. All other subcommands present output verbatim and never re-run.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Manual end-to-end smoke (real `/profile create`)

**Files:** none (manual verification).

- [ ] **Step 1: Dry-run the bash halves directly**

Run: `bash ~/.claude/profile-system/profile_mgmt.sh create smoketest`
Expected: prints `PROFILE_INTERVIEW_READY name=smoketest`; `ls ~/.claude/profiles/smoketest` → "No such file or directory" (nothing written).

- [ ] **Step 2: Provision and inspect**

Run: `bash ~/.claude/profile-system/profile_mgmt.sh provision smoketest && ls -la ~/.claude/profiles/smoketest`
Expected: `Provisioned 'smoketest'` + `ccp smoketest`; dir contains `CLAUDE.md`, `settings.json`, `.curator_state`, `skills/`, `commands/profile.md`, `plugins` symlink.

- [ ] **Step 3: Tear down the smoke profile**

Run: `bash ~/.claude/profile-system/profile_mgmt.sh archive smoketest`
Expected: `Archived 'smoketest'` (recoverable under `profiles/.archived/`). Then optionally `rm -rf ~/.claude/profiles/.archived/smoketest`.

- [ ] **Step 4: Exercise the real flow once (in a NEW Claude Code session)**

In a fresh session, run `/profile create demo-recipe`, answer the single intake question, approve the proposed bundle, and confirm: the profile dir appears only after approval; `~/.claude/profiles/demo-recipe/CLAUDE.md` has no `(Describe…)` placeholders; any proposed `skills/<slug>/SKILL.md` and `projects/_profile/memory/MEMORY.md` + pointer files exist. Then `archive demo-recipe`.

(No commit — verification only.)

---

## Self-Review Notes

- **Spec coverage:** create-reserves (Task 1), provision-builds (Task 1), markdown branching + no-re-run (Task 2), one-intake/propose-bundle interview (Task 2 markdown), memory=pointer/skill=detail authoring (Task 2 markdown steps 3-4), seed memory at `_profile/memory` (Task 2), double-run regression test (Task 1 create test), provision skeleton parity (Task 1 provision test). All spec sections map to a task.
- **Non-goals respected:** no `settings.json`/permissions tailoring; no draft/auto-clean (nothing written pre-approval).
- **Type/name consistency:** subcommand `provision`, cue token `PROFILE_INTERVIEW_READY name=<name>`, and memory path `projects/_profile/memory/` are used identically across `profile_mgmt.sh`, the markdown, and all three tests.

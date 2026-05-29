# Profile Layer (Subsystem A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the profile layer — `CLAUDE_CONFIG_DIR`-per-profile isolation, a `ccp` activation wrapper, a SessionStart wakeup hook, a `Stop` learning-capture stub, shared-machinery symlinking, a `/profile` management command, and an idempotent installer that adopts `~/.claude` as the structured default profile.

**Architecture:** Pure-bash scripts (portable `#!/usr/bin/env bash`) plus `jq` for JSON. All path resolution funnels through one sourced helper (`lib/paths.sh`) whose root is overridable via `CC_PROFILE_ROOT`, so every script is testable against a temp sandbox that never touches the real `~/.claude`. `ccp` is an executable on PATH (not a shell function) — same `ccp <name>` UX, but testable and requires no `~/.zshrc` edit. Hooks are registered in each profile's `settings.json` by absolute `_shared` path; `plugins/` and machinery skills/commands are delivered into each profile by symlink. Source lives in this repo (`~/.claude/profile-system/`); `install.sh` wires it into the live config.

**Tech Stack:** bash, jq 1.8.1, python3 3.14.3 (available; used only if needed), macOS (`darwin`), a dependency-free pure-bash test harness (no bats).

**Spec:** `docs/specs/2026-05-28-profile-layer-design.md` (decisions D1–D12).

**Deviations from spec (approved-design-consistent refinements):**
- `ccp` is a PATH executable, not a `~/.zshrc` function (testable, no rc mutation → removes risk R2).
- Hooks fire via absolute `_shared/hooks/...` paths in `settings.json`; the per-profile `hooks/` symlink is kept for convention/`doctor` but is not load-bearing for execution.
- `_shared/templates/settings.json` is realized as **generation logic** in `profile_mgmt.sh create` (inherits the default profile's `enabledPlugins`), not a static file.

---

## File Structure

```
~/.claude/profile-system/
├── bin/ccp                         # activation wrapper (executable on PATH)
├── lib/paths.sh                    # path resolution (sourced) — single source of truth
├── lib/jsonutil.sh                 # jq helpers: curator-state init, field read, hook merge
├── hooks/profile-wakeup.sh         # SessionStart: wakeup block + mismatch guard + symlink heal
├── hooks/learn-capture.sh          # Stop: writes a breadcrumb into <profile>/curator/inbox/ (B feed)
├── commands/profile.md             # /profile slash command (glue → profile_mgmt.sh)
├── skills/codex-implement/SKILL.md # placeholder (subsystem C fills in)
├── skills/learn/SKILL.md           # placeholder (subsystem B fills in)
├── templates/persona.md            # starter CLAUDE.md for new profiles
├── profile_mgmt.sh                 # create/list/show/status/archive/switch/doctor
├── install.sh                      # wires repo into ~/.claude; adopts default profile
├── README.md
├── tests/
│   ├── lib.sh                      # sandbox + assertions (sourced)
│   ├── run.sh                      # runs all *_test.sh
│   ├── paths_test.sh
│   ├── jsonutil_test.sh
│   ├── ccp_test.sh
│   ├── wakeup_test.sh
│   ├── learn_capture_test.sh
│   ├── profile_mgmt_create_test.sh
│   ├── profile_mgmt_query_test.sh
│   ├── profile_mgmt_lifecycle_test.sh
│   ├── install_test.sh
│   └── e2e_test.sh
└── docs/{specs,plans}/...
```

**Responsibilities:**
- `lib/paths.sh` — *where things are.* No side effects. Sourced everywhere.
- `lib/jsonutil.sh` — *JSON read/merge.* Pure functions over files.
- `bin/ccp` — *activation only.* Sets env, stamps `active_profile`, execs claude.
- `hooks/*` — *runtime glue at session boundaries.* Read-only/append-only, never fail the session.
- `profile_mgmt.sh` — *profile lifecycle.* The tested core behind `/profile`.
- `install.sh` — *one-time wiring + default-profile adoption.* Idempotent.

---

## Task 0: Test harness + repo scaffold

**Files:**
- Create: `tests/lib.sh`, `tests/run.sh`, `tests/smoke_test.sh`

- [ ] **Step 1: Write the harness library**

Create `tests/lib.sh`:

```bash
# Sourced by every *_test.sh. Provides a temp sandbox + assertions.
# Never executed directly.

PS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS_TESTS=0
PS_FAILS=0

ps_setup_sandbox() {
  PS_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ps_test.XXXXXX")"
  export CC_PROFILE_ROOT="$PS_SANDBOX"
  mkdir -p "$CC_PROFILE_ROOT/plugins"
  cat > "$CC_PROFILE_ROOT/settings.json" <<'JSON'
{ "enabledPlugins": { "superpowers@official": true }, "permissions": { "defaultMode": "default" } }
JSON
}

ps_teardown_sandbox() {
  [ -n "${PS_SANDBOX:-}" ] && rm -rf "$PS_SANDBOX"
}

# Fake `claude` that dumps env + args (for ccp tests). Echoes its path.
ps_make_fake_claude() {
  local p="$PS_SANDBOX/fake-claude"
  cat > "$p" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"
echo "CLAUDE_PROFILE=${CLAUDE_PROFILE:-<unset>}"
echo "ARGS=$*"
SH
  chmod +x "$p"
  printf '%s\n' "$p"
}

assert_eq() {
  PS_TESTS=$((PS_TESTS + 1))
  if [ "$1" != "$2" ]; then
    echo "  FAIL: ${3:-assert_eq}: expected [$2], got [$1]"
    PS_FAILS=$((PS_FAILS + 1))
  fi
}
assert_contains() {
  PS_TESTS=$((PS_TESTS + 1))
  case "$1" in
    *"$2"*) ;;
    *) echo "  FAIL: ${3:-assert_contains}: output missing [$2]"; PS_FAILS=$((PS_FAILS + 1)) ;;
  esac
}
assert_file() {
  PS_TESTS=$((PS_TESTS + 1))
  [ -e "$1" ] || { echo "  FAIL: ${2:-assert_file}: missing [$1]"; PS_FAILS=$((PS_FAILS + 1)); }
}
assert_symlink() {
  PS_TESTS=$((PS_TESTS + 1))
  [ -L "$1" ] || { echo "  FAIL: ${2:-assert_symlink}: not a symlink [$1]"; PS_FAILS=$((PS_FAILS + 1)); }
}
ps_report() {
  echo "  ($PS_TESTS checks, $PS_FAILS failed)"
  return "$PS_FAILS"
}
```

- [ ] **Step 2: Write the runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
total=0; failed=0
for t in "$HERE"/*_test.sh; do
  [ -e "$t" ] || continue
  echo "RUN $(basename "$t")"
  bash "$t"; rc=$?
  total=$((total + 1))
  if [ "$rc" -ne 0 ]; then failed=$((failed + 1)); echo "  -> FAILED (rc=$rc)"; fi
done
echo "=== $((total - failed))/$total test files passed ==="
[ "$failed" -eq 0 ]
```

- [ ] **Step 3: Write a smoke test (proves the harness fails and passes correctly)**

Create `tests/smoke_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
assert_eq "hello" "hello" "harness sanity"
assert_file "$CC_PROFILE_ROOT/settings.json" "sandbox seeded settings"
ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 4: Run the harness, verify it passes**

Run: `bash tests/run.sh`
Expected: `RUN smoke_test.sh` then `(2 checks, 0 failed)` and `=== 1/1 test files passed ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd ~/.claude/profile-system
git add tests/
git commit -m "test: add dependency-free bash test harness + smoke test"
```

---

## Task 1: `lib/paths.sh` — path resolution

**Files:**
- Create: `lib/paths.sh`
- Test: `tests/paths_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/paths_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$PS_REPO_ROOT/lib/paths.sh"
ps_setup_sandbox

assert_eq "$(cc_root)" "$CC_PROFILE_ROOT" "cc_root honors CC_PROFILE_ROOT"
assert_eq "$(profiles_dir)" "$CC_PROFILE_ROOT/profiles" "profiles_dir"
assert_eq "$(shared_dir)" "$CC_PROFILE_ROOT/profiles/_shared" "shared_dir"
assert_eq "$(profile_dir default)" "$CC_PROFILE_ROOT" "default -> cc_root"
assert_eq "$(profile_dir)" "$CC_PROFILE_ROOT" "empty -> cc_root"
assert_eq "$(profile_dir foo)" "$CC_PROFILE_ROOT/profiles/foo" "named profile dir"

# profile_exists
mkdir -p "$CC_PROFILE_ROOT/profiles/foo"
if profile_exists foo; then assert_eq ok ok "foo exists"; else assert_eq missing ok "foo should exist"; fi
if profile_exists nope; then assert_eq present absent "nope should not exist"; else assert_eq absent absent "nope absent"; fi

# resolve_active_profile (env-prefixed to isolate)
assert_eq "$(CLAUDE_PROFILE=bar resolve_active_profile)" "bar" "CLAUDE_PROFILE wins"
assert_eq "$(CLAUDE_PROFILE= CLAUDE_CONFIG_DIR= resolve_active_profile)" "default" "unset -> default"
assert_eq "$(CLAUDE_PROFILE= CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT" resolve_active_profile)" "default" "cc_root -> default"
assert_eq "$(CLAUDE_PROFILE= CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/baz" resolve_active_profile)" "baz" "derive from config dir"

# expected_config_dir
assert_eq "$(expected_config_dir default)" "" "default expects empty"
assert_eq "$(expected_config_dir foo)" "$CC_PROFILE_ROOT/profiles/foo" "named expected dir"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/paths_test.sh`
Expected: FAIL — `lib/paths.sh: No such file or directory` (source fails).

- [ ] **Step 3: Implement `lib/paths.sh`**

```bash
#!/usr/bin/env bash
# Path resolution for the profile system. SOURCE this; do not execute.
# Single source of truth for where profiles live. No side effects.

# Base dir holding profiles/, active_profile; IS the default profile.
# Overridable via CC_PROFILE_ROOT (tests).
cc_root() { printf '%s\n' "${CC_PROFILE_ROOT:-$HOME/.claude}"; }

profiles_dir() { printf '%s\n' "$(cc_root)/profiles"; }
shared_dir()   { printf '%s\n' "$(cc_root)/profiles/_shared"; }

# profile_dir [name]: "default"/empty => cc_root; else profiles/<name>.
profile_dir() {
  local name="${1:-default}"
  if [ "$name" = "default" ]; then cc_root; else printf '%s\n' "$(profiles_dir)/$name"; fi
}

profile_exists() { [ -d "$(profile_dir "$1")" ]; }

# Echo the active profile name from env: CLAUDE_PROFILE wins, else derive
# from CLAUDE_CONFIG_DIR (under profiles/<name> => name; cc_root/unset => default).
resolve_active_profile() {
  if [ -n "${CLAUDE_PROFILE:-}" ]; then printf '%s\n' "$CLAUDE_PROFILE"; return; fi
  local ccd="${CLAUDE_CONFIG_DIR:-}"
  if [ -z "$ccd" ] || [ "$ccd" = "$(cc_root)" ]; then printf '%s\n' "default"; return; fi
  local pdir; pdir="$(profiles_dir)"
  case "$ccd" in
    "$pdir"/*) printf '%s\n' "$(basename "$ccd")" ;;
    *)         printf '%s\n' "default" ;;
  esac
}

# Where CLAUDE_CONFIG_DIR should point for <name>. default => "" (unset/cc_root ok).
expected_config_dir() {
  local name="$1"
  if [ "$name" = "default" ]; then printf '%s\n' ""; else profile_dir "$name"; fi
}
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/paths_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/paths.sh tests/paths_test.sh
git commit -m "feat: add path resolution helpers (lib/paths.sh)"
```

---

## Task 2: `lib/jsonutil.sh` — jq helpers

**Files:**
- Create: `lib/jsonutil.sh`
- Test: `tests/jsonutil_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/jsonutil_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$PS_REPO_ROOT/lib/jsonutil.sh"
ps_setup_sandbox

# curator state init
state="$CC_PROFILE_ROOT/.curator_state"
js_init_curator_state "$state"
assert_file "$state" "state created"
assert_eq "$(jq -r '.paused' "$state")" "false" "paused default false"
assert_eq "$(jq -r '.run_count' "$state")" "0" "run_count default 0"
assert_eq "$(jq -r '.last_run_at' "$state")" "null" "last_run_at null"
# idempotent: mutate then re-init must not clobber
jq '.run_count = 5' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
js_init_curator_state "$state"
assert_eq "$(jq -r '.run_count' "$state")" "5" "init idempotent (no clobber)"

# js_get
assert_eq "$(js_get "$state" '.run_count')" "5" "js_get field"
assert_eq "$(js_get "$state" '.last_run_at')" "" "js_get null -> empty"
assert_eq "$(js_get /no/such/file '.x')" "" "js_get missing file -> empty"

# hook merge (additive + idempotent)
s="$CC_PROFILE_ROOT/settings.json"
js_merge_command_hook "$s" SessionStart "bash /abs/profile-wakeup.sh"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | length' "$s")" "1" "one SessionStart hook"
js_merge_command_hook "$s" SessionStart "bash /abs/profile-wakeup.sh"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | length' "$s")" "1" "merge idempotent"
js_merge_command_hook "$s" Stop "bash /abs/learn-capture.sh"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" "bash /abs/learn-capture.sh" "Stop hook added"
assert_eq "$(jq -r '.enabledPlugins["superpowers@official"]' "$s")" "true" "existing keys preserved"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/jsonutil_test.sh`
Expected: FAIL — `lib/jsonutil.sh: No such file or directory`.

- [ ] **Step 3: Implement `lib/jsonutil.sh`**

```bash
#!/usr/bin/env bash
# JSON helpers (jq-based). SOURCE this; do not execute.

# Write a fresh curator-state file iff absent (idempotent).
js_init_curator_state() {
  local path="$1"
  [ -f "$path" ] && return 0
  jq -n '{last_run_at: null, last_run_duration_seconds: null, last_run_summary: null, paused: false, run_count: 0}' > "$path"
}

# Print a field; empty string if file missing or value null.
js_get() {
  local file="$1" filter="$2"
  [ -f "$file" ] || { printf '\n'; return 0; }
  jq -r "$filter // empty" "$file" 2>/dev/null || printf '\n'
}

# Add a {type:command} hook under <event> if that exact command is not already
# present. Additive (keeps existing entries), idempotent. Creates .hooks/.hooks[event].
js_merge_command_hook() {
  local file="$1" event="$2" cmd="$3" tmp
  tmp="$(mktemp)"
  jq --arg ev "$event" --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks[$ev] //= [] |
    if any(.hooks[$ev][]?; (.hooks[]?|.command) == $cmd)
    then .
    else .hooks[$ev] += [{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}]
    end
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/jsonutil_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/jsonutil.sh tests/jsonutil_test.sh
git commit -m "feat: add jq JSON helpers (lib/jsonutil.sh)"
```

---

## Task 3: `bin/ccp` — activation wrapper

**Files:**
- Create: `bin/ccp`
- Test: `tests/ccp_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/ccp_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
fake="$(ps_make_fake_claude)"
CCP="$PS_REPO_ROOT/bin/ccp"

# default profile: no arg -> CLAUDE_CONFIG_DIR unset, CLAUDE_PROFILE=default
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CCP_CLAUDE_BIN="$fake" bash "$CCP")"
assert_contains "$out" "CLAUDE_CONFIG_DIR=<unset>" "default unsets config dir"
assert_contains "$out" "CLAUDE_PROFILE=default" "default profile name"
assert_eq "$(cat "$CC_PROFILE_ROOT/active_profile")" "default" "active_profile=default"

# missing named profile -> error, exit 1, no launch
set +e
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CCP_CLAUDE_BIN="$fake" bash "$CCP" ghost 2>&1)"; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "missing profile exits 1"
assert_contains "$out" "not found" "missing profile message"

# existing named profile -> sets config dir + profile + active_profile, passes args
mkdir -p "$CC_PROFILE_ROOT/profiles/work"
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CCP_CLAUDE_BIN="$fake" bash "$CCP" work --resume)"
assert_contains "$out" "CLAUDE_CONFIG_DIR=$CC_PROFILE_ROOT/profiles/work" "config dir set"
assert_contains "$out" "CLAUDE_PROFILE=work" "profile name set"
assert_contains "$out" "ARGS=--resume" "args forwarded"
assert_eq "$(cat "$CC_PROFILE_ROOT/active_profile")" "work" "active_profile=work"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/ccp_test.sh`
Expected: FAIL — `bin/ccp: No such file or directory` / non-zero from missing script.

- [ ] **Step 3: Implement `bin/ccp`**

```bash
#!/usr/bin/env bash
# ccp — Claude Code profile launcher (the `hermes -p` analog).
# Usage:
#   ccp                  -> default profile (~/.claude)
#   ccp <name> [args...] -> named profile (~/.claude/profiles/<name>)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "$HERE/../lib/paths.sh"

name="default"
# First non-flag arg is the profile name; flags fall through to claude.
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then name="$1"; shift; fi

if [ "$name" = "default" ]; then
  unset CLAUDE_CONFIG_DIR
else
  if ! profile_exists "$name"; then
    echo "ccp: profile '$name' not found at $(profile_dir "$name")" >&2
    echo "ccp: create it with:  /profile create $name   (or  $HERE/../profile_mgmt.sh create $name)" >&2
    exit 1
  fi
  CLAUDE_CONFIG_DIR="$(profile_dir "$name")"
  export CLAUDE_CONFIG_DIR
fi

export CLAUDE_PROFILE="$name"
mkdir -p "$(cc_root)"
printf '%s\n' "$name" > "$(cc_root)/active_profile"

exec "${CCP_CLAUDE_BIN:-claude}" "$@"
```

- [ ] **Step 4: Make executable + run test**

Run: `chmod +x bin/ccp && bash tests/ccp_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/ccp tests/ccp_test.sh
git commit -m "feat: add ccp profile activation wrapper"
```

---

## Task 4: `hooks/profile-wakeup.sh` — SessionStart wakeup

**Files:**
- Create: `hooks/profile-wakeup.sh`
- Test: `tests/wakeup_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/wakeup_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
HOOK="$PS_REPO_ROOT/hooks/profile-wakeup.sh"

# default profile: emits wakeup JSON with additionalContext naming "default"
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=default bash "$HOOK")"
assert_contains "$out" '"hookEventName": "SessionStart"' "wakeup is SessionStart"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "PROFILE WAKEUP: default" "default wakeup header"
assert_contains "$ctx" "Curator:" "curator status line present"

# named profile with persona + pending inbox + one learned skill
mkdir -p "$CC_PROFILE_ROOT/profiles/work/skills/my-skill" \
         "$CC_PROFILE_ROOT/profiles/work/curator/inbox"
printf '# Work Profile\nBackend specialist.\n' > "$CC_PROFILE_ROOT/profiles/work/CLAUDE.md"
echo '{}' > "$CC_PROFILE_ROOT/profiles/work/curator/inbox/item1.json"
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=work \
        CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/work" bash "$HOOK")"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "PROFILE WAKEUP: work" "named header"
assert_contains "$ctx" "Work Profile" "persona summary from CLAUDE.md"
assert_contains "$ctx" "1 pending" "pending inbox count"
assert_contains "$ctx" "1 learned skill" "learned skill count"

# mismatch guard: CLAUDE_PROFILE=work but config dir points elsewhere
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=work \
        CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/OTHER" bash "$HOOK")"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "PROFILE MISMATCH" "mismatch guard fires"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/wakeup_test.sh`
Expected: FAIL — hook file missing.

- [ ] **Step 3: Implement `hooks/profile-wakeup.sh`**

```bash
#!/usr/bin/env bash
# SessionStart hook for the profile system. Independent of role-wakeup.sh.
# Emits a PROFILE WAKEUP context block with live status, plus a loud warning
# if CLAUDE_PROFILE and CLAUDE_CONFIG_DIR disagree. Read-only; never blocks.
set -uo pipefail
cat >/dev/null 2>&1 || true   # drain stdin (hook input JSON, unused here)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve paths.sh whether invoked via _shared symlink or repo path.
if [ -f "$HERE/../../../profile-system/lib/paths.sh" ]; then
  source "$HERE/../../../profile-system/lib/paths.sh"   # _shared/hooks -> repo/hooks
else
  source "$HERE/../lib/paths.sh"                          # repo/hooks
fi
source "$(dirname "$(command -v jq)")/../bin/.." 2>/dev/null || true  # noop guard
# jsonutil for js_get
JU="$(cd "$HERE" && pwd)/../lib/jsonutil.sh"
[ -f "$JU" ] && source "$JU" || true

name="$(resolve_active_profile)"
pdir="$(profile_dir "$name")"

# --- mismatch guard ---
warning=""
if [ -n "${CLAUDE_PROFILE:-}" ]; then
  exp="$(expected_config_dir "$CLAUDE_PROFILE")"
  ccd="${CLAUDE_CONFIG_DIR:-}"
  if [ "$CLAUDE_PROFILE" = "default" ]; then
    if [ -n "$ccd" ] && [ "$ccd" != "$(cc_root)" ]; then
      warning="!! PROFILE MISMATCH: CLAUDE_PROFILE=default but CLAUDE_CONFIG_DIR=$ccd (expected unset or $(cc_root)). Data may land in the wrong profile."
    fi
  elif [ "$ccd" != "$exp" ]; then
    warning="!! PROFILE MISMATCH: CLAUDE_PROFILE=$CLAUDE_PROFILE but CLAUDE_CONFIG_DIR=${ccd:-<unset>} (expected $exp). Data may land in the wrong profile."
  fi
fi

# --- symlink self-heal (named profiles only; default owns real dirs) ---
if [ "$name" != "default" ] && [ -d "$pdir" ]; then
  [ -e "$pdir/plugins" ] || ln -sfn "$(cc_root)/plugins" "$pdir/plugins" 2>/dev/null || true
  [ -e "$pdir/hooks" ]   || ln -sfn "$(shared_dir)/hooks" "$pdir/hooks" 2>/dev/null || true
fi

# --- gather status ---
persona="(no persona set)"
if [ -f "$pdir/CLAUDE.md" ]; then
  persona="$(grep -m1 -E '^[^[:space:]]' "$pdir/CLAUDE.md" | sed 's/^#\+ *//')"
  [ -n "$persona" ] || persona="(empty CLAUDE.md)"
fi
state="$pdir/.curator_state"
last_run="never"
if [ -f "$state" ]; then
  lr="$(js_get "$state" '.last_run_at')"; [ -n "$lr" ] && last_run="$lr"
fi
pending=0
[ -d "$pdir/curator/inbox" ] && pending="$(find "$pdir/curator/inbox" -maxdepth 1 -type f | wc -l | tr -d ' ')"
learned=0
[ -d "$pdir/skills" ] && learned="$(find "$pdir/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

ctx="===== PROFILE WAKEUP: $name =====
Persona: $persona
Curator: last run $last_run · $pending pending learning candidate(s)
Skills:  $learned learned skill(s)"
[ -n "$warning" ] && ctx="$warning

$ctx"
ctx="$ctx
===== END PROFILE WAKEUP ====="

jq -n --arg msg "Profile: $name" --arg ctx "$ctx" \
  '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
```

NOTE for the implementer: the two `source` resolution lines above are fragile. Replace them with this simpler, robust block (the repo layout guarantees `lib/` is a sibling of `hooks/`, and `_shared/hooks` is a symlink to `repo/hooks`, so `$HERE/../lib` resolves correctly through the symlink because `cd -P` is NOT used):

```bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/paths.sh"
source "$HERE/../lib/jsonutil.sh"
```

Use exactly that 3-line block in place of the messy resolution + the `JU` lines. (`_shared/hooks` → `repo/hooks`, so `_shared/hooks/../lib` = `repo/lib`. ✓)

- [ ] **Step 4: Run, verify it passes**

Run: `chmod +x hooks/profile-wakeup.sh && bash tests/wakeup_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add hooks/profile-wakeup.sh tests/wakeup_test.sh
git commit -m "feat: add profile-wakeup SessionStart hook with mismatch guard"
```

---

## Task 5: `hooks/learn-capture.sh` — Stop hook (B feed stub)

**Files:**
- Create: `hooks/learn-capture.sh`
- Test: `tests/learn_capture_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/learn_capture_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
HOOK="$PS_REPO_ROOT/hooks/learn-capture.sh"

# default profile: writes a breadcrumb into cc_root/curator/inbox/
mkdir -p "$CC_PROFILE_ROOT/curator/inbox"
input='{"session_id":"abc123","transcript_path":"/tmp/t.jsonl","cwd":"/repo"}'
out="$(printf '%s' "$input" | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=default bash "$HOOK")"
count="$(find "$CC_PROFILE_ROOT/curator/inbox" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$count" "1" "one breadcrumb written"
f="$(find "$CC_PROFILE_ROOT/curator/inbox" -maxdepth 1 -type f -name '*.json' | head -1)"
assert_eq "$(jq -r '.session_id' "$f")" "abc123" "session_id captured"
assert_eq "$(jq -r '.transcript_path' "$f")" "/tmp/t.jsonl" "transcript captured"
assert_eq "$(jq -r '.profile' "$f")" "default" "profile captured"

# never fails the session even on malformed input
set +e
printf 'not json' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=default bash "$HOOK" >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "0" "malformed input still exits 0"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/learn_capture_test.sh`
Expected: FAIL — hook file missing.

- [ ] **Step 3: Implement `hooks/learn-capture.sh`**

```bash
#!/usr/bin/env bash
# Stop hook (subsystem B feed). Drops a lightweight breadcrumb describing the
# just-finished turn into the active profile's curator/inbox/. The daemon (B)
# consumes these. MUST never fail the session: always exits 0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/paths.sh"

input="$(cat 2>/dev/null || true)"
name="$(resolve_active_profile)"
inbox="$(profile_dir "$name")/curator/inbox"
mkdir -p "$inbox" 2>/dev/null || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo "")"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
fname="$inbox/${ts}-${session_id}-$$.json"

jq -n --arg ts "$ts" --arg sid "$session_id" --arg tp "$transcript" \
      --arg cwd "$cwd" --arg prof "$name" \
  '{kind:"turn", captured_at:$ts, profile:$prof, session_id:$sid, transcript_path:$tp, cwd:$cwd}' \
  > "$fname" 2>/dev/null || true

exit 0
```

- [ ] **Step 4: Run, verify it passes**

Run: `chmod +x hooks/learn-capture.sh && bash tests/learn_capture_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add hooks/learn-capture.sh tests/learn_capture_test.sh
git commit -m "feat: add learn-capture Stop hook (curator inbox feed)"
```

---

## Task 6: Static machinery files (templates, command, skill placeholders)

**Files:**
- Create: `templates/persona.md`, `commands/profile.md`, `skills/codex-implement/SKILL.md`, `skills/learn/SKILL.md`

No test of its own — these are content files consumed by Task 7's `create` test and Task 10's `install` test. Verified there.

- [ ] **Step 1: Create `templates/persona.md`**

```markdown
# {{PROFILE_NAME}} Profile

> One-line identity: describe who this profile is and what it's for.

You are operating in the **{{PROFILE_NAME}}** profile. This file is your
persona and operating contract — Claude Code loads it as global instructions
whenever this profile is active.

## Identity
- (Describe the role/voice/expertise this profile embodies.)

## Operating style
- (Describe defaults: verbosity, autonomy, dev-process expectations.)

## Dev process
- Claude reasons / brainstorms / plans; codex implements (see `/codex-implement`).

## Notes
- Memories and learned skills accrue under this profile only.
```

- [ ] **Step 2: Create `commands/profile.md`**

```markdown
---
description: Manage Claude Code profiles (list, show, status, create, archive, switch, doctor)
argument-hint: <subcommand> [name]
allowed-tools: Bash
---

Run the profile-system management script and present its output to the user verbatim,
then add a one-line interpretation if helpful.

Execute:

!`bash ~/.claude/profile-system/profile_mgmt.sh $ARGUMENTS`

If `$ARGUMENTS` is empty, run `list`. For `switch`, remember mid-session switching
is impossible — surface the printed `ccp <name>` command so the user can relaunch.
```

- [ ] **Step 3: Create `skills/codex-implement/SKILL.md` (placeholder for subsystem C)**

```markdown
---
name: codex-implement
description: PLACEHOLDER (subsystem C). Will dispatch codex to implement a planned change — auto-selecting one-shot `codex exec` vs resumable `codex resume`, running in a git worktree, then auto-verifying the diff. Not yet implemented.
---

This is a placeholder so the shared-machinery symlink target exists. Subsystem C
(spec: codex dev-process dispatch) implements the real behavior. Until then, do
not invoke; tell the user codex dispatch is not yet wired.
```

- [ ] **Step 4: Create `skills/learn/SKILL.md` (placeholder for subsystem B)**

```markdown
---
name: learn
description: PLACEHOLDER (subsystem B). Will let the main session deliberately flag a learning candidate (memory or skill) into the curator inbox for background curation. Not yet implemented.
---

Placeholder for the shared-machinery symlink target. Subsystem B (self-improvement
learning daemon) implements the real behavior.
```

- [ ] **Step 5: Commit**

```bash
git add templates/ commands/ skills/
git commit -m "feat: add persona template, /profile command, machinery skill placeholders"
```

---

## Task 7: `profile_mgmt.sh` — `create`

**Files:**
- Create: `profile_mgmt.sh`
- Test: `tests/profile_mgmt_create_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/profile_mgmt_create_test.sh`:

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

out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work 2>&1)"; rc=$?
assert_eq "$rc" "0" "create succeeds"
P="$CC_PROFILE_ROOT/profiles/work"
assert_file "$P/CLAUDE.md" "persona created"
assert_contains "$(cat "$P/CLAUDE.md")" "work Profile" "persona name substituted"
assert_file "$P/settings.json" "settings created"
assert_eq "$(jq -r '.enabledPlugins["superpowers@official"]' "$P/settings.json")" "true" "inherited plugins"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | any(test("profile-wakeup"))' "$P/settings.json")" "true" "wakeup hook registered"
assert_eq "$(jq '[.hooks.Stop[].hooks[].command] | any(test("learn-capture"))' "$P/settings.json")" "true" "stop hook registered"
assert_file "$P/.curator_state" "curator state created"
assert_eq "$(jq -r '.run_count' "$P/.curator_state")" "0" "curator state init"
assert_symlink "$P/plugins" "plugins symlinked"
assert_symlink "$P/commands/profile.md" "command symlinked"
[ -d "$P/skills" ] && assert_eq dir dir "skills dir" || assert_eq nodir dir "skills dir missing"
[ -d "$P/curator/inbox" ] && assert_eq ok ok "inbox dir" || assert_eq no ok "inbox missing"

# duplicate create fails
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "duplicate create fails"

# reserved names fail
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create default >/dev/null 2>&1; r1=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create _shared >/dev/null 2>&1; r2=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create "bad/name" >/dev/null 2>&1; r3=$?
set -e 2>/dev/null || true
assert_eq "$r1" "1" "reserved: default"
assert_eq "$r2" "1" "reserved: _shared"
assert_eq "$r3" "1" "invalid: slash"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/profile_mgmt_create_test.sh`
Expected: FAIL — `profile_mgmt.sh` missing.

- [ ] **Step 3: Implement `profile_mgmt.sh` (create + dispatcher)**

```bash
#!/usr/bin/env bash
# profile_mgmt.sh — profile lifecycle. Backs the /profile command.
# Subcommands: create | list | show | status | archive | switch | doctor
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/paths.sh"
source "$HERE/lib/jsonutil.sh"

die() { echo "profile: $*" >&2; exit 1; }

valid_name() {
  case "$1" in
    ""|default|_shared) return 1 ;;
    */*|*' '*) return 1 ;;
    *) return 0 ;;
  esac
}

cmd_create() {
  local name="${1:-}"
  valid_name "$name" || die "invalid or reserved profile name: '${name}'"
  local P; P="$(profile_dir "$name")"
  [ -e "$P" ] && die "profile '$name' already exists at $P"

  local shared; shared="$(shared_dir)"
  mkdir -p "$P/skills" "$P/agents" "$P/projects" "$P/curator/inbox" "$P/commands"

  # persona from template, with {{PROFILE_NAME}} substituted
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
        }' "$def_settings" > "$P/settings.json"
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

  echo "Created profile '$name' at $P"
  echo "Activate it with:  ccp $name"
}

main() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    create)  cmd_create "$@" ;;
    list|show|status|archive|switch|doctor)
             die "subcommand '$sub' not implemented yet" ;;   # Tasks 8-9
    *)       die "unknown subcommand: $sub" ;;
  esac
}
main "$@"
```

- [ ] **Step 4: Run, verify it passes**

Run: `chmod +x profile_mgmt.sh && bash tests/profile_mgmt_create_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add profile_mgmt.sh tests/profile_mgmt_create_test.sh
git commit -m "feat: profile_mgmt create (scaffold profile + inherit plugins + hooks)"
```

---

## Task 8: `profile_mgmt.sh` — `list` / `show` / `status`

**Files:**
- Modify: `profile_mgmt.sh` (add `cmd_list`, `cmd_show`, `cmd_status`; wire into `main`)
- Test: `tests/profile_mgmt_query_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/profile_mgmt_query_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
MGMT="$PS_REPO_ROOT/profile_mgmt.sh"

mkdir -p "$CC_PROFILE_ROOT/profiles/_shared/templates"
ln -sfn "$PS_REPO_ROOT/templates" "$CC_PROFILE_ROOT/profiles/_shared/templates"
ln -sfn "$PS_REPO_ROOT/hooks"    "$CC_PROFILE_ROOT/profiles/_shared/hooks"
ln -sfn "$PS_REPO_ROOT/commands" "$CC_PROFILE_ROOT/profiles/_shared/commands"
ln -sfn "$PS_REPO_ROOT/skills"   "$CC_PROFILE_ROOT/profiles/_shared/skills"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work >/dev/null 2>&1
echo "work" > "$CC_PROFILE_ROOT/active_profile"

# list: shows default + work, marks active
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" list)"
assert_contains "$out" "default" "list shows default"
assert_contains "$out" "work" "list shows work"
assert_contains "$out" "*" "active marker present"

# show: persona + counts
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" show work)"
assert_contains "$out" "work" "show names profile"
assert_contains "$out" "Skills" "show lists skills count"

# status: curator state of work
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" status work)"
assert_contains "$out" "paused" "status shows paused flag"
assert_contains "$out" "run_count" "status shows run_count"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/profile_mgmt_query_test.sh`
Expected: FAIL — `subcommand 'list' not implemented yet`.

- [ ] **Step 3: Implement the three functions; update `main`**

Add these functions to `profile_mgmt.sh` (before `main`):

```bash
cmd_list() {
  local active="default"
  [ -f "$(cc_root)/active_profile" ] && active="$(cat "$(cc_root)/active_profile")"
  local mark
  mark=$([ "$active" = "default" ] && echo " *" || echo "")
  echo "Profiles (* = active):"
  echo "  default${mark}   $(cc_root)"
  if [ -d "$(profiles_dir)" ]; then
    local d nm
    for d in "$(profiles_dir)"/*/; do
      [ -d "$d" ] || continue
      nm="$(basename "$d")"
      [ "$nm" = "_shared" ] && continue
      mark=$([ "$active" = "$nm" ] && echo " *" || echo "")
      echo "  ${nm}${mark}   ${d%/}"
    done
  fi
}

cmd_show() {
  local name="${1:-default}"
  profile_exists "$name" || die "no such profile: $name"
  local P; P="$(profile_dir "$name")"
  local persona="(none)"
  [ -f "$P/CLAUDE.md" ] && persona="$(grep -m1 -E '^[^[:space:]]' "$P/CLAUDE.md" | sed 's/^#\+ *//')"
  local skills=0 mems=0
  [ -d "$P/skills" ]   && skills="$(find "$P/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [ -d "$P/projects" ] && mems="$(find "$P/projects" -type d -name memory 2>/dev/null | wc -l | tr -d ' ')"
  echo "Profile: $name"
  echo "  Path:    $P"
  echo "  Persona: $persona"
  echo "  Skills:  $skills learned"
  echo "  Memory:  $mems project memory store(s)"
  echo "  Plugins symlink: $([ -L "$P/plugins" ] && echo ok || ([ "$name" = default ] && echo "n/a (default owns real dir)" || echo BROKEN))"
}

cmd_status() {
  local name="${1:-$(resolve_active_profile)}"
  profile_exists "$name" || die "no such profile: $name"
  local state; state="$(profile_dir "$name")/.curator_state"
  echo "Curator status for '$name':"
  if [ -f "$state" ]; then jq '.' "$state"; else echo "  (no .curator_state yet)"; fi
}
```

Update `main`'s case so these dispatch (replace the combined not-implemented line):

```bash
    list)    cmd_list "$@" ;;
    show)    cmd_show "$@" ;;
    status)  cmd_status "$@" ;;
    archive|switch|doctor)
             die "subcommand '$sub' not implemented yet" ;;   # Task 9
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/profile_mgmt_query_test.sh`
Expected: `(N checks, 0 failed)`, exit 0. Also re-run `bash tests/profile_mgmt_create_test.sh` to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add profile_mgmt.sh tests/profile_mgmt_query_test.sh
git commit -m "feat: profile_mgmt list/show/status"
```

---

## Task 9: `profile_mgmt.sh` — `archive` / `switch` / `doctor`

**Files:**
- Modify: `profile_mgmt.sh` (add `cmd_archive`, `cmd_switch`, `cmd_doctor`; wire into `main`)
- Test: `tests/profile_mgmt_lifecycle_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/profile_mgmt_lifecycle_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
MGMT="$PS_REPO_ROOT/profile_mgmt.sh"

mkdir -p "$CC_PROFILE_ROOT/profiles/_shared"
ln -sfn "$PS_REPO_ROOT/templates" "$CC_PROFILE_ROOT/profiles/_shared/templates"
ln -sfn "$PS_REPO_ROOT/hooks"    "$CC_PROFILE_ROOT/profiles/_shared/hooks"
ln -sfn "$PS_REPO_ROOT/commands" "$CC_PROFILE_ROOT/profiles/_shared/commands"
ln -sfn "$PS_REPO_ROOT/skills"   "$CC_PROFILE_ROOT/profiles/_shared/skills"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work >/dev/null 2>&1

# switch: prints the ccp command, does not move anything
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" switch work)"
assert_contains "$out" "ccp work" "switch prints ccp command"

# doctor: repairs a deliberately broken plugins symlink
rm -f "$CC_PROFILE_ROOT/profiles/work/plugins"
ln -sfn "/nonexistent/target" "$CC_PROFILE_ROOT/profiles/work/plugins"
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" doctor work 2>&1)"
assert_contains "$out" "repair" "doctor reports a repair"
# after doctor, plugins symlink resolves to cc_root/plugins
assert_eq "$(readlink "$CC_PROFILE_ROOT/profiles/work/plugins")" "$CC_PROFILE_ROOT/plugins" "plugins relinked"

# archive: moves to profiles/.archived/work, never deletes
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" archive work 2>&1)"; rc=$?
assert_eq "$rc" "0" "archive succeeds"
[ -d "$CC_PROFILE_ROOT/profiles/work" ] && assert_eq present absent "work should be moved" || assert_eq absent absent "work moved"
assert_file "$CC_PROFILE_ROOT/profiles/.archived/work/CLAUDE.md" "archived copy exists"

# archiving default is refused
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" archive default >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "cannot archive default"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/profile_mgmt_lifecycle_test.sh`
Expected: FAIL — `subcommand 'switch' not implemented yet`.

- [ ] **Step 3: Implement the three functions; update `main`**

Add to `profile_mgmt.sh` (before `main`):

```bash
cmd_switch() {
  local name="${1:-}"; [ -n "$name" ] || die "usage: switch <name>"
  if [ "$name" != "default" ]; then profile_exists "$name" || die "no such profile: $name"; fi
  echo "Profiles can't switch mid-session (CLAUDE_CONFIG_DIR is read at launch)."
  echo "Relaunch into '$name' with:"
  echo "    ccp $name"
}

cmd_doctor() {
  local name="${1:-$(resolve_active_profile)}"
  profile_exists "$name" || die "no such profile: $name"
  local P; P="$(profile_dir "$name")" repaired=0
  if [ "$name" = "default" ]; then
    echo "doctor: '$name' is the default profile (owns real plugins/hooks; nothing to relink)."
  else
    local want_plugins; want_plugins="$(cc_root)/plugins"
    if [ ! -e "$P/plugins" ] || [ "$(readlink "$P/plugins" 2>/dev/null)" != "$want_plugins" ] || [ ! -d "$P/plugins/" ]; then
      ln -sfn "$want_plugins" "$P/plugins"; echo "  repair: relinked plugins -> $want_plugins"; repaired=1
    fi
    local want_hooks; want_hooks="$(shared_dir)/hooks"
    if [ ! -e "$P/hooks" ] || [ "$(readlink "$P/hooks" 2>/dev/null)" != "$want_hooks" ]; then
      ln -sfn "$want_hooks" "$P/hooks"; echo "  repair: relinked hooks -> $want_hooks"; repaired=1
    fi
  fi
  [ "$repaired" -eq 0 ] && echo "doctor: '$name' healthy."
}

cmd_archive() {
  local name="${1:-}"; [ -n "$name" ] || die "usage: archive <name>"
  [ "$name" = "default" ] && die "refusing to archive the default profile"
  profile_exists "$name" || die "no such profile: $name"
  local P; P="$(profile_dir "$name")"
  local adir; adir="$(profiles_dir)/.archived"
  mkdir -p "$adir"
  [ -e "$adir/$name" ] && die "an archived '$name' already exists at $adir/$name"
  mv "$P" "$adir/$name"
  echo "Archived '$name' -> $adir/$name (recoverable; not deleted)."
}
```

Update `main`'s case (replace the Task-9 not-implemented line):

```bash
    archive) cmd_archive "$@" ;;
    switch)  cmd_switch "$@" ;;
    doctor)  cmd_doctor "$@" ;;
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/profile_mgmt_lifecycle_test.sh`
Expected: `(N checks, 0 failed)`, exit 0. Re-run `bash tests/run.sh` to confirm all green.

- [ ] **Step 5: Commit**

```bash
git add profile_mgmt.sh tests/profile_mgmt_lifecycle_test.sh
git commit -m "feat: profile_mgmt archive/switch/doctor"
```

---

## Task 10: `install.sh` — wire repo + adopt default profile

**Files:**
- Create: `install.sh`
- Test: `tests/install_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/install_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
INSTALL="$PS_REPO_ROOT/install.sh"

# Seed a realistic default settings.json with an EXISTING hook to prove additivity.
cat > "$CC_PROFILE_ROOT/settings.json" <<'JSON'
{ "enabledPlugins": {"superpowers@official": true},
  "hooks": {"SessionStart": [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/role-wakeup.sh"}]}]} }
JSON

CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" 2>&1
rc=$?
assert_eq "$rc" "0" "install succeeds"

# _shared populated (symlinks into repo)
assert_symlink "$CC_PROFILE_ROOT/profiles/_shared/hooks" "_shared/hooks"
assert_symlink "$CC_PROFILE_ROOT/profiles/_shared/commands" "_shared/commands"

# default profile adopted additively
assert_file "$CC_PROFILE_ROOT/.curator_state" "default curator state"
[ -d "$CC_PROFILE_ROOT/curator/inbox" ] && assert_eq ok ok "default inbox" || assert_eq no ok "inbox missing"
# existing role-wakeup hook preserved
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | any(test("role-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "role-wakeup preserved"
# profile hooks added
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | any(test("profile-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "profile-wakeup added"
assert_eq "$(jq '[.hooks.Stop[].hooks[].command] | any(test("learn-capture"))' "$CC_PROFILE_ROOT/settings.json")" "true" "learn-capture added"
# existing plugins preserved
assert_eq "$(jq -r '.enabledPlugins["superpowers@official"]' "$CC_PROFILE_ROOT/settings.json")" "true" "plugins preserved"
# machinery command symlinked into default
assert_symlink "$CC_PROFILE_ROOT/commands/profile.md" "default /profile command"
# settings backup created
ls "$CC_PROFILE_ROOT"/settings.json.bak.* >/dev/null 2>&1 && assert_eq ok ok "settings backed up" || assert_eq no ok "no backup"

# idempotent: second run does not duplicate hooks
CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(test("profile-wakeup"))) | length' "$CC_PROFILE_ROOT/settings.json")" "1" "no duplicate profile-wakeup on rerun"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/install_test.sh`
Expected: FAIL — `install.sh` missing.

- [ ] **Step 3: Implement `install.sh`**

```bash
#!/usr/bin/env bash
# install.sh — wire this repo into the live Claude Code config and adopt the
# default profile (~/.claude) into the profile structure, additively.
# Idempotent. Honors CC_PROFILE_ROOT (tests) and CCP_SKIP_PATH (skip PATH symlink).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SRC/lib/paths.sh"
source "$SRC/lib/jsonutil.sh"

ROOT="$(cc_root)"
SHARED="$(shared_dir)"

echo "Installing profile-system into: $ROOT"
mkdir -p "$SHARED" "$ROOT/profiles" "$ROOT/curator/inbox" "$ROOT/commands"

# 1. _shared/* -> repo/* (so repo edits propagate to runtime)
ln -sfn "$SRC/hooks"     "$SHARED/hooks"
ln -sfn "$SRC/commands"  "$SHARED/commands"
ln -sfn "$SRC/skills"    "$SHARED/skills"
ln -sfn "$SRC/templates" "$SHARED/templates"

# 2. Adopt default profile: curator state (idempotent)
js_init_curator_state "$ROOT/.curator_state"

# 3. Back up settings.json, then additively register the two profile hooks.
if [ -f "$ROOT/settings.json" ]; then
  cp "$ROOT/settings.json" "$ROOT/settings.json.bak.$(date -u +%Y%m%d%H%M%S)"
else
  echo '{}' > "$ROOT/settings.json"
fi
js_merge_command_hook "$ROOT/settings.json" SessionStart "bash $SHARED/hooks/profile-wakeup.sh"
js_merge_command_hook "$ROOT/settings.json" Stop          "bash $SHARED/hooks/learn-capture.sh"

# 4. Machinery command + skills into the default profile (additive symlinks).
[ -f "$SHARED/commands/profile.md" ] && ln -sfn "$SHARED/commands/profile.md" "$ROOT/commands/profile.md"
mkdir -p "$ROOT/skills"
for s in "$SHARED/skills"/*/; do
  [ -d "$s" ] || continue
  ln -sfn "${s%/}" "$ROOT/skills/$(basename "$s")"
done

# 5. ccp onto PATH (skip in tests).
if [ "${CCP_SKIP_PATH:-0}" != "1" ]; then
  target="$HOME/.local/bin/ccp"
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$SRC/bin/ccp" "$target"
  echo "  Linked ccp -> $target (ensure ~/.local/bin is on PATH)"
fi

echo "Done. Default profile adopted. Create more with: /profile create <name>  (or  $SRC/profile_mgmt.sh create <name>)"
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/install_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install_test.sh
git commit -m "feat: idempotent installer + additive default-profile adoption"
```

---

## Task 11: End-to-end acceptance test + README + final commit

**Files:**
- Create: `tests/e2e_test.sh`, `README.md`

- [ ] **Step 1: Write the e2e test (maps spec §5 acceptance criteria, headless)**

Create `tests/e2e_test.sh`:

```bash
#!/usr/bin/env bash
# Exercises install -> create -> ccp(stub) -> wakeup against a sandbox.
# Covers spec §5 criteria reachable without launching real claude.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
fake="$(ps_make_fake_claude)"

# Seed default settings with an existing hook
cat > "$CC_PROFILE_ROOT/settings.json" <<'JSON'
{ "enabledPlugins": {"superpowers@official": true},
  "hooks": {"SessionStart":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/role-wakeup.sh"}]}]} }
JSON

# §A install + adopt
CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/install.sh" >/dev/null 2>&1

# §5.1 create scaffolds everything
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/profile_mgmt.sh" create demo >/dev/null 2>&1
assert_file "$CC_PROFILE_ROOT/profiles/demo/CLAUDE.md" "5.1 persona"
assert_symlink "$CC_PROFILE_ROOT/profiles/demo/plugins" "5.1 plugins link"

# §5.2 ccp sets env + active_profile
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CCP_CLAUDE_BIN="$fake" bash "$PS_REPO_ROOT/bin/ccp" demo)"
assert_contains "$out" "CLAUDE_CONFIG_DIR=$CC_PROFILE_ROOT/profiles/demo" "5.2 config dir"
assert_contains "$out" "CLAUDE_PROFILE=demo" "5.2 profile env"
assert_eq "$(cat "$CC_PROFILE_ROOT/active_profile")" "demo" "5.2 active_profile"

# §5.4 shared skills present in profile (placeholders resolve)
assert_symlink "$CC_PROFILE_ROOT/profiles/demo/skills/codex-implement" "5.4 codex-implement skill"

# §5.6 wakeup block correct for the profile
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=demo \
       CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/demo" bash "$PS_REPO_ROOT/hooks/profile-wakeup.sh")"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "PROFILE WAKEUP: demo" "5.6 wakeup header"
assert_contains "$ctx" "0 pending" "5.6 zero pending on fresh profile"

# §5.7 default profile additive: role-wakeup preserved, profile hooks added
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command]|any(test("role-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "5.7 role hook preserved"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command]|any(test("profile-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "5.7 profile hook added"

# §5.9 mismatch guard
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=demo \
       CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/WRONG" bash "$PS_REPO_ROOT/hooks/profile-wakeup.sh")"
assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" "PROFILE MISMATCH" "5.9 guard"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run the full suite**

Run: `bash tests/run.sh`
Expected: every `*_test.sh` reports `0 failed`; final line `=== 11/11 test files passed ===`, exit 0.

- [ ] **Step 3: Write `README.md`**

```markdown
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

## Use
```bash
ccp                     # default profile (~/.claude)
ccp work                # launch the 'work' profile
/profile create work    # scaffold a new profile (inside a session)
/profile list|show|status|doctor|archive|switch
```

## Test
```bash
bash tests/run.sh
```

See `docs/specs/2026-05-28-profile-layer-design.md` for the full design.
```

- [ ] **Step 4: Final full-suite run + commit**

Run: `bash tests/run.sh`
Expected: `=== 11/11 test files passed ===`.

```bash
git add tests/e2e_test.sh README.md
git commit -m "test: end-to-end acceptance suite + README"
```

---

## Self-Review

**Spec coverage (§ → task):**
- A.0 project home / install model → Task 10 (`install.sh`), README Task 11.
- A.1 layout → Tasks 6/7/10 (dirs + symlinks created and asserted).
- A.2 isolation (isolated reals vs shared symlinks; curator touches only profile `skills/`) → Task 7 create (symlinks) + Task 4 wakeup counts real dirs only.
- A.3 `ccp` activation (default unset, named set, missing errors, args forwarded, `active_profile` stamped) → Task 3.
- A.4 wakeup (profile resolution, status block, default included) → Task 4.
- A.5 `/profile` subcommands → Tasks 7/8/9 + command glue Task 6.
- A.6 persona via `CLAUDE.md` → Task 6 template + Task 7 substitution.
- A.7 safety: mismatch guard → Task 4; symlink self-heal → Task 4 (wakeup) + Task 9 (`doctor`); archive-not-delete → Task 9; additive adoption + settings backup → Task 10.
- A.8 lock convention — **GAP NOTED:** the spec mentions `.lock` files for memory/skill writes shared with the B daemon. Subsystem A does no concurrent writing (the daemon arrives in B), so no lock code is needed yet; B's plan owns it. Documented here so it isn't silently dropped.
- §5 acceptance #1–#9 → `tests/e2e_test.sh` (Task 11) maps each reachable criterion; #5 (keychain, no re-login) is a manual smoke item — see below.

**Manual smoke checklist (cannot be unit-tested headlessly):**
1. `bash install.sh` for real; open a new shell; `ccp` → confirm a normal session with a PROFILE WAKEUP: default block, role-wakeup still firing.
2. `/profile create scratch`; `ccp scratch`; confirm `echo $CLAUDE_CONFIG_DIR` = the scratch dir, no re-login prompt (keychain), plugins/skills available.
3. In the scratch session, save a memory; confirm it lands under `~/.claude/profiles/scratch/projects/.../memory/`, not under `~/.claude/projects/`.
4. `git -C ~/.claude/profile-system status` clean; remove the scratch profile with `/profile archive scratch`.

**Placeholder scan:** No "TBD/TODO/handle appropriately" in steps; every code step contains complete code; the `codex-implement`/`learn` SKILL.md files are intentional, labeled placeholders for subsystems C/B (out of scope per spec §6), not plan placeholders.

**Type/name consistency:** function names are stable across tasks — `cc_root`, `profiles_dir`, `shared_dir`, `profile_dir`, `profile_exists`, `resolve_active_profile`, `expected_config_dir` (paths.sh); `js_init_curator_state`, `js_get`, `js_merge_command_hook` (jsonutil.sh); `cmd_create/list/show/status/switch/doctor/archive` (profile_mgmt.sh). Env contract stable: `CC_PROFILE_ROOT` (test root override), `CCP_CLAUDE_BIN` (ccp test stub), `CCP_SKIP_PATH` (install test). The fragile `source` block in Task 4 Step 3 is explicitly corrected to the simple 3-line form in the same step.

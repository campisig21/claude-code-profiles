# Codex Dev-Process Dispatch (Subsystem C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build subsystem C — a deterministic, unit-tested bash engine (`codex_dispatch.sh` + `lib/dispatch.sh`) that hands implementation work to `codex` in a git worktree per dispatch, auto-verifies the result, and lands only on Claude's explicit approval — plus the rigid `codex-implement` skill and `/codex-implement` command that drive it.

**Architecture:** A pure-bash engine operates on the **current working repo** (not the profile). `lib/dispatch.sh` holds side-effect-free-ish helper functions (git context, sidecar JSON I/O, the single codex-invocation wrapper, check runner, diff/test-touch detection). `codex_dispatch.sh` is the CLI: `dispatch | quick | resume | show | land | abandon | list | doctor`. Per-dispatch state is a JSON sidecar under the target repo's git dir; worktrees live at a sibling path. **Faithful usage is enforced mechanically** — the engine refuses illegal state transitions and ends every command with an `ALLOWED NEXT ACTIONS` block — so the skill can stay a lean decision-table + checklist. Tests use a **fake `codex`** + a **sandbox git repo** in the existing dependency-free harness.

**Tech Stack:** bash (`#!/usr/bin/env bash`, `set -uo pipefail`), jq, git worktrees, macOS (`darwin`); the existing pure-bash test harness (no bats); `codex-cli 0.135.0`.

**Spec:** `docs/specs/2026-05-31-codex-dispatch-design.md` (decisions C1–C7, E1/E2; risks R1–R7).

**Branch:** `subsystem-c-codex-dispatch` (already created; the spec is committed there).

---

## File Structure

```
~/.claude/profile-system/
├── codex_dispatch.sh               # NEW — engine CLI (dispatch/quick/resume/show/land/abandon/list/doctor)
├── lib/dispatch.sh                 # NEW — helpers (git ctx, sidecar I/O, codex wrapper, checks, diff)
├── lib/jsonutil.sh                 # REUSED — js_get (sidecar field reads)
├── commands/codex-implement.md     # NEW — /codex-implement glue (full + --quick)
├── skills/codex-implement/SKILL.md # REPLACE placeholder — rigid decision-table + checklist skill
└── tests/
    ├── lib.sh                      # EXTEND — ps_make_fake_codex + ps_make_sandbox_repo
    ├── dispatch_lib_test.sh        # NEW — unit tests for lib/dispatch.sh helpers
    ├── dispatch_exec_test.sh       # NEW
    ├── dispatch_verify_test.sh     # NEW
    ├── dispatch_resume_test.sh     # NEW
    ├── dispatch_show_list_test.sh  # NEW
    ├── dispatch_land_test.sh       # NEW
    ├── dispatch_quick_test.sh      # NEW
    ├── dispatch_doctor_test.sh     # NEW
    └── dispatch_guardrails_test.sh # NEW — refusals + ALLOWED NEXT ACTIONS
```

**Responsibilities:**
- `lib/dispatch.sh` — *mechanism primitives.* Pure functions over git + JSON. No policy.
- `codex_dispatch.sh` — *the state machine + guardrails.* Composes primitives into the dispatch lifecycle; refuses illegal transitions; prints `ALLOWED NEXT ACTIONS`.
- `commands/codex-implement.md` / `skills/codex-implement/SKILL.md` — *judgment glue.* Tell Claude how to drive the engine; never re-implement engine logic.
- `tests/lib.sh` additions — *deterministic doubles.* Fake codex + sandbox repo so every path is unit-testable.

**Conventions used throughout:**
- The engine sources `lib/jsonutil.sh` then `lib/dispatch.sh` relative to its own dir.
- Tests override the codex binary with `CODEX_DISPATCH_CODEX_BIN` and the timestamp with `CODEX_DISPATCH_NOW` (for deterministic ids).
- `die() { echo "codex-dispatch: $*" >&2; exit 1; }` is the standard error exit.

---

## Task 0: Test-harness doubles (fake codex + sandbox repo)

**Files:**
- Modify: `tests/lib.sh` (append two functions)
- Create: `tests/dispatch_lib_test.sh` (smoke of the doubles only, for now)

- [ ] **Step 1: Append the doubles to `tests/lib.sh`**

Add to the end of `tests/lib.sh`:

```bash
# --- Subsystem C doubles -----------------------------------------------------

# A fake `codex` for engine tests. Honors: [exec [resume]] ... -C <dir> -o <file> --json
# and `--version`. Behavior controlled by FAKE_CODEX_BEHAVIOR=pass|fail|weaken-tests.
# Writes a sentinel file IMPL in the -C dir: "ok" passes the sandbox check, "bad" fails.
# `exec resume` always writes "ok" (models a fix on retry). Echoes path to the fake.
ps_make_fake_codex() {
  local p="$PS_SANDBOX/fake-codex"
  cat > "$p" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
# --version short-circuit
for a in "$@"; do case "$a" in --version|-V) echo "fake-codex 0.0.0"; exit 0;; esac; done
is_resume=0
for a in "$@"; do case "$a" in resume) is_resume=1;; esac; done
cdir="." ; outfile="" ; json=0
while [ $# -gt 0 ]; do
  case "$1" in
    -C|--cd) cdir="$2"; shift 2;;
    -o|--output-last-message) outfile="$2"; shift 2;;
    --json) json=1; shift;;
    *) shift;;
  esac
done
behavior="${FAKE_CODEX_BEHAVIOR:-pass}"
if [ "$is_resume" = "1" ]; then
  printf 'ok\n' > "$cdir/IMPL"; msg="resumed: applied fix"
else
  case "$behavior" in
    pass)         printf 'ok\n'  > "$cdir/IMPL"; msg="implemented (pass)";;
    fail)         printf 'bad\n' > "$cdir/IMPL"; msg="implemented (fail)";;
    weaken-tests) printf 'ok\n'  > "$cdir/IMPL"
                  mkdir -p "$cdir/tests"; printf '# weakened\n' >> "$cdir/tests/some_test.sh"
                  msg="implemented (weakened tests)";;
    *)            printf 'ok\n'  > "$cdir/IMPL"; msg="implemented";;
  esac
fi
[ -n "$outfile" ] && printf '%s\n' "$msg" > "$outfile"
[ "$json" = "1" ] && printf '{"type":"session.created","session_id":"fake-sess-0001"}\n'
exit 0
SH
  chmod +x "$p"
  printf '%s\n' "$p"
}

# Create a sandbox git repo INSIDE PS_SANDBOX (so teardown removes it + sibling
# worktrees). Seeds a commit and a check script `check.sh` that passes iff IMPL=ok.
# Echoes the repo path.
ps_make_sandbox_repo() {
  local repo="$PS_SANDBOX/${1:-repo}"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name  "Test"
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  cat > "$repo/check.sh" <<'CHK'
#!/usr/bin/env bash
# Passes iff IMPL exists and contains "ok".
[ -f IMPL ] && grep -q ok IMPL
CHK
  chmod +x "$repo/check.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed"
  printf '%s\n' "$repo"
}
```

- [ ] **Step 2: Write a smoke test for the doubles**

Create `tests/dispatch_lib_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox

fake="$(ps_make_fake_codex)"
assert_file "$fake" "fake codex created"
assert_eq "$("$fake" --version)" "fake-codex 0.0.0" "fake codex --version"

repo="$(ps_make_sandbox_repo)"
assert_file "$repo/check.sh" "sandbox repo has check.sh"
assert_eq "$(git -C "$repo" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; echo $?)" "0" "sandbox repo is a git repo"

# fake exec writes IMPL=ok into -C dir; check passes
"$fake" exec -C "$repo" -o "$PS_SANDBOX/last.txt" --json >/dev/null
assert_eq "$(cat "$repo/IMPL")" "ok" "fake exec wrote IMPL=ok"
assert_eq "$(cd "$repo" && bash check.sh; echo $?)" "0" "check passes on ok"

# fail behavior makes the check fail
FAKE_CODEX_BEHAVIOR=fail "$fake" exec -C "$repo" >/dev/null
assert_eq "$(cd "$repo" && bash check.sh; echo $?)" "1" "check fails on bad"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 3: Run, verify it passes**

Run: `bash tests/dispatch_lib_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add tests/lib.sh tests/dispatch_lib_test.sh
git commit -m "test: add fake-codex + sandbox-repo doubles for subsystem C"
```

---

## Task 1: `lib/dispatch.sh` — git context + sidecar I/O

**Files:**
- Create: `lib/dispatch.sh`
- Modify: `tests/dispatch_lib_test.sh` (append helper assertions)

- [ ] **Step 1: Append failing assertions to `tests/dispatch_lib_test.sh`**

Insert these lines immediately before `ps_teardown_sandbox` in `tests/dispatch_lib_test.sh`:

```bash
# --- lib/dispatch.sh helpers ---
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch.sh"

# identity helpers
assert_eq "$(d_slugify 'Fix the Auth Bug!!')" "fix-the-auth-bug" "slugify"
assert_eq "$(CODEX_DISPATCH_NOW=20260531T120000Z d_now)" "20260531T120000Z" "d_now honors override"
assert_eq "$(d_short abc | wc -c | tr -d ' ')" "7" "d_short is 6 chars + newline"

# git context (run inside the sandbox repo)
( cd "$repo"
  assert_eq "$(d_in_git_repo; echo $?)" "0" "in git repo"
  assert_eq "$(d_repo_root)" "$repo" "repo root"
  assert_eq "$(d_worktree_root)" "$(dirname "$repo")/.codex-dispatch-worktrees/$(basename "$repo")" "worktree root sibling"
  assert_contains "$(d_sidecar_dir)" "/codex-dispatch" "sidecar dir under git dir"
)

# sidecar I/O
( cd "$repo"
  mkdir -p "$(d_sidecar_dir)"
  echo '{"id":"x1","status":"running","retry_budget":2}' > "$(d_sidecar_path x1)"
  assert_eq "$(d_sc_get x1 '.status')" "running" "sc_get status"
  assert_eq "$(d_sc_get x1 '.retry_budget')" "2" "sc_get number"
  d_sc_set x1 '.status=$s|.updated_at=$u' --arg s needs_review --arg u 20260531T130000Z
  assert_eq "$(d_sc_get x1 '.status')" "needs_review" "sc_set status"
  assert_eq "$(d_sc_get x1 '.updated_at')" "20260531T130000Z" "sc_set updated_at"
  assert_eq "$(d_sidecar_exists x1; echo $?)" "0" "sidecar exists"
  assert_eq "$(d_sidecar_exists nope; echo $?)" "1" "missing sidecar"
  assert_eq "$(d_list_ids)" "x1" "list ids"
)
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/dispatch_lib_test.sh`
Expected: FAIL — `lib/dispatch.sh: No such file or directory`.

- [ ] **Step 3: Create `lib/dispatch.sh` (part 1)**

```bash
#!/usr/bin/env bash
# lib/dispatch.sh — primitives for the codex dispatch engine. SOURCE this.
# Operates on the CURRENT working repo (cwd), independent of the profile root.
# Depends on lib/jsonutil.sh (js_get) being sourced first.

# --- identity ---------------------------------------------------------------
d_now()     { printf '%s\n' "${CODEX_DISPATCH_NOW:-$(date -u +%Y%m%dT%H%M%SZ)}"; }
d_slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
                | sed -E 's/^-+//; s/-+$//' | cut -c1-32; }
d_short()   { printf '%s' "$1" | cksum | tr -d ' ' | cut -c1-6; }

# --- git context (operate on cwd's repo) ------------------------------------
d_in_git_repo() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
d_repo_root()   { git rev-parse --show-toplevel; }
d_git_dir()     { git rev-parse --absolute-git-dir; }
d_tree_dirty()  { [ -n "$(git status --porcelain 2>/dev/null)" ]; }
d_cur_branch()  { git rev-parse --abbrev-ref HEAD; }
d_head_sha()    { git rev-parse HEAD; }

d_worktree_root() {
  local repo; repo="$(d_repo_root)"
  printf '%s\n' "$(dirname "$repo")/.codex-dispatch-worktrees/$(basename "$repo")"
}
d_sidecar_dir()  { printf '%s\n' "$(d_git_dir)/codex-dispatch"; }
d_sidecar_path() { printf '%s\n' "$(d_sidecar_dir)/$1.json"; }
d_sidecar_exists() { [ -f "$(d_sidecar_path "$1")" ]; }

# --- sidecar JSON I/O -------------------------------------------------------
# d_sc_get <id> <jq-filter>  -> field (empty if null/missing)
d_sc_get() { js_get "$(d_sidecar_path "$1")" "$2"; }

# d_sc_set <id> <jq-filter> [jq args...]  -> apply filter in place
d_sc_set() {
  local id="$1" filter="$2"; shift 2
  local p t; p="$(d_sidecar_path "$id")"; t="$(mktemp)"
  jq "$@" "$filter" "$p" > "$t" && mv "$t" "$p"
}

# d_list_ids -> one id per line (no sidecars => no output)
d_list_ids() {
  local dir f; dir="$(d_sidecar_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do [ -e "$f" ] || continue; basename "$f" .json; done
}
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/dispatch_lib_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/dispatch.sh tests/dispatch_lib_test.sh
git commit -m "feat: lib/dispatch.sh git-context + sidecar I/O helpers"
```

---

## Task 2: `lib/dispatch.sh` — codex wrapper, checks, diff/test-touch

**Files:**
- Modify: `lib/dispatch.sh` (append part 2)
- Modify: `tests/dispatch_lib_test.sh` (append assertions)

- [ ] **Step 1: Append failing assertions to `tests/dispatch_lib_test.sh`**

Insert before `ps_teardown_sandbox` (after the Task 1 block):

```bash
# --- codex wrapper + checks + diff helpers ---
( cd "$repo"
  # session id parsing from a captured stream
  echo '{"type":"session.created","session_id":"fake-sess-0001"}' > "$PS_SANDBOX/stream.json"
  assert_eq "$(d_codex_session_id "$PS_SANDBOX/stream.json")" "fake-sess-0001" "session id parsed"
  assert_eq "$(d_codex_session_id /no/file)" "" "missing stream -> empty"

  # run a passing + failing check, capture JSON
  printf 'ok\n' > IMPL
  d_run_checks "$repo" "bash check.sh"; rc=$?
  assert_eq "$rc" "0" "checks pass when IMPL=ok"
  assert_eq "$(printf '%s' "$D_CHECKS_JSON" | jq -r '.[0].exit')" "0" "check exit recorded"
  printf 'bad\n' > IMPL
  d_run_checks "$repo" "bash check.sh"; rc=$?
  assert_eq "$rc" "1" "checks fail when IMPL=bad"

  # test-touch detection
  printf 'src/app.js\nREADME.md\n' | d_touches_tests; assert_eq "$?" "1" "no test files -> 1"
  printf 'src/app.js\ntests/run.sh\n' | d_touches_tests; assert_eq "$?" "0" "tests/ path -> 0"
  printf 'foo_test.go\n' | d_touches_tests; assert_eq "$?" "0" "_test. suffix -> 0"
)
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/dispatch_lib_test.sh`
Expected: FAIL — `d_codex_session_id: command not found` (or similar).

- [ ] **Step 3: Append part 2 to `lib/dispatch.sh`**

```bash
# --- codex invocation (the ONLY place codex is called — see spec R4) --------
# d_codex_exec <worktree> <lastmsg_file> <prompt>  -> echoes captured session id
d_codex_exec() {
  local wt="$1" lastmsg="$2" prompt="$3"
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}" stream
  stream="$(mktemp)"
  "$bin" exec --dangerously-bypass-approvals-and-sandbox --json \
         -C "$wt" -o "$lastmsg" "$prompt" > "$stream" 2>&1 || true
  d_codex_session_id "$stream"
  rm -f "$stream"
}

# d_codex_resume <worktree> <session_id|""> <prompt>
# Primary path: `--last -C <wt>` (cwd-scoped, schema-independent). Uses an
# explicit session id when one was captured.
d_codex_resume() {
  local wt="$1" session="$2" prompt="$3"
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}"
  if [ -n "$session" ]; then
    "$bin" exec resume "$session" --dangerously-bypass-approvals-and-sandbox \
           -C "$wt" "$prompt" >/dev/null 2>&1 || true
  else
    "$bin" exec resume --last --dangerously-bypass-approvals-and-sandbox \
           -C "$wt" "$prompt" >/dev/null 2>&1 || true
  fi
}

# d_codex_session_id <stream-file>  -> best-effort session id (empty if none)
d_codex_session_id() {
  local stream="$1"
  [ -f "$stream" ] || { printf '\n'; return 0; }
  grep -o '"session_id":"[^"]*"' "$stream" 2>/dev/null \
    | head -1 | sed 's/.*:"//; s/"$//'
}

# --- checks -----------------------------------------------------------------
# d_run_checks <worktree> <cmd>...  -> sets D_CHECKS_JSON; returns 0 iff all pass.
D_CHECKS_JSON='[]'
d_run_checks() {
  local wt="$1"; shift
  local overall=0 c out code tail entries='[]'
  for c in "$@"; do
    [ -n "$c" ] || continue
    out="$(cd "$wt" && bash -c "$c" 2>&1)"; code=$?
    tail="$(printf '%s\n' "$out" | tail -n 20)"
    entries="$(printf '%s' "$entries" \
      | jq --arg c "$c" --argjson e "$code" --arg t "$tail" \
           '. + [{cmd:$c, exit:$e, output_tail:$t}]')"
    [ "$code" -ne 0 ] && overall=1
  done
  D_CHECKS_JSON="$entries"
  return "$overall"
}

# --- worktree commit + diff -------------------------------------------------
# d_commit_worktree <wt> <msg>  -> commits all changes; 0 if a commit was made, 1 if none.
d_commit_worktree() {
  local wt="$1" msg="$2"
  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet; then return 1; fi
  git -C "$wt" commit -q -m "$msg"
}

d_changed_files() { git -C "$1" diff --name-only "$2"..HEAD; }
d_diffstat()      { git -C "$1" diff --stat       "$2"..HEAD; }
d_full_diff()     { git -C "$1" diff              "$2"..HEAD; }

# d_touches_tests  (reads file list on stdin) -> 0 if any path looks like a test
d_touches_tests() {
  grep -Eiq '(^|/)(tests?|__tests__|spec)(/|$)|_test\.|\.test\.|_spec\.|\.spec\.'
}
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/dispatch_lib_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/dispatch.sh tests/dispatch_lib_test.sh
git commit -m "feat: lib/dispatch.sh codex wrapper + checks + diff helpers"
```

---

## Task 3: `codex_dispatch.sh` — `dispatch` (exec + verify, no retry)

**Files:**
- Create: `codex_dispatch.sh`
- Create: `tests/dispatch_exec_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/dispatch_exec_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"

# A passing dispatch with verify=checks stops at needs_review, prints diffstat
# (NOT the full diff) + ALLOWED NEXT ACTIONS, and records a session id.
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug fix-auth "do the thing" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "dispatch exits 0"
assert_contains "$out" "needs_review" "reaches needs_review"
assert_contains "$out" "ALLOWED NEXT ACTIONS" "next-actions block present"
assert_contains "$out" "IMPL" "diffstat names the changed file (IMPL is new)"
# full diff content (the +ok line) must NOT be dumped by default
case "$out" in *"+ok"*) echo "  FAIL: full diff leaked into default output"; exit 1;; esac

id="20260531T120000Z-fix-auth"
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_sc_get "$id" '.status')" "needs_review" "sidecar status"
  assert_eq "$(d_sc_get "$id" '.verify')" "checks" "sidecar verify mode"
  assert_eq "$(d_sc_get "$id" '.session_id')" "fake-sess-0001" "session id captured"
  assert_eq "$(d_sc_get "$id" '.checks[0].exit')" "0" "check recorded passing"
  wt="$(d_sc_get "$id" '.worktree')"
  assert_file "$wt/IMPL" "worktree has codex's change"
)
# dispatch outside a git repo is refused
out="$( cd "$PS_SANDBOX" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" dispatch --check 'true' "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "refuses outside git repo"
assert_contains "$out" "git repository" "explains why"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/dispatch_exec_test.sh`
Expected: FAIL — `codex_dispatch.sh: No such file or directory`.

- [ ] **Step 3: Create `codex_dispatch.sh` (dispatcher + `cmd_dispatch`, no retry yet)**

```bash
#!/usr/bin/env bash
# codex_dispatch.sh — the codex dev-process dispatch engine (subsystem C).
# Claude is the policy-maker; this engine is a deterministic mechanism.
# Commands: dispatch | quick | resume | show | land | abandon | list | doctor
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/jsonutil.sh"
source "$HERE/lib/dispatch.sh"

die() { echo "codex-dispatch: $*" >&2; exit 1; }

# Print the ALLOWED NEXT ACTIONS block for a dispatch in a given status.
emit_next_actions() {
  local id="$1" status="$2" verify="$3"
  echo
  echo "ALLOWED NEXT ACTIONS (pick exactly one):"
  case "$status" in
    needs_review)
      [ "$verify" != checks ] && echo "  codex_dispatch.sh show $id --diff      # review the diff"
      echo "  codex_dispatch.sh land $id            # after review/checks pass"
      echo "  codex_dispatch.sh resume $id \"<fb>\"    # send fixes to codex"
      echo "  codex_dispatch.sh abandon $id          # discard"
      ;;
    failed)
      echo "  codex_dispatch.sh show $id --diff      # inspect"
      echo "  codex_dispatch.sh resume $id \"<fb>\"    # retry with guidance"
      echo "  codex_dispatch.sh abandon $id          # discard"
      ;;
    landed|abandoned)
      echo "  (none — dispatch $status)"
      ;;
  esac
}

# Print the standard result summary for a dispatch id (diffstat by default).
emit_result() {
  local id="$1"
  local status verify branch wt base touches
  status="$(d_sc_get "$id" '.status')"
  verify="$(d_sc_get "$id" '.verify')"
  branch="$(d_sc_get "$id" '.branch')"
  wt="$(d_sc_get "$id" '.worktree')"
  base="$(d_sc_get "$id" '.base_ref')"
  touches="$(d_sc_get "$id" '.touches_tests')"
  echo "Dispatch $id"
  echo "  status:   $status"
  echo "  verify:   $verify   retries_used: $(d_sc_get "$id" '.retries_used')/$(d_sc_get "$id" '.retry_budget')"
  echo "  branch:   $branch"
  echo "  worktree: $wt"
  echo "  codex:    $(d_sc_get "$id" '.codex_last_message')"
  [ "$touches" = "true" ] && echo "  ⚠ diff modifies tests — review recommended before landing"
  echo "  checks:"
  d_sc_get "$id" '.checks[] | "    [\(.exit)] \(.cmd)"' 2>/dev/null || true
  echo "  diffstat:"
  d_diffstat "$wt" "$base" | sed 's/^/    /'
  emit_next_actions "$id" "$status" "$verify"
}

cmd_dispatch() {
  local verify=both retry=1 slug=""
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify) verify="$2"; shift 2;;
      --check)  checks+=("$2"); shift 2;;
      --retry)  retry="$2"; shift 2;;
      --slug)   slug="$2"; shift 2;;
      --)       shift; break;;
      -*)       die "unknown flag: $1";;
      *)        break;;
    esac
  done
  local prompt="${1:-}"
  [ -n "$prompt" ] || die "dispatch requires a prompt"
  case "$verify" in checks|review|both) ;; *) die "invalid --verify: $verify (want checks|review|both)";; esac
  d_in_git_repo || die "not in a git repository — cd into the repo you want codex to work on"

  local repo base_ref id short branch wt
  repo="$(d_repo_root)"
  base_ref="$(d_head_sha)"
  [ -n "$slug" ] || slug="$(d_slugify "$prompt")"
  [ -n "$slug" ] || slug="dispatch"
  id="$(d_now)-$slug"
  short="$(d_short "$id")"
  branch="codex/$slug-$short"
  wt="$(d_worktree_root)/$id"

  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" && die "branch already exists: $branch"
  [ -e "$wt" ] && die "worktree path already exists: $wt"

  mkdir -p "$(d_sidecar_dir)" "$(d_worktree_root)"
  git -C "$repo" worktree add -q -b "$branch" "$wt" "$base_ref" \
    || die "failed to create worktree at $wt"

  # init sidecar
  local checks_json='[]'
  if [ "${#checks[@]}" -gt 0 ]; then
    checks_json="$(printf '%s\n' "${checks[@]}" | jq -R . | jq -s '.')"
  fi
  jq -n --arg id "$id" --arg now "$(d_now)" --arg repo "$repo" --arg wt "$wt" \
        --arg branch "$branch" --arg base "$base_ref" --arg verify "$verify" \
        --argjson retry "$retry" --argjson reqchecks "$checks_json" --arg prompt "$prompt" \
    '{id:$id, created_at:$now, updated_at:$now, repo:$repo, worktree:$wt, branch:$branch,
      base_ref:$base, verify:$verify, retry_budget:$retry, retries_used:0,
      requested_checks:$reqchecks, session_id:null, status:"running",
      checks:[], touches_tests:false, codex_last_message:null, prompt:$prompt}' \
    > "$(d_sidecar_path "$id")"

  # run codex (fresh exec)
  local lastmsg session
  lastmsg="$(mktemp)"
  session="$(d_codex_exec "$wt" "$lastmsg" "$prompt")"
  d_sc_set "$id" '.session_id=(if $s=="" then null else $s end)|.codex_last_message=$m|.updated_at=$u' \
    --arg s "$session" --arg m "$(cat "$lastmsg" 2>/dev/null)" --arg u "$(d_now)"
  rm -f "$lastmsg"

  # commit codex's work onto the dispatch branch
  d_commit_worktree "$wt" "codex: $slug (dispatch $id)" || true

  # touches-tests signal
  local touches=false
  if d_changed_files "$wt" "$base_ref" | d_touches_tests; then touches=true; fi
  d_sc_set "$id" '.touches_tests=$t' --argjson t "$touches"

  # verify
  finish_verify "$id" "$wt" "$verify" "$retry"
  emit_result "$id"
}

# finish_verify <id> <wt> <verify> <retry_budget> — runs checks (if applicable),
# sets terminal status (needs_review|failed). Retry loop added in Task 4.
finish_verify() {
  local id="$1" wt="$2" verify="$3" retry="$4"
  if [ "$verify" = review ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
    return 0
  fi
  d_sc_set "$id" '.status="verifying"|.updated_at=$u' --arg u "$(d_now)"
  local -a cmds=()
  while IFS= read -r line; do [ -n "$line" ] && cmds+=("$line"); done \
    < <(d_sc_get "$id" '.requested_checks[]')
  if [ "${#cmds[@]}" -eq 0 ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
    return 0
  fi
  d_run_checks "$wt" "${cmds[@]}"; local ok=$?
  d_sc_set "$id" '.checks=$c|.updated_at=$u' --argjson c "$D_CHECKS_JSON" --arg u "$(d_now)"
  if [ "$ok" -eq 0 ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
  else
    d_sc_set "$id" '.status="failed"|.updated_at=$u' --arg u "$(d_now)"
  fi
}

main() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    dispatch) cmd_dispatch "$@" ;;
    quick|resume|show|land|abandon|list|doctor)
              die "subcommand '$sub' not implemented yet" ;;   # Tasks 4-8
    *)        die "unknown subcommand: $sub" ;;
  esac
}
main "$@"
```

- [ ] **Step 4: Make executable + run test**

Run: `chmod +x codex_dispatch.sh && bash tests/dispatch_exec_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_exec_test.sh
git commit -m "feat: codex_dispatch dispatch (exec + verify, needs_review gate)"
```

---

## Task 4: `dispatch` retry loop + `resume` command

**Files:**
- Modify: `codex_dispatch.sh` (replace `finish_verify`; add `cmd_resume`; wire `resume` into `main`)
- Create: `tests/dispatch_verify_test.sh`, `tests/dispatch_resume_test.sh`

- [ ] **Step 1: Write the failing tests**

Create `tests/dispatch_verify_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# FAIL then retry: first exec writes IMPL=bad (check fails); with --retry 1 the
# engine resumes codex (which writes IMPL=ok) -> check passes -> needs_review.
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        FAKE_CODEX_BEHAVIOR=fail bash "$ENGINE" dispatch --verify checks \
        --check 'bash check.sh' --retry 1 --slug retry-me "x" 2>&1 )"
id="20260531T120000Z-retry-me"
( cd "$repo"
  assert_eq "$(d_sc_get "$id" '.status')" "needs_review" "recovered after retry"
  assert_eq "$(d_sc_get "$id" '.retries_used')" "1" "one retry used"
)

# Budget 0: failing check hands back as 'failed', worktree retained.
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260531T130000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        FAKE_CODEX_BEHAVIOR=fail bash "$ENGINE" dispatch --verify checks \
        --check 'bash check.sh' --retry 0 --slug no-retry "x" 2>&1 )"
id2="20260531T130000Z-no-retry"
( cd "$repo"
  assert_eq "$(d_sc_get "$id2" '.status')" "failed" "no-retry -> failed"
  wt="$(d_sc_get "$id2" '.worktree')"; assert_file "$wt/IMPL" "worktree retained on failure"
)
assert_contains "$out" "failed" "reports failed"

# weaken-tests behavior raises the touches_tests warning even in checks-only mode
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260531T140000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        FAKE_CODEX_BEHAVIOR=weaken-tests bash "$ENGINE" dispatch --verify checks \
        --check 'bash check.sh' --slug touchy "x" 2>&1 )"
assert_contains "$out" "modifies tests" "test-touch warning surfaced"

ps_teardown_sandbox
ps_report; exit $?
```

Create `tests/dispatch_resume_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# Land-less iteration: a failed dispatch can be resumed with feedback; resume
# re-verifies and (fake fixes on resume) reaches needs_review.
( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
   FAKE_CODEX_BEHAVIOR=fail bash "$ENGINE" dispatch --verify checks \
   --check 'bash check.sh' --retry 0 --slug iter "x" >/dev/null 2>&1 )
id="20260531T120000Z-iter"
( cd "$repo"; assert_eq "$(d_sc_get "$id" '.status')" "failed" "starts failed" )

out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" resume "$id" "please fix" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "resume exits 0"
( cd "$repo"
  assert_eq "$(d_sc_get "$id" '.status')" "needs_review" "resume re-verified to needs_review"
  assert_eq "$(d_sc_get "$id" '.retries_used')" "1" "resume counts as a retry use"
)
assert_contains "$out" "ALLOWED NEXT ACTIONS" "resume prints next actions"

# resume of unknown id errors with valid-id list
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" resume nope "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "unknown id refused"
assert_contains "$out" "$id" "lists valid ids"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify they fail**

Run: `bash tests/dispatch_verify_test.sh` then `bash tests/dispatch_resume_test.sh`
Expected: verify test FAILS (no retry → status stays `failed` where `needs_review` expected); resume test FAILS (`subcommand 'resume' not implemented yet`).

- [ ] **Step 3: Replace `finish_verify` with the retry loop, add `cmd_resume`, wire `main`**

Replace the entire `finish_verify` function in `codex_dispatch.sh` with:

```bash
# finish_verify <id> <wt> <verify> — runs checks with the dispatch's retry budget,
# self-correcting via codex resume on failure. Sets needs_review|failed.
finish_verify() {
  local id="$1" wt="$2" verify="$3"
  if [ "$verify" = review ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
    return 0
  fi
  local -a cmds=()
  while IFS= read -r line; do [ -n "$line" ] && cmds+=("$line"); done \
    < <(d_sc_get "$id" '.requested_checks[]')
  if [ "${#cmds[@]}" -eq 0 ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
    return 0
  fi

  local budget used session slug
  budget="$(d_sc_get "$id" '.retry_budget')"
  used="$(d_sc_get "$id" '.retries_used')"
  session="$(d_sc_get "$id" '.session_id')"
  slug="$(d_sc_get "$id" '.id')"

  while :; do
    d_sc_set "$id" '.status="verifying"|.updated_at=$u' --arg u "$(d_now)"
    d_run_checks "$wt" "${cmds[@]}"; local ok=$?
    d_sc_set "$id" '.checks=$c|.updated_at=$u' --argjson c "$D_CHECKS_JSON" --arg u "$(d_now)"
    if [ "$ok" -eq 0 ]; then
      d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
      return 0
    fi
    if [ "$used" -ge "$budget" ]; then
      d_sc_set "$id" '.status="failed"|.updated_at=$u' --arg u "$(d_now)"
      return 0
    fi
    # resume codex with the failure output, then re-verify
    local fb; fb="The checks failed. Output:
$(printf '%s' "$D_CHECKS_JSON" | jq -r '.[] | "$ \(.cmd)\n\(.output_tail)"')
Fix the code so all checks pass."
    d_codex_resume "$wt" "$session" "$fb"
    d_commit_worktree "$wt" "codex: resume fix ($slug)" || true
    used=$((used + 1))
    d_sc_set "$id" '.retries_used=$n|.updated_at=$u' --argjson n "$used" --arg u "$(d_now)"
  done
}

# cmd_resume <id> <feedback> — resume a dispatch's codex session with Claude
# feedback, re-commit, re-verify. Counts as one retry use.
cmd_resume() {
  local id="${1:-}" fb="${2:-}"
  [ -n "$id" ] || die "resume requires a dispatch id"
  [ -n "$fb" ] || die "resume requires a feedback prompt"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local status; status="$(d_sc_get "$id" '.status')"
  case "$status" in
    needs_review|failed) ;;
    *) die "cannot resume a dispatch in status '$status'";;
  esac
  local wt session used slug verify
  wt="$(d_sc_get "$id" '.worktree')"
  session="$(d_sc_get "$id" '.session_id')"
  used="$(d_sc_get "$id" '.retries_used')"
  slug="$(d_sc_get "$id" '.id')"
  verify="$(d_sc_get "$id" '.verify')"
  [ -d "$wt" ] || die "worktree missing for '$id' (run: codex_dispatch.sh doctor)"

  d_codex_resume "$wt" "$session" "$fb"
  d_commit_worktree "$wt" "codex: resume ($slug)" || true
  used=$((used + 1))
  d_sc_set "$id" '.retries_used=$n|.updated_at=$u' --argjson n "$used" --arg u "$(d_now)"

  local base; base="$(d_sc_get "$id" '.base_ref')"
  local touches=false
  if d_changed_files "$wt" "$base" | d_touches_tests; then touches=true; fi
  d_sc_set "$id" '.touches_tests=$t' --argjson t "$touches"

  finish_verify "$id" "$wt" "$verify"
  emit_result "$id"
}
```

Then update `main`'s case to wire `resume`:

```bash
    dispatch) cmd_dispatch "$@" ;;
    resume)   cmd_resume "$@" ;;
    quick|show|land|abandon|list|doctor)
              die "subcommand '$sub' not implemented yet" ;;   # Tasks 5-8
```

(Note: `cmd_dispatch` already calls `finish_verify "$id" "$wt" "$verify" "$retry"` — drop the now-unused 4th arg by changing that call to `finish_verify "$id" "$wt" "$verify"`.)

- [ ] **Step 4: Run, verify they pass**

Run: `bash tests/dispatch_verify_test.sh && bash tests/dispatch_resume_test.sh && bash tests/dispatch_exec_test.sh`
Expected: all `(N checks, 0 failed)`, exit 0 (exec test still green — the call-site arg change is backward compatible).

- [ ] **Step 5: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_verify_test.sh tests/dispatch_resume_test.sh
git commit -m "feat: codex_dispatch retry loop + resume command"
```

---

## Task 5: `show` (diffstat + `--diff`) and `list`

**Files:**
- Modify: `codex_dispatch.sh` (add `cmd_show`, `cmd_list`; wire `main`)
- Create: `tests/dispatch_show_list_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/dispatch_show_list_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"

( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
   bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug showme "x" >/dev/null 2>&1 )
id="20260531T120000Z-showme"

# show: diffstat by default, NO full diff
out="$( cd "$repo" && bash "$ENGINE" show "$id" 2>&1 )"
assert_contains "$out" "needs_review" "show prints status"
assert_contains "$out" "diffstat" "show has diffstat"
case "$out" in *"+ok"*) echo "  FAIL: show leaked full diff without --diff"; exit 1;; esac

# show --diff: full diff present
out="$( cd "$repo" && bash "$ENGINE" show "$id" --diff 2>&1 )"
assert_contains "$out" "+ok" "show --diff includes the full diff"

# list: shows the dispatch with id + status
out="$( cd "$repo" && bash "$ENGINE" list 2>&1 )"
assert_contains "$out" "$id" "list shows id"
assert_contains "$out" "needs_review" "list shows status"

# show unknown id errors
out="$( cd "$repo" && bash "$ENGINE" show nope 2>&1 )"; rc=$?
assert_eq "$rc" "1" "show unknown id errors"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/dispatch_show_list_test.sh`
Expected: FAIL — `subcommand 'show' not implemented yet`.

- [ ] **Step 3: Add `cmd_show` and `cmd_list`; wire `main`**

Add to `codex_dispatch.sh` (before `main`):

```bash
cmd_show() {
  local id="" want_diff=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --diff) want_diff=1; shift;;
      -*) die "unknown flag: $1";;
      *) id="$1"; shift;;
    esac
  done
  [ -n "$id" ] || die "show requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  emit_result "$id"
  if [ "$want_diff" -eq 1 ]; then
    local wt base; wt="$(d_sc_get "$id" '.worktree')"; base="$(d_sc_get "$id" '.base_ref')"
    echo
    echo "FULL DIFF ($id):"
    if [ -d "$wt" ]; then d_full_diff "$wt" "$base"; else echo "  (worktree gone)"; fi
  fi
}

cmd_list() {
  d_in_git_repo || die "not in a git repository"
  local ids; ids="$(d_list_ids)"
  if [ -z "$ids" ]; then echo "No dispatches for this repo."; return 0; fi
  echo "Dispatches (this repo):"
  printf '  %-26s %-13s %-8s %s\n' "ID" "STATUS" "VERIFY" "BRANCH"
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '  %-26s %-13s %-8s %s\n' \
      "$id" "$(d_sc_get "$id" '.status')" "$(d_sc_get "$id" '.verify')" "$(d_sc_get "$id" '.branch')"
  done <<< "$ids"
}
```

Update `main`:

```bash
    dispatch) cmd_dispatch "$@" ;;
    resume)   cmd_resume "$@" ;;
    show)     cmd_show "$@" ;;
    list)     cmd_list "$@" ;;
    quick|land|abandon|doctor)
              die "subcommand '$sub' not implemented yet" ;;   # Tasks 6-8
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/dispatch_show_list_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_show_list_test.sh
git commit -m "feat: codex_dispatch show (diffstat + --diff) and list"
```

---

## Task 6: `land` (rebase+merge, guardrails, conflict abort) + `abandon`

**Files:**
- Modify: `codex_dispatch.sh` (add `cmd_land`, `cmd_abandon`; wire `main`)
- Create: `tests/dispatch_land_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/dispatch_land_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# Each scenario gets its own sandbox repo so landed IMPL files never couple them.
# disp <repo> <ts> <slug> <behavior> <retry> <verify> [check-cmd]
disp() {
  local r="$1" ts="$2" slug="$3" beh="$4" retry="$5" verify="$6" chk="${7:-}"
  local args=(dispatch --verify "$verify" --retry "$retry" --slug "$slug")
  [ -n "$chk" ] && args+=(--check "$chk")
  ( cd "$r" && CODEX_DISPATCH_NOW="$ts" CODEX_DISPATCH_CODEX_BIN="$fake" \
     FAKE_CODEX_BEHAVIOR="$beh" bash "$ENGINE" "${args[@]}" "do x" >/dev/null 2>&1 )
}

# --- happy path: land a passing checks dispatch ---
ro="$(ps_make_sandbox_repo ok)"
disp "$ro" 20260531T120000Z land-ok pass 1 checks 'bash check.sh'
id="20260531T120000Z-land-ok"
out="$( cd "$ro" && bash "$ENGINE" land "$id" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "land succeeds"
assert_eq "$(cat "$ro/IMPL")" "ok" "change landed in working tree"
( cd "$ro"; assert_eq "$(d_sc_get "$id" '.status')" "landed" "status landed" )
wt="$( cd "$ro"; d_sc_get "$id" '.worktree' )"
[ -d "$wt" ] && { echo "  FAIL: worktree not removed after land"; exit 1; }

# --- guardrail: cannot land a failed dispatch (fail + retry 0 => failed) ---
rf="$(ps_make_sandbox_repo fail)"
disp "$rf" 20260531T121000Z land-bad fail 0 checks 'bash check.sh'
id2="20260531T121000Z-land-bad"
( cd "$rf"; assert_eq "$(d_sc_get "$id2" '.status')" "failed" "precondition: failed" )
out="$( cd "$rf" && bash "$ENGINE" land "$id2" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "refuses to land failed dispatch"
assert_contains "$out" "status" "explains status gate"

# --- guardrail: review-only land needs --reviewed ---
rr="$(ps_make_sandbox_repo rev)"
disp "$rr" 20260531T122000Z land-rev pass 0 review
id3="20260531T122000Z-land-rev"
out="$( cd "$rr" && bash "$ENGINE" land "$id3" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "review-only land without --reviewed refused"
assert_contains "$out" "reviewed" "explains --reviewed requirement"
out="$( cd "$rr" && bash "$ENGINE" land "$id3" --reviewed 2>&1 )"; rc=$?
assert_eq "$rc" "0" "review-only land with --reviewed succeeds"

# --- conflict: base lacks IMPL; the working branch advances with a different IMPL ---
rconf="$(ps_make_sandbox_repo conf)"
disp "$rconf" 20260531T123000Z land-conf pass 1 checks 'bash check.sh'
id4="20260531T123000Z-land-conf"
printf 'conflict\n' > "$rconf/IMPL"; git -C "$rconf" add IMPL; git -C "$rconf" commit -q -m "conflicting"
out="$( cd "$rconf" && bash "$ENGINE" land "$id4" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "land refuses on rebase conflict"
assert_contains "$out" "conflict" "reports conflict"
( cd "$rconf"; assert_eq "$(d_sc_get "$id4" '.status')" "needs_review" "stays needs_review on conflict" )
wt4="$( cd "$rconf"; d_sc_get "$id4" '.worktree' )"; assert_file "$wt4/IMPL" "worktree retained on conflict"

# --- abandon removes worktree + branch ---
out="$( cd "$rconf" && bash "$ENGINE" abandon "$id4" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "abandon succeeds"
( cd "$rconf"; assert_eq "$(d_sc_get "$id4" '.status')" "abandoned" "status abandoned" )
[ -d "$wt4" ] && { echo "  FAIL: abandon left worktree"; exit 1; }

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/dispatch_land_test.sh`
Expected: FAIL — `subcommand 'land' not implemented yet`.

- [ ] **Step 3: Add `cmd_land` and `cmd_abandon`; wire `main`**

Add to `codex_dispatch.sh` (before `main`):

```bash
# verification_satisfied <id> <verify> <reviewed-flag> — 0 if landing is allowed.
verification_satisfied() {
  local id="$1" verify="$2" reviewed="$3"
  case "$verify" in
    checks|both)
      # every recorded check must have exited 0, and there must be at least one
      local n bad
      n="$(d_sc_get "$id" '.checks | length')"; [ "${n:-0}" -ge 1 ] || return 1
      bad="$(d_sc_get "$id" '[.checks[] | select(.exit != 0)] | length')"
      [ "${bad:-0}" -eq 0 ] || return 1
      ;;
  esac
  case "$verify" in
    review|both) [ "$reviewed" -eq 1 ] || { [ "$verify" = both ] && return 0; return 1; } ;;
  esac
  return 0
}

cmd_land() {
  local id="" reviewed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reviewed) reviewed=1; shift;;
      -*) die "unknown flag: $1";;
      *) id="$1"; shift;;
    esac
  done
  [ -n "$id" ] || die "land requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local status verify branch wt base repo
  status="$(d_sc_get "$id" '.status')"
  verify="$(d_sc_get "$id" '.verify')"
  branch="$(d_sc_get "$id" '.branch')"
  wt="$(d_sc_get "$id" '.worktree')"
  base="$(d_sc_get "$id" '.base_ref')"
  repo="$(d_repo_root)"

  [ "$status" = needs_review ] || die "cannot land: status is '$status' (need needs_review)"
  if ! verification_satisfied "$id" "$verify" "$reviewed"; then
    case "$verify" in
      review|both) die "verify=$verify requires confirming your review: pass --reviewed to land $id";;
      *)           die "checks did not all pass — resume or abandon $id";;
    esac
  fi
  [ -d "$wt" ] || die "worktree missing for '$id' (run: codex_dispatch.sh doctor)"

  # rebase the dispatch branch onto current HEAD inside the worktree (R1/flag #2)
  local cur; cur="$(d_head_sha)"
  if ! git -C "$wt" rebase "$cur" >/dev/null 2>&1; then
    git -C "$wt" rebase --abort >/dev/null 2>&1 || true
    d_sc_set "$id" '.updated_at=$u' --arg u "$(d_now)"   # status stays needs_review
    echo "codex-dispatch: land aborted — rebase conflict against current HEAD." >&2
    echo "codex-dispatch: worktree kept at $wt; resolve, then resume/land, or abandon $id." >&2
    return 1
  fi
  # re-run checks post-rebase for checks modes
  case "$verify" in
    checks|both)
      local -a cmds=()
      while IFS= read -r line; do [ -n "$line" ] && cmds+=("$line"); done \
        < <(d_sc_get "$id" '.requested_checks[]')
      if [ "${#cmds[@]}" -gt 0 ]; then
        d_run_checks "$wt" "${cmds[@]}" || die "checks failed after rebase — resume or abandon $id"
        d_sc_set "$id" '.checks=$c' --argjson c "$D_CHECKS_JSON"
      fi
      ;;
  esac

  # fast-forward merge into the working branch, then clean up
  git -C "$repo" merge --ff-only "$branch" >/dev/null 2>&1 \
    || die "merge failed unexpectedly for $branch"
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  d_sc_set "$id" '.status="landed"|.updated_at=$u' --arg u "$(d_now)"
  echo "Landed $id onto $(d_cur_branch) (branch $branch merged, worktree removed)."
}

cmd_abandon() {
  local id="${1:-}"
  [ -n "$id" ] || die "abandon requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local wt branch repo; wt="$(d_sc_get "$id" '.worktree')"; branch="$(d_sc_get "$id" '.branch')"
  repo="$(d_repo_root)"
  [ -d "$wt" ] && git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  d_sc_set "$id" '.status="abandoned"|.updated_at=$u' --arg u "$(d_now)"
  echo "Abandoned $id (worktree + branch removed)."
}
```

Update `main`:

```bash
    dispatch) cmd_dispatch "$@" ;;
    resume)   cmd_resume "$@" ;;
    show)     cmd_show "$@" ;;
    list)     cmd_list "$@" ;;
    land)     cmd_land "$@" ;;
    abandon)  cmd_abandon "$@" ;;
    quick|doctor)
              die "subcommand '$sub' not implemented yet" ;;   # Tasks 7-8
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/dispatch_land_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

> Note on the conflict case: the dispatch branch and the working branch both modify `IMPL`. Rebasing the dispatch branch onto the working branch's conflicting commit produces a real rebase conflict, which the engine aborts and reports. ✓

- [ ] **Step 5: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_land_test.sh
git commit -m "feat: codex_dispatch land (rebase+merge, guardrails, conflict abort) + abandon"
```

---

## Task 7: `quick` (clean-tree-or-snapshot, in-place)

**Files:**
- Modify: `codex_dispatch.sh` (add `cmd_quick`; wire `main`)
- Create: `tests/dispatch_quick_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/dispatch_quick_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# clean tree: quick edits in place, reports diff, creates NO worktree/branch/sidecar
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" quick "small fix" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "quick succeeds on clean tree"
assert_eq "$(cat "$repo/IMPL")" "ok" "quick wrote change in place"
assert_contains "$out" "+ok" "quick reports the diff"
( cd "$repo"
  assert_eq "$(d_list_ids | wc -l | tr -d ' ')" "0" "quick made no sidecar"
  assert_eq "$(git worktree list | wc -l | tr -d ' ')" "1" "quick made no extra worktree"
)

# dirty tree without --snapshot is refused
printf 'dirty\n' >> "$repo/README.md"
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" quick "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "quick refuses dirty tree"
assert_contains "$out" "snapshot" "suggests --snapshot"

# dirty tree WITH --snapshot proceeds and reports a restore point
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" quick --snapshot "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "quick --snapshot proceeds on dirty tree"
assert_contains "$out" "snapshot" "reports a restore point"

# quick with a failing check reports the failure (no auto-retry, no land step)
git -C "$repo" checkout -- README.md 2>/dev/null || true; rm -f "$repo/IMPL"
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_BEHAVIOR=fail \
        bash "$ENGINE" quick --verify checks --check 'bash check.sh' "x" 2>&1 )"; rc=$?
assert_contains "$out" "FAIL" "quick surfaces failing check"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/dispatch_quick_test.sh`
Expected: FAIL — `subcommand 'quick' not implemented yet`.

- [ ] **Step 3: Add `cmd_quick`; wire `main`**

Add to `codex_dispatch.sh` (before `main`):

```bash
# quick: run codex in the CURRENT working tree (no worktree/branch/sidecar).
# Refuses a dirty tree unless --snapshot, which records a restore point first.
cmd_quick() {
  local verify=none snapshot=0
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify)   verify="$2"; shift 2;;
      --check)    checks+=("$2"); shift 2;;
      --snapshot) snapshot=1; shift;;
      --) shift; break;;
      -*) die "unknown flag: $1";;
      *) break;;
    esac
  done
  local prompt="${1:-}"
  [ -n "$prompt" ] || die "quick requires a prompt"
  case "$verify" in none|checks|review|both) ;; *) die "invalid --verify: $verify";; esac
  d_in_git_repo || die "not in a git repository"
  local repo; repo="$(d_repo_root)"

  if d_tree_dirty; then
    if [ "$snapshot" -eq 0 ]; then
      die "working tree is dirty — commit/stash first, or pass --snapshot to record a restore point"
    fi
    local snap; snap="$(git -C "$repo" stash create "codex-quick snapshot $(d_now)")"
    if [ -n "$snap" ]; then
      git -C "$repo" update-ref "refs/codex-dispatch-snapshots/$(d_now)" "$snap"
      echo "Recorded snapshot $snap — restore with:  git stash apply $snap"
    fi
  fi

  local lastmsg session; lastmsg="$(mktemp)"
  session="$(d_codex_exec "$repo" "$lastmsg" "$prompt")"
  echo "codex: $(cat "$lastmsg" 2>/dev/null)"
  rm -f "$lastmsg"

  if [ "$verify" != none ] && [ "$verify" != review ] && [ "${#checks[@]}" -gt 0 ]; then
    if d_run_checks "$repo" "${checks[@]}"; then
      echo "checks: PASS"
    else
      echo "checks: FAIL"
      printf '%s' "$D_CHECKS_JSON" | jq -r '.[] | "  [\(.exit)] \(.cmd)\n\(.output_tail)"'
    fi
  fi

  echo
  echo "DIFF (in-place, not committed):"
  git -C "$repo" --no-pager diff
  echo
  echo "Quick edits are in your working tree. Review, then commit or revert yourself."
  echo "Iterate with:  codex exec resume --last -C $repo \"<feedback>\""
}
```

Update `main` (replace the `quick|doctor` not-implemented line):

```bash
    quick)    cmd_quick "$@" ;;
    doctor)   die "subcommand '$sub' not implemented yet" ;;   # Task 8
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/dispatch_quick_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_quick_test.sh
git commit -m "feat: codex_dispatch quick (in-place, clean-tree-or-snapshot)"
```

---

## Task 8: `doctor` (reconcile sidecars + codex version)

**Files:**
- Modify: `codex_dispatch.sh` (add `cmd_doctor`; wire `main`)
- Create: `tests/dispatch_doctor_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/dispatch_doctor_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# Active dispatch (worktree exists) is reported healthy.
( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
   bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug healthy "x" >/dev/null 2>&1 )
ok_id="20260531T120000Z-healthy"

# Orphan sidecar: status needs_review but the worktree was deleted out-of-band.
( cd "$repo"
  cp "$(d_sidecar_path "$ok_id")" "$(d_sidecar_path 20260531T999999Z-orphan)"
  jq '.id="20260531T999999Z-orphan"|.worktree="/tmp/does-not-exist-xyz"' \
     "$(d_sidecar_path 20260531T999999Z-orphan)" > "$PS_SANDBOX/o.json" \
     && mv "$PS_SANDBOX/o.json" "$(d_sidecar_path 20260531T999999Z-orphan)"
)

out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" doctor 2>&1 )"; rc=$?
assert_eq "$rc" "0" "doctor exits 0"
assert_contains "$out" "orphan" "doctor flags the orphan dispatch"
assert_contains "$out" "fake-codex 0.0.0" "doctor reports codex version"
# orphan reconciled to status=lost
( cd "$repo"; assert_eq "$(d_sc_get 20260531T999999Z-orphan '.status')" "lost" "orphan marked lost" )
# healthy dispatch untouched
( cd "$repo"; assert_eq "$(d_sc_get "$ok_id" '.status')" "needs_review" "healthy untouched" )

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/dispatch_doctor_test.sh`
Expected: FAIL — `subcommand 'doctor' not implemented yet`.

- [ ] **Step 3: Add `cmd_doctor`; wire `main`**

Add to `codex_dispatch.sh` (before `main`):

```bash
# doctor: reconcile sidecars against reality, prune nothing destructively but mark
# orphans (worktree gone while still 'active'), and report the codex version.
cmd_doctor() {
  d_in_git_repo || die "not in a git repository"
  echo "codex-dispatch doctor"
  local ver; ver="$(${CODEX_DISPATCH_CODEX_BIN:-codex} --version 2>/dev/null || echo 'codex: NOT FOUND')"
  echo "  codex version: $ver"
  local ids; ids="$(d_list_ids)"
  if [ -z "$ids" ]; then echo "  no dispatches."; return 0; fi
  local id status wt
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    status="$(d_sc_get "$id" '.status')"
    wt="$(d_sc_get "$id" '.worktree')"
    case "$status" in
      running|verifying|needs_review|failed)
        if [ ! -d "$wt" ]; then
          d_sc_set "$id" '.status="lost"|.updated_at=$u' --arg u "$(d_now)"
          echo "  ⚠ $id: worktree missing → marked 'lost' (orphan reconciled)"
        else
          echo "  ok $id ($status)"
        fi
        ;;
      landed|abandoned|lost) echo "  ok $id ($status)";;
      *) echo "  ? $id (unknown status '$status')";;
    esac
  done <<< "$ids"
  # prune git's worktree admin for any dirs we removed
  git worktree prune >/dev/null 2>&1 || true
}
```

Update `main` (replace the `doctor` not-implemented line):

```bash
    doctor)   cmd_doctor "$@" ;;
```

- [ ] **Step 4: Run, verify it passes**

Run: `bash tests/dispatch_doctor_test.sh`
Expected: `(N checks, 0 failed)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_doctor_test.sh
git commit -m "feat: codex_dispatch doctor (reconcile sidecars + codex version)"
```

---

## Task 9: Consolidated guardrails test

**Files:**
- Create: `tests/dispatch_guardrails_test.sh`

This task adds no engine code — it locks the faithful-usage guarantees (spec §4.4) against regression in one place. If any assertion fails, fix the engine, not the test.

- [ ] **Step 1: Write the guardrails test**

Create `tests/dispatch_guardrails_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

run() { ( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" "$@" 2>&1 ); }

# dispatch outside a repo
o="$( cd "$PS_SANDBOX" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" dispatch --check true "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "dispatch refused outside repo"

# invalid verify mode
o="$(run dispatch --verify bogus "x")"; rc=$?
assert_eq "$rc" "1" "invalid verify refused"

# unknown id across commands
for c in show land resume abandon; do
  o="$(run "$c" ghost ${c:+x})"; rc=$?
  assert_eq "$rc" "1" "$c unknown id refused"
done

# every terminal-state command prints ALLOWED NEXT ACTIONS
( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
   bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug g "x" >/dev/null 2>&1 )
id="20260531T120000Z-g"
assert_contains "$(run show "$id")" "ALLOWED NEXT ACTIONS" "show emits next actions"

# land refused on wrong status (force-set to running)
( cd "$repo"; d_sc_set "$id" '.status="running"' )
o="$(run land "$id")"; rc=$?
assert_eq "$rc" "1" "land refused on running status"
( cd "$repo"; d_sc_set "$id" '.status="needs_review"' )   # restore

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run, verify it passes**

Run: `bash tests/dispatch_guardrails_test.sh`
Expected: `(N checks, 0 failed)`, exit 0. (All guardrails were built in Tasks 3–8; this only asserts them.) If anything fails, fix `codex_dispatch.sh`.

- [ ] **Step 3: Commit**

```bash
git add tests/dispatch_guardrails_test.sh
git commit -m "test: consolidated faithful-usage guardrail assertions"
```

---

## Task 10: The `codex-implement` skill + `/codex-implement` command

**Files:**
- Modify: `skills/codex-implement/SKILL.md` (replace the placeholder)
- Create: `commands/codex-implement.md`

These are content files (judgment glue). They are exercised by Task 11's full-suite run and by the manual smoke checklist; they have no unit test of their own.

- [ ] **Step 1: Replace `skills/codex-implement/SKILL.md`**

```markdown
---
name: codex-implement
description: Dispatch implementation work to codex in a git worktree, auto-verify it, and land it on your approval. Use when you (Claude) have planned a change and it's time to implement — a plan task, a whole plan, a focused change, or a trivial in-place edit. Wraps codex exec/resume with verification and Claude-gated merge.
---

# codex-implement

You (the main session) are the **policy-maker**. `codex_dispatch.sh` is a deterministic
engine that does the mechanical work and **refuses unsafe sequences**. Never run raw
`git worktree` / `git merge` / `codex` yourself — always go through the engine. The one
exception: `codex exec resume --last` for iterating on a `--quick` edit.

Engine path: `~/.claude/profile-system/codex_dispatch.sh` (a profile symlinks it via
shared machinery). Run it from inside the repo codex should work on.

## 1. Decide the shape (decision table)

| Situation | Command |
|---|---|
| Fresh task / plan / focused change | `dispatch` |
| Iterating on an existing dispatch (your feedback or a failure) | `resume <id> "<fb>"` |
| Trivial edit, isolation is overkill | `quick` (add `--snapshot` if the tree is dirty) |

| Task impact | `--verify` | `--retry` |
|---|---|---|
| High impact / risky / touches many files | `both` (default) | `0` (hand failures back to you) |
| Medium | `both` or `checks` | `1` |
| Low / mechanical | `checks` | `1`–`2` |
| No meaningful tests | `review` | `0` |

Granularity is your call (one task vs. a whole plan) — the engine treats them identically.

## 2. Dispatch

```
codex_dispatch.sh dispatch --verify <checks|review|both> --check '<cmd>' [--check '<cmd2>'] \
  --retry <N> --slug <short-label> "<prompt for codex>"
```
- Pass the **verify commands** the planned work should satisfy (e.g. `--check 'bash tests/run.sh'`).
- Write a **complete, self-contained prompt**: what to build, where, and the definition of done.

## 3. Read the result, then take EXACTLY ONE next action

The engine prints a summary + an `ALLOWED NEXT ACTIONS` block. Follow it.
- If `verify` includes `review` (i.e. `both`/`review`): run `codex_dispatch.sh show <id> --diff`
  and **actually review the diff** before landing. Watch for weakened/deleted tests
  (the engine also flags `⚠ diff modifies tests`).
- Then exactly one of:
  - `codex_dispatch.sh land <id>` — review/checks pass. (Add `--reviewed` for `review`-only.)
  - `codex_dispatch.sh resume <id> "<feedback>"` — send fixes to codex; re-verifies.
  - `codex_dispatch.sh abandon <id>` — discard worktree + branch.
- On `failed` (retry budget exhausted): inspect, then `resume` or `abandon`. If you're unsure
  whether to keep spending retries, ask the user.

## 4. Quick (in-place) path

```
codex_dispatch.sh quick [--verify checks --check '<cmd>'] [--snapshot] "<prompt>"
```
Edits the current working tree directly (no worktree, no land step). Refuses a dirty tree
without `--snapshot`. Review the printed diff; commit or revert yourself.

## Red flags — STOP if you think any of these

| Thought | Reality |
|---|---|
| "I'll just `git merge`/`git worktree remove` this myself" | Use `land`/`abandon` — they run the rebase, re-verify, cleanup, and guardrails. |
| "Checks passed, I'll skip the diff review" | Only valid when `verify=checks`. For `both`/`review` you MUST `show --diff` and review. |
| "I'll run `codex exec` directly to implement this" | Go through `dispatch`/`quick` so it's isolated, verified, and tracked. |
| "I'll force the land of a failed/`running` dispatch" | The engine refuses it. Resume to fix, or abandon — don't try to route around it. |

> Governance: keep this table ≤7 rows, phrased by category. A misuse the engine can
> already refuse does NOT belong here — it belongs in the engine.

## Checklist (make a TodoWrite item per step)
- [ ] Pick command + `--verify`/`--retry` from the decision table
- [ ] `dispatch` (or `quick`) with explicit checks + a complete prompt
- [ ] Read the result + `ALLOWED NEXT ACTIONS`
- [ ] If review-mode: `show <id> --diff` and review
- [ ] Take exactly one of `land` / `resume` / `abandon`
```

- [ ] **Step 2: Create `commands/codex-implement.md`**

```markdown
---
description: Dispatch a change to codex (isolated, verified, Claude-gated) or --quick in place
argument-hint: [--quick] [--verify mode] [--check 'cmd'] "<task>"
allowed-tools: Bash, Read
---

Invoke the `codex-implement` skill and drive `~/.claude/profile-system/codex_dispatch.sh`
to implement the user's task with codex.

Arguments: `$ARGUMENTS`

- If `$ARGUMENTS` starts with `--quick`, use the engine's `quick` path (in-place, no worktree)
  — for trivial edits. Otherwise use the full isolated `dispatch` flow (worktree + verify +
  Claude-gated land).
- Choose `--verify`/`--retry` and the `--check` commands per the skill's decision table and
  the task's impact. Always read the result and the `ALLOWED NEXT ACTIONS` block, review the
  diff when the verify mode includes review, then land / resume / abandon.
- Never run raw git/codex yourself; always go through the engine.
```

- [ ] **Step 3: Sanity-check the skill frontmatter parses**

Run: `head -3 skills/codex-implement/SKILL.md` and confirm the `---` frontmatter with `name:` and `description:` is intact.
Expected: valid YAML frontmatter (the placeholder note is gone).

- [ ] **Step 4: Commit**

```bash
git add skills/codex-implement/SKILL.md commands/codex-implement.md
git commit -m "feat: real codex-implement skill (decision table + checklist) + /codex-implement command"
```

---

## Task 11: Full suite green + manual smoke checklist

**Files:**
- Create: `docs/smoke/2026-05-31-codex-dispatch-smoke.md`

- [ ] **Step 1: Run the entire test suite**

Run: `bash tests/run.sh`
Expected: every `*_test.sh` reports `0 failed`, final line `=== M/M test files passed ===`, exit 0. This includes **A's existing tests** (no regression) plus all `dispatch_*` files.

- [ ] **Step 2: Write the manual smoke checklist**

The fake codex proves the engine's orchestration, not real codex behavior. Create `docs/smoke/2026-05-31-codex-dispatch-smoke.md`:

```markdown
# Subsystem C — manual smoke checklist

Run once against the REAL `codex` in a throwaway git repo (these can't be unit-tested).

- [ ] In a scratch repo with a real test command, run:
      `~/.claude/profile-system/codex_dispatch.sh dispatch --verify checks --check '<real test cmd>' "<small real task>"`
      → a worktree is created, real `codex exec` runs (full-access), the check runs,
        and it stops at `needs_review` printing a diffstat (not the full diff).
- [ ] `codex_dispatch.sh show <id> --diff` shows codex's real diff.
- [ ] Force a failing check (or a task you know will fail once) with `--retry 1` and confirm
      a real `codex exec resume` continues the SAME session and fixes it.
- [ ] `codex_dispatch.sh land <id>` rebases, merges into the working branch, removes the worktree.
- [ ] `codex_dispatch.sh quick "<trivial task>"` edits the working tree in place; `--snapshot`
      works on a dirty tree.
- [ ] `codex_dispatch.sh doctor` reports the real codex version and reconciles a hand-deleted worktree.
- [ ] (Activation) After `bash ~/.claude/profile-system/install.sh`, the `codex-implement` skill
      and `/codex-implement` command resolve inside an active profile session.
```

- [ ] **Step 3: Commit**

```bash
git add docs/smoke/2026-05-31-codex-dispatch-smoke.md
git commit -m "docs: subsystem C manual smoke checklist; full suite green"
```

- [ ] **Step 4: (Optional) open a PR / merge to main**

Subsystem C lives on `subsystem-c-codex-dispatch`. When the suite is green and the smoke
checklist passes, merge to `main` (mirroring how A was merged), then run `install.sh` to
activate. Coordinate this with the user.

---

## Self-Review (completed by plan author)

**Spec coverage** — every spec section maps to a task:
- C1 flexible unit → Task 3/skill decision table (engine is unit-agnostic). ✓
- C2 verify modes (checks/review/both) → Tasks 3–4, `--verify`. ✓
- C3 Claude-gated merge / never auto-land → Task 3 (`finish_verify` only ever sets `needs_review`/`failed`) + Task 6 (`land` is a separate command). ✓
- C4 configurable retry budget, hands back when exhausted → Task 4 retry loop. ✓
- C5 full-access codex → Task 2 `d_codex_exec`/`d_codex_resume` flags. ✓
- C6 engine + skill split → whole plan. ✓
- C7 skill + `/codex-implement` (full + `--quick`) → Tasks 7, 10. ✓
- E1 diffstat-by-default, full diff on demand → Task 3 `emit_result`, Task 5 `show --diff`. ✓
- E2 lean decision-table skill + ALLOWED NEXT ACTIONS → Task 3 `emit_next_actions`, Task 10 skill. ✓
- Faithful-usage 3 layers → Task 3 (Layer 2 output), Tasks 6/9 (Layer 1 refusals), Task 10 (Layer 3 skill). ✓
- Flag #1 quick clean-tree/snapshot → Task 7. ✓
- Flag #2 land rebase+merge, conflict abort → Task 6. ✓
- Flag #3 touches_tests warning → Task 4/3. ✓
- Flag #4 codex isolation + `--last` resume → Task 2. ✓
- Flag #5 doctor reconcile → Task 8. ✓
- Sidecar schema → Task 3 init `jq -n`. ✓
- Testing approach (fake codex + sandbox repo) → Task 0; one test file per behavior. ✓

**Placeholder scan** — no TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type/name consistency** — helper names (`d_*`), sidecar fields (`status`, `verify`, `retry_budget`, `retries_used`, `requested_checks`, `checks`, `touches_tests`, `session_id`, `base_ref`, `worktree`, `branch`), statuses (`running`/`verifying`/`needs_review`/`failed`/`landed`/`abandoned`/`lost`), and command names (`dispatch`/`quick`/`resume`/`show`/`land`/`abandon`/`list`/`doctor`) are used consistently across tasks. `finish_verify` signature is `(id, wt, verify)` after Task 4 (call site in Task 3 updated in Task 4 Step 3). ✓

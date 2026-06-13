# Dispatch Harness Decoupling — Phase 1b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the harness-agnostic dispatch *seam* — `begin`/`codex-run`/`verify`/`record` plus the `attach`/`console` observability board — on top of the Phase-1a library, so a native Agent *cell* can compose → delegate to `codex exec -m <model>` → verify → report a verdict, while the `harness=codex` autonomous loop keeps working untouched.

**Architecture:** Phase 1a already extracted the worker-agnostic primitives into `lib/dispatch-lib.sh` (exposed by `bin/dispatch`) and left the codex call site in `lib/dispatch.sh`. Phase 1b adds the *cell-driven* verbs: `begin` opens a library-owned worktree + ledger entry and echoes an `<id>` (no worker runs); `codex-run` (in the codex adapter) threads the two orthogonal sub-axes — `--backend` (transport flag-bundle via the **unchanged** `d_backend_args`) × `-m <model>` — into the single `d_codex_exec` call site, projecting the codex `--json` stream into a per-dispatch `events.jsonl`; `verify` runs checks **once** (no auto-retry — the cell decides); `record` sets status; `attach`/`console` (new `lib/console.sh`) read the event log. A new `skills/dispatch/SKILL.md` is the cell contract and `/dispatch` is the command. `land`/`abandon`/`doctor`/`list`/`show` are unchanged from Phase 1a.

**Tech Stack:** Bash (`set -uo pipefail`, **not** `-e` — explicit `die`/`|| true`), `jq`, `git worktree`. Pure-bash dependency-free test harness (`tests/run.sh` auto-discovers `*_test.sh`; `tests/lib.sh` provides the sandbox + fakes + assertions). Determinism via `CODEX_DISPATCH_NOW`; fake codex via `CODEX_DISPATCH_CODEX_BIN` + `FAKE_CODEX_BEHAVIOR` + `FAKE_CODEX_ARGV_LOG`.

**Spec:** `docs/specs/2026-06-13-dispatch-harness-decoupling-design.md` (§5.3–5.5, §6 Phase 1b, AC2/AC3/AC5/AC7, MC-E/MC-F/MC-G/MC-I/MC-J). **Do NOT** touch the spec's `Status:` line.

**Invariants that hold at every task boundary:**
1. `bash tests/run.sh` is green (all `*_test.sh` pass).
2. `lib/dispatch-lib.sh` stays portable — **no** hard dependency on `lib/dispatch.sh` (codex), `lib/local.sh`, or `lib/paths.sh`. The codex-specific `codex-run` lives in `lib/dispatch.sh`, never in the lib.
3. `d_backend_args` (in `lib/dispatch.sh`) is **unchanged** — `dispatch_backend_ollama_test.sh` pins its exact output. `codex-run` composes `-m <model>` as a *separate* appended axis.
4. `codex_dispatch.sh` back-compat (`dispatch`/`resume`/`quick`/`land`/…) behaves exactly as before (E8). The only edit to it is two constant sidecar fields (Task 1).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `lib/dispatch-lib.sh` | Modify (+`d_events_path`/`d_event`/`d_begin`/`d_verify`/`d_record`) | Portable library: event-log writer + worktree-opener + single-shot verify + status setter. No codex. |
| `lib/dispatch.sh` | Modify (+`d_codex_run`) | Codex adapter: the cell's delegation verb. Two-axis compose into the existing single `d_codex_exec` call site. |
| `lib/console.sh` | **Create** | Observability *readers*: `d_attach` (tail one event log) + `d_console` (the cross-model board). |
| `codex_dispatch.sh` | Modify (2 sidecar fields) | Back-compat engine — gains `harness:"codex"`/`model:"—"` in its sidecar init only. |
| `bin/dispatch` | Modify (route new verbs; source adapter+console) | The CLI the cell shells to. Drops the "Phase 1b not-yet" stubs verb-by-verb. |
| `skills/dispatch/SKILL.md` | **Create** | The dispatch-cell contract: compose → delegate → verify → report; thread `<id>`; never land. |
| `commands/dispatch.md` | **Create** | `/dispatch` — supersedes `/codex-implement` (kept as alias). |
| `lib/install-common.sh` | Modify (1 symlink) | Put `bin/dispatch` on `PATH` so the cell can call it. |
| `tests/dispatch_begin_test.sh` | **Create** | begin: lib-standalone, worktree+sidecar+branch+event, echoes id, harness/model. |
| `tests/dispatch_bakeoff_id_test.sh` | **Create** | parallel same-slug `--label` → distinct ids/branches/worktrees (MC-G). |
| `tests/dispatch_codex_run_test.sh` | **Create** | two-axis `-m`/`--backend` → argv + event projection + sidecar fields + commit. |
| `tests/dispatch_pair_validation_test.sh` | **Create** | E10 refusals: Claude model; codex-less non-Claude. |
| `tests/dispatch_cell_spine_test.sh` | **Create** | begin→codex-run→verify→record→land happy path (the SKILL spine). |
| `tests/dispatch_console_test.sh` | **Create** | attach (`--no-follow`) + console board incl. legacy-sidecar defaulting. |
| `tests/dispatch_addmodel_test.sh` | **Create** | AC7: cloud model = `-m` passthrough no-code; provider = one `d_backend_args` arm. |
| `tests/dispatch_skill_md_test.sh` | **Create** | structural lint of `skills/dispatch/SKILL.md`. |
| `tests/dispatch_command_md_test.sh` | **Create** | structural lint of `commands/dispatch.md`. |
| `tests/dispatch_install_path_test.sh` | **Create** | install symlinks `bin/dispatch` onto PATH; `CCP_SKIP_PATH` respected. |

---

## Task 1: Event log + `begin` + sidecar `harness`/`model` fields

**Files:**
- Modify: `lib/dispatch-lib.sh` (append `d_events_path`, `d_event`, `d_begin`)
- Modify: `codex_dispatch.sh:78-87` (cmd_dispatch sidecar init — add two constant fields)
- Modify: `bin/dispatch` (route `begin`)
- Test: `tests/dispatch_begin_test.sh`, `tests/dispatch_bakeoff_id_test.sh`

- [ ] **Step 1: Write the failing test `tests/dispatch_begin_test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"

# --- begin is drivable with ONLY the portable lib sourced (no codex adapter) ---
ro="$(ps_make_sandbox_repo ok)"
drv="$PS_SANDBOX/begin-iso.sh"; cat > "$drv" <<'EOF'
set -uo pipefail
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
cd "$REPO"
d_begin "$SLUG" --label "$LABEL"
EOF
id="$( REPO="$ro" SLUG="add-widget" LABEL="gpt-5.5" PS_REPO_ROOT="$PS_REPO_ROOT" \
       CODEX_DISPATCH_NOW=20260613T200000Z bash "$drv" )"
assert_eq "$id" "20260613T200000Z-add-widget-gpt-5-5" "begin echoes the <id> (slug + slugified label)"

# sidecar + worktree + branch + event log all created, status=running, no worker ran
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$id" '.status')"  "running" "begin opens at status=running"
  assert_eq "$(d_sc_get "$id" '.harness')" "agent"   "default harness=agent"
  assert_eq "$(d_sc_get "$id" '.model')"   "gpt-5.5" "model recorded from --label"
  assert_eq "$(d_sc_get "$id" '.backend')" "—"       "backend deferred to codex-run (— until then)"
  assert_contains "$(d_sc_get "$id" '.branch')" "dispatch/add-widget-gpt-5-5-" "branch embeds slug+label"
  wt="$(d_sc_get "$id" '.worktree')"; assert_file "$wt" "worktree directory created"
  assert_file "$(d_events_path "$id")" "event log seeded"
  assert_contains "$(cat "$(d_events_path "$id")")" '"phase":"begin"' "begin wrote a begin event" )

# --- begin via bin/dispatch (parity) + default harness/no-label path ---
ro2="$(ps_make_sandbox_repo ok2)"
id2="$( cd "$ro2" && CODEX_DISPATCH_NOW=20260613T201000Z bash "$DISPATCH" begin tidy )"
assert_eq "$id2" "20260613T201000Z-tidy" "begin via bin/dispatch with no --label"
( cd "$ro2"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$id2" '.model')" "—" "no --label => model is —" )

# --- guards ---
out="$( cd "$ro2" && bash "$DISPATCH" begin tidy --verify bogus 2>&1 )"; rc=$?
assert_eq "$rc" "1" "invalid --verify refused"
assert_contains "$out" "invalid --verify" "explains the bad verify mode"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it; expect FAIL (`d_begin`/`d_events_path` undefined, `begin` still stubbed)**

Run: `bash tests/dispatch_begin_test.sh`
Expected: FAILs — `command not found`-style empties for `d_begin`, and `bin/dispatch begin` dies "arrives in Phase 1b".

- [ ] **Step 3: Add the event-log writer + `d_begin` to `lib/dispatch-lib.sh`**

Append after the `d_doctor` function (end of file), before the final newline:

```bash

# --- event log (the console-facing stream; distinct from codexlog.jsonl) -----
# Per spec §4/MC-I: <id>.events.jsonl is the append-only {ts,phase,kind,line}
# console stream, SEPARATE from C's verbatim <id>.codexlog.jsonl. Writers append
# ONE whole line per call; a single <4096-byte printf to an O_APPEND fd is atomic
# on macOS/Linux, so concurrent contestants never interleave-corrupt the log.
d_events_path() { printf '%s\n' "$(d_sidecar_dir)/$1.events.jsonl"; }
d_event() {
  local id="$1" phase="$2" kind="$3" line="$4" p
  p="$(d_events_path "$id")"
  mkdir -p "$(d_sidecar_dir)" 2>/dev/null || true
  printf '%s\n' "$(jq -nc --arg ts "$(d_now)" --arg ph "$phase" --arg k "$kind" --arg l "$line" \
      '{ts:$ts, phase:$ph, kind:$k, line:$l}')" >> "$p" 2>/dev/null || true
}

# --- begin: open a library-owned worktree + ledger entry (NO worker runs) -----
# d_begin <slug> [--label <text>] [--harness agent|workflow|codex] [--verify checks|review|both] [--base <ref>]
# Echoes <id> on stdout — the cell captures it and threads it through codex-run /
# verify / record / land. --label embeds the contestant (model) in the <id> AND
# branch so parallel same-slug fan-out can't collide on second-granularity ids
# (spec §5.6 / MC-G). This is cmd_dispatch's worktree+sidecar setup WITHOUT codex.
d_begin() {
  local slug="" label="" harness="agent" verify="both" base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)   label="$2"; shift 2;;
      --harness) harness="$2"; shift 2;;
      --verify)  verify="$2"; shift 2;;
      --base)    base="$2"; shift 2;;
      -*) die "unknown flag: $1";;
      *) if [ -z "$slug" ]; then slug="$1"; else die "begin takes one <slug> (extra arg: $1)"; fi; shift;;
    esac
  done
  [ -n "$slug" ] || die "begin requires a <slug>"
  case "$verify"  in checks|review|both) ;; *) die "invalid --verify: $verify (want checks|review|both)";; esac
  case "$harness" in agent|workflow|codex) ;; *) die "invalid --harness: $harness (want agent|workflow|codex)";; esac
  d_in_git_repo || die "not in a git repository"

  local repo base_ref id short branch wt labelpart=""
  repo="$(d_repo_root)"
  base_ref="${base:-$(d_head_sha)}"
  slug="$(d_slugify "$slug")"; [ -n "$slug" ] || slug="dispatch"
  [ -n "$label" ] && labelpart="-$(d_slugify "$label")"
  id="$(d_now)-${slug}${labelpart}"
  short="$(d_short "$id")"
  branch="dispatch/${slug}${labelpart}-${short}"
  wt="$(d_worktree_root)/$id"

  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" && die "branch already exists: $branch"
  [ -e "$wt" ] && die "worktree path already exists: $wt"

  mkdir -p "$(d_sidecar_dir)" "$(d_worktree_root)"
  d_ensure_worktree_gitignore "$repo"
  git -C "$repo" worktree add -q -b "$branch" "$wt" "$base_ref" \
    || die "failed to create worktree at $wt"

  jq -n --arg id "$id" --arg now "$(d_now)" --arg repo "$repo" --arg wt "$wt" \
        --arg branch "$branch" --arg base "$base_ref" --arg verify "$verify" \
        --arg harness "$harness" --arg model "${label:-—}" \
    '{id:$id, created_at:$now, updated_at:$now, repo:$repo, worktree:$wt, branch:$branch,
      base_ref:$base, verify:$verify, retry_budget:0, retries_used:0,
      requested_checks:[], session_id:null, status:"running",
      checks:[], touches_tests:false, codex_last_message:null, prompt:null,
      backend:"—", harness:$harness, model:$model}' \
    > "$(d_sidecar_path "$id")"
  d_event "$id" begin start "harness=$harness model=${label:-—} branch=$branch"
  printf '%s\n' "$id"
}
```

- [ ] **Step 4: Add the two constant sidecar fields to `codex_dispatch.sh` cmd_dispatch**

In `codex_dispatch.sh`, the `jq -n … '{… backend:$backend}'` block (the sidecar init at ~line 82-87), change the closing object so codex-path sidecars carry the new fields explicitly:

Replace `      backend:$backend}' \` with:
```bash
      backend:$backend, harness:"codex", model:"—"}' \
```
(`harness`/`model` are constants here — no new `--arg` needed. The console still *defaults* these for truly-legacy sidecars that predate this field, per AC3.)

- [ ] **Step 5: Route `begin` in `bin/dispatch`**

In `bin/dispatch`'s `main()`, add an arm above `land)`:
```bash
    begin)     d_begin "$@" ;;
```
and drop `begin` from the not-yet alternation:
`begin|codex-run|verify|record|attach|console)` → `codex-run|verify|record|attach|console)`.

- [ ] **Step 6: Run the begin test; expect PASS**

Run: `bash tests/dispatch_begin_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 7: Write `tests/dispatch_bakeoff_id_test.sh` (MC-G collision proof)**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
ro="$(ps_make_sandbox_repo ok)"

# Two contestants, SAME slug, SAME frozen second, DIFFERENT --label: must not collide
# (C's id is second-granularity + branch is unique-or-die — an unlabelled same-slug
# fan-out would fail `git worktree add`). --label disambiguates (spec §5.6).
ida="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T120000Z bash "$DISPATCH" begin race --label gpt-5.5 )"
idb="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T120000Z bash "$DISPATCH" begin race --label qwen2.5 )"
assert_eq "$ida" "20260613T120000Z-race-gpt-5-5" "contestant A id embeds label"
assert_eq "$idb" "20260613T120000Z-race-qwen2-5" "contestant B id embeds label"
case "$ida" in "$idb") echo "  FAIL: same-second same-slug contestants collided on id"; exit 1;; esac

( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  ba="$(d_sc_get "$ida" '.branch')"; bb="$(d_sc_get "$idb" '.branch')"
  case "$ba" in "$bb") echo "  FAIL: contestants share a branch"; exit 1;; esac
  assert_contains "$ba" "dispatch/race-gpt-5-5-"  "A branch embeds slug+label"
  assert_contains "$bb" "dispatch/race-qwen2-5-"  "B branch embeds slug+label"
  wta="$(d_sc_get "$ida" '.worktree')"; wtb="$(d_sc_get "$idb" '.worktree')"
  assert_file "$wta" "A worktree exists"
  assert_file "$wtb" "B worktree exists"
  case "$wta" in "$wtb") echo "  FAIL: contestants share a worktree path"; exit 1;; esac )

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 8: Run it; expect PASS**

Run: `bash tests/dispatch_bakeoff_id_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 9: Full suite green, then commit**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===` (N grew by 2).

```bash
git add lib/dispatch-lib.sh codex_dispatch.sh bin/dispatch \
        tests/dispatch_begin_test.sh tests/dispatch_bakeoff_id_test.sh
git commit -m "$(cat <<'EOF'
feat(dispatch): add begin verb + events.jsonl writer + sidecar harness/model

Subsystem E Phase 1b, Task 1. d_begin opens a library-owned worktree + ledger
entry (status=running) and echoes <id> without running any worker; --label
embeds the contestant in the id/branch so same-slug fan-out can't collide
(MC-G). d_event appends whole-line atomically to the console-facing
<id>.events.jsonl (MC-I). codex-path sidecars now carry harness/model too.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `codex-run` — the two-axis cell delegation verb (E4/E6/E10)

**Files:**
- Modify: `lib/dispatch.sh` (append `d_codex_run`)
- Modify: `bin/dispatch` (source the adapter; route `codex-run`)
- Test: `tests/dispatch_codex_run_test.sh`, `tests/dispatch_pair_validation_test.sh`

- [ ] **Step 1: Write the failing test `tests/dispatch_codex_run_test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"
log="$PS_SANDBOX/argv.log"; : > "$log"

# begin, then codex-run the headline (codex, gpt-5.5): -m threads as its own axis,
# the codex bundle for `codex` backend is empty, so argv carries exactly `-m gpt-5.5`.
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T130000Z bash "$DISPATCH" begin add-x --label gpt-5.5 )"
out="$( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
        bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.5 "implement X in the worktree" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "codex-run exits 0"
assert_contains "$(cat "$log")" "-m gpt-5.5" "argv threads -m <model> (the model axis)"
assert_contains "$(cat "$log")" "exec" "still goes through codex exec (single call site)"
# the full diff is NOT auto-dumped (E1 token economy preserved)
case "$out" in *"+ok"*) echo "  FAIL: codex-run leaked the full diff"; exit 1;; esac

( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  wt="$(d_sc_get "$id" '.worktree')"
  assert_eq "$(cat "$wt/IMPL")" "ok" "codex's change landed in the library worktree"
  assert_eq "$(d_sc_get "$id" '.backend')" "codex" "sidecar backend set by codex-run"
  assert_eq "$(d_sc_get "$id" '.model')"   "gpt-5.5" "sidecar model set by codex-run"
  assert_eq "$(d_sc_get "$id" '.session_id')" "fake-sess-0001" "session captured from the --json stream"
  assert_eq "$(d_sc_get "$id" '.prompt')" "implement X in the worktree" "composed prompt recorded (for the curator feed)"
  # codex-run committed the work onto the dispatch branch
  assert_eq "$(d_has_changes "$wt" "$(d_sc_get "$id" '.base_ref')" && echo yes || echo no)" "yes" "worktree diverges from base (work committed)"
  # the verbatim stream is in codexlog; a projection is in the console event log
  assert_file "$(d_sidecar_dir)/$id.codexlog.jsonl" "verbatim codex stream retained"
  ev="$(cat "$(d_events_path "$id")")"
  assert_contains "$ev" '"phase":"codex-run"' "codex-run wrote console events"
  assert_contains "$ev" "session.created" "codex --json progress projected into the event log" )

# ollama backend: -m overrides the bundle's baked-in default (last-wins), transport intact
: > "$log"
id2="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T131000Z bash "$DISPATCH" begin add-y --label qwen2.5 )"
( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
    bash "$DISPATCH" codex-run "$id2" --backend ollama -m qwen2.5 "do y" >/dev/null 2>&1 )
assert_contains "$(cat "$log")" "--oss --local-provider ollama" "ollama transport bundle threaded unchanged"
assert_contains "$(cat "$log")" "-m qwen2.5" "the cell's -m model is present (last-wins over the arm default)"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it; expect FAIL (`codex-run` still stubbed in bin/dispatch)**

Run: `bash tests/dispatch_codex_run_test.sh`
Expected: FAIL — `bin/dispatch codex-run` dies "arrives in Phase 1b".

- [ ] **Step 3: Append `d_codex_run` to `lib/dispatch.sh`**

Add at the end of `lib/dispatch.sh` (after `d_backend_args`). This is the codex-specific cell verb; it lives in the adapter, never in the portable lib (Invariant 2). `d_event`/`d_sc_*`/`d_commit_worktree` come from `dispatch-lib.sh`, already sourced at the top of this file.

```bash

# --- codex-run: the Subsystem-E cell delegation verb (E4/E6/E10) -------------
# d_codex_run <id> --backend <codex|ollama|local|…> -m <model> "<composed-prompt>"
# Runs `codex exec` (via the single d_codex_exec call site) in the dispatch's
# worktree, threading the two orthogonal sub-axes: --backend selects the transport
# flag-bundle (the UNCHANGED d_backend_args), -m selects the model — appended as its
# own axis. For the `codex` backend the bundle is empty, so argv is exactly
# `-m <model>`; for `ollama` the cell's -m wins over the arm's baked-in default
# (last-wins, harmless). The verbatim --json stream stays in <id>.codexlog.jsonl;
# a compact projection is forwarded into <id>.events.jsonl (MC-I). Updates the
# sidecar (.backend/.model/.session_id/.prompt) and commits the work.
# E10 (MC-J): REFUSES a Claude model (Claude cells implement directly, never via
# codex) and a non-Claude model when no codex binary is available — each loudly.
d_codex_run() {
  local id="" backend="codex" model="" prompt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --backend)  backend="$2"; shift 2;;
      -m|--model) model="$2"; shift 2;;
      --) shift; break;;
      -*) die "unknown flag: $1";;
      *) if [ -z "$id" ]; then id="$1"; else prompt="$1"; fi; shift;;
    esac
  done
  [ -n "$prompt" ] || prompt="${1:-}"
  [ -n "$id" ]     || die "codex-run requires a dispatch id"
  [ -n "$prompt" ] || die "codex-run requires a composed prompt"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  [ -n "$model" ]  || die "codex-run requires -m <model> (the worker model axis)"
  # E10: a Claude model is implemented by the cell directly — never delegated to codex.
  case "$model" in
    claude|claude-*|sonnet|opus|haiku|fable)
      die "model '$model' is a Claude model — implement it directly in the cell; do NOT codex-run it (E10).";;
  esac
  # E10: a non-Claude model needs a codex binary to ride in through.
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}"
  command -v "$bin" >/dev/null 2>&1 \
    || die "no codex binary ('$bin') available — install codex, or pick a Claude model to implement directly (E10)."
  local bargs; bargs="$(d_backend_args "$backend")" || die "invalid --backend: $backend"
  local wt; wt="$(d_sc_get "$id" '.worktree')"
  [ -d "$wt" ] || die "worktree missing for '$id' (run: dispatch doctor)"

  d_event "$id" codex-run start "backend=$backend model=$model"
  local lastmsg session; lastmsg="$(mktemp)"
  # $bargs is intentionally unquoted (word-split into flags, as in cmd_dispatch);
  # -m "$model" is the separate model axis appended last.
  session="$(d_codex_exec "$id" "$wt" "$lastmsg" "$prompt" $bargs -m "$model")"
  d_sc_set "$id" \
    '.session_id=(if $s=="" then null else $s end)|.codex_last_message=$m|.backend=$b|.model=$mo|.prompt=$p|.updated_at=$u' \
    --arg s "$session" --arg m "$(cat "$lastmsg" 2>/dev/null)" \
    --arg b "$backend" --arg mo "$model" --arg p "$prompt" --arg u "$(d_now)"
  rm -f "$lastmsg"

  # project the verbatim codex stream into the console event log (MC-I).
  local cl; cl="$(d_sidecar_dir)/$id.codexlog.jsonl"
  if [ -f "$cl" ]; then
    local pl
    while IFS= read -r pl; do
      [ -n "$pl" ] && d_event "$id" codex-run progress "$pl"
    done < <(jq -rc 'select(.type) | "\(.type) \(.session_id // .thread_id // .item.item_type // .item.type // "")"' "$cl" 2>/dev/null)
  fi

  d_commit_worktree "$wt" "codex-run: $id ($backend -m $model)" || true
  d_event "$id" codex-run done "$(d_sc_get "$id" '.codex_last_message')"
  echo "codex-run $id done (backend=$backend model=$model). Next: dispatch verify $id --check '<cmd>'"
}
```

- [ ] **Step 4: Source the adapter + route `codex-run` in `bin/dispatch`**

`codex-run` needs the codex adapter. Change the library source line so `bin/dispatch` pulls `lib/dispatch.sh` (which sources `lib/dispatch-lib.sh` via its include guard — no double-source):

Replace:
```bash
source "$ROOT/lib/dispatch-lib.sh"
```
with:
```bash
source "$ROOT/lib/dispatch.sh"     # codex adapter (sources dispatch-lib.sh) — needed for codex-run
```

Add an arm in `main()` above `land)`:
```bash
    codex-run) d_codex_run "$@" ;;
```
and drop `codex-run` from the not-yet alternation:
`codex-run|verify|record|attach|console)` → `verify|record|attach|console)`.

- [ ] **Step 5: Run the codex-run test; expect PASS**

Run: `bash tests/dispatch_codex_run_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 6: Write `tests/dispatch_pair_validation_test.sh` (E10 refusals)**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T140000Z bash "$DISPATCH" begin pv --label opus )"

# E10: a Claude model must be refused loudly (Claude cells implement directly).
for m in claude opus sonnet haiku fable claude-3-5; do
  out="$( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" \
          bash "$DISPATCH" codex-run "$id" --backend codex -m "$m" "do it" 2>&1 )"; rc=$?
  assert_eq "$rc" "1" "codex-run refuses Claude model '$m'"
  assert_contains "$out" "implement it directly" "refusal names the correct next move for '$m'"
done

# E10: a non-Claude model with NO codex binary available errors cleanly.
out="$( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="/nonexistent/codex-bin" \
        bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.5 "do it" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "codex-run refuses when no codex binary is available"
assert_contains "$out" "no codex binary" "refusal explains the missing binary"

# missing -m is refused (a worker model is mandatory on the codex path)
out="$( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" \
        bash "$DISPATCH" codex-run "$id" --backend codex "do it" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "codex-run requires -m <model>"
assert_contains "$out" "requires -m" "explains the -m requirement"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 7: Run it; expect PASS** (the E10 guards are already in `d_codex_run` from Step 3)

Run: `bash tests/dispatch_pair_validation_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 8: Full suite green, then commit**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===`.

```bash
git add lib/dispatch.sh bin/dispatch \
        tests/dispatch_codex_run_test.sh tests/dispatch_pair_validation_test.sh
git commit -m "$(cat <<'EOF'
feat(dispatch): add codex-run — the two-axis cell delegation verb (E4/E6/E10)

Subsystem E Phase 1b, Task 2. d_codex_run threads --backend (transport bundle
via the UNCHANGED d_backend_args) x -m <model> into the single d_codex_exec
call site, projects the codex --json stream into events.jsonl beside the
verbatim codexlog, updates the sidecar, and commits. E10: refuses a Claude
model (implement directly) and a codex-less non-Claude model, loudly.
bin/dispatch now sources the codex adapter.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `verify` (single-shot) + `record` (status setter) + the cell spine

**Files:**
- Modify: `lib/dispatch-lib.sh` (append `d_verify`, `d_record`)
- Modify: `bin/dispatch` (route `verify`, `record`)
- Test: `tests/dispatch_cell_spine_test.sh`

- [ ] **Step 1: Write the failing test `tests/dispatch_cell_spine_test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"

# The SKILL spine end-to-end on the cell path: begin -> codex-run -> verify -> record -> land.
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T150000Z bash "$DISPATCH" begin feat --label gpt-5.5 --verify checks )"
( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" \
    bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.5 "implement feat" >/dev/null 2>&1 )

# verify runs the checks ONCE and records them; it sets NO status (the cell decides).
vout="$( cd "$ro" && bash "$DISPATCH" verify "$id" --check 'bash check.sh' 2>&1 )"; vrc=$?
assert_eq "$vrc" "0" "verify exits 0 when checks pass"
assert_contains "$vout" "PASS" "verify reports PASS"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$id" '.status')" "running" "verify does NOT mutate status (single-shot, cell decides)"
  assert_eq "$(d_sc_get "$id" '.checks[0].exit')" "0" "verify recorded the passing check"
  assert_eq "$(d_sc_get "$id" '.requested_checks[0]')" "bash check.sh" "verify persisted requested_checks for land's re-verify" )

# the cell accepts -> record needs_review.
( cd "$ro" && bash "$DISPATCH" record "$id" --status needs_review >/dev/null 2>&1 )
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$id" '.status')" "needs_review" "record set status=needs_review" )

# land (unchanged from Phase 1a) merges it: re-verifies post-rebase from requested_checks.
lout="$( cd "$ro" && bash "$DISPATCH" land "$id" 2>&1 )"; lrc=$?
assert_eq "$lrc" "0" "land succeeds on the cell-path dispatch"
assert_contains "$lout" "Landed $id" "land reports success"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$id" '.status')" "landed" "sidecar status=landed"
  assert_eq "$(cat "$ro/IMPL")" "ok" "the change is merged into the working tree" )

# verify on a no-checks (review) dispatch is a clean no-op.
id2="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T151000Z bash "$DISPATCH" begin docs --label gpt-5.5 --verify review )"
vout2="$( cd "$ro" && bash "$DISPATCH" verify "$id2" 2>&1 )"; assert_eq "$?" "0" "verify with no checks exits 0"
assert_contains "$vout2" "no checks" "verify explains the review-only no-op"

# record rejects an invalid status.
out="$( cd "$ro" && bash "$DISPATCH" record "$id2" --status bogus 2>&1 )"; rc=$?
assert_eq "$rc" "1" "record refuses an invalid status"
assert_contains "$out" "invalid --status" "explains the bad status"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it; expect FAIL (`verify`/`record` still stubbed)**

Run: `bash tests/dispatch_cell_spine_test.sh`
Expected: FAIL — `bin/dispatch verify` dies "arrives in Phase 1b".

- [ ] **Step 3: Append `d_verify` and `d_record` to `lib/dispatch-lib.sh`**

Add after `d_begin` (these are worker-agnostic — they only read/run checks and set status):

```bash

# d_verify <id> [--check '<cmd>']...  — run the dispatch's checks ONCE in its
# worktree and record results. NO auto-retry: the cell owns resume/accept/fail
# judgment (spec §5.3 step 4). Checks come from --check; with none given it
# replays the sidecar's stored .requested_checks. Persists the cmds to
# .requested_checks so land's post-rebase re-verify can replay them, and records
# .checks + .touches_tests. Prints a one-line PASS/FAIL; sets NO status.
d_verify() {
  local id=""; local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) checks+=("$2"); shift 2;;
      -*) die "unknown flag: $1";;
      *) if [ -z "$id" ]; then id="$1"; else die "verify takes one id (extra: $1)"; fi; shift;;
    esac
  done
  [ -n "$id" ] || die "verify requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local wt base; wt="$(d_sc_get "$id" '.worktree')"; base="$(d_sc_get "$id" '.base_ref')"
  [ -d "$wt" ] || die "worktree missing for '$id' (run: dispatch doctor)"
  if [ "${#checks[@]}" -eq 0 ]; then
    while IFS= read -r line; do [ -n "$line" ] && checks+=("$line"); done \
      < <(d_sc_get "$id" '.requested_checks[]')
  fi
  if [ "${#checks[@]}" -eq 0 ]; then
    d_event "$id" verify skip "no checks (review-only)"
    echo "verify $id: no checks to run (review-only — the cell reviews the diff)."
    return 0
  fi
  local cj; cj="$(printf '%s\n' "${checks[@]}" | jq -R . | jq -s '.')"
  d_sc_set "$id" '.requested_checks=$c' --argjson c "$cj"
  d_run_checks "$wt" "${checks[@]}"; local ok=$?
  d_sc_set "$id" '.checks=$c|.updated_at=$u' --argjson c "$D_CHECKS_JSON" --arg u "$(d_now)"
  local touches=false
  if d_changed_files "$wt" "$base" | d_touches_tests; then touches=true; fi
  d_sc_set "$id" '.touches_tests=$t' --argjson t "$touches"
  if [ "$ok" -eq 0 ]; then
    d_event "$id" verify pass "checks=${#checks[@]}"
    echo "verify $id: PASS (${#checks[@]} check(s))."
  else
    d_event "$id" verify fail "checks=${#checks[@]}"
    echo "verify $id: FAIL"
    printf '%s' "$D_CHECKS_JSON" | jq -r '.[] | "  [\(.exit)] \(.cmd)"'
  fi
  [ "$touches" = true ] && echo "  ⚠ diff modifies tests — review before landing"
  return "$ok"
}

# d_record <id> --status <needs_review|failed|noop>  — cell/orchestrator status
# setter. The cell calls this after verify to commit its resume/accept/fail call.
d_record() {
  local id="" status=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status="$2"; shift 2;;
      -*) die "unknown flag: $1";;
      *) if [ -z "$id" ]; then id="$1"; else die "record takes one id (extra: $1)"; fi; shift;;
    esac
  done
  [ -n "$id" ] || die "record requires a dispatch id"
  [ -n "$status" ] || die "record requires --status <needs_review|failed|noop>"
  case "$status" in needs_review|failed|noop) ;; *) die "invalid --status: $status (want needs_review|failed|noop)";; esac
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  d_sc_set "$id" '.status=$s|.updated_at=$u' --arg s "$status" --arg u "$(d_now)"
  d_event "$id" record "$status" ""
  echo "record $id: status=$status"
}
```

- [ ] **Step 4: Route `verify`/`record` in `bin/dispatch`**

Add arms in `main()` above `land)`:
```bash
    verify)    d_verify "$@" ;;
    record)    d_record "$@" ;;
```
and drop them from the not-yet alternation:
`verify|record|attach|console)` → `attach|console)`.

- [ ] **Step 5: Run the spine test; expect PASS**

Run: `bash tests/dispatch_cell_spine_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 6: Full suite green, then commit**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===`.

```bash
git add lib/dispatch-lib.sh bin/dispatch tests/dispatch_cell_spine_test.sh
git commit -m "$(cat <<'EOF'
feat(dispatch): add single-shot verify + record; prove the begin->land cell spine

Subsystem E Phase 1b, Task 3. d_verify runs the dispatch's checks ONCE (no
auto-retry — the cell owns resume/accept/fail), persists requested_checks so
land's post-rebase re-verify replays them, and records checks + touches_tests
without mutating status. d_record is the validated status setter. The spine
test drives begin -> codex-run -> verify -> record -> land green.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `lib/console.sh` — `attach` + `console` observability (payoff 4 / AC3)

**Files:**
- Create: `lib/console.sh`
- Modify: `bin/dispatch` (source console; route `attach`/`console`; remove the now-empty not-yet stub)
- Test: `tests/dispatch_console_test.sh`

- [ ] **Step 1: Write the failing test `tests/dispatch_console_test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"

# a real cell dispatch (begin + codex-run) gives attach something to show.
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T160000Z bash "$DISPATCH" begin board --label gpt-5.5 )"
( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" \
    bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.5 "do board" >/dev/null 2>&1 )

# attach --no-follow formats the event stream and exits (no tail -f hang).
aout="$( cd "$ro" && bash "$DISPATCH" attach "$id" --no-follow 2>&1 )"; arc=$?
assert_eq "$arc" "0" "attach --no-follow exits"
assert_contains "$aout" "[begin/start]" "attach renders the begin event"
assert_contains "$aout" "[codex-run/start]" "attach renders the codex-run start"
assert_contains "$aout" "[codex-run/done]" "attach renders the codex-run done"

# console board: columns + this dispatch's harness/backend/model/status.
cout="$( cd "$ro" && bash "$DISPATCH" console 2>&1 )"
assert_contains "$cout" "HARNESS" "console prints the column header"
assert_contains "$cout" "LAST-ACTIVITY" "console has the last-activity column"
assert_contains "$cout" "$id" "console lists the dispatch id"
assert_contains "$cout" "agent" "console shows harness=agent for a begin'd cell"
assert_contains "$cout" "gpt-5.5" "console shows the model"

# legacy-sidecar defaulting (AC3): a sidecar with NO harness/model field shows codex/—.
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  legacy="20200101T000000Z-legacy"
  jq -n --arg id "$legacy" '{id:$id, status:"needs_review", branch:"codex/legacy", updated_at:"20200101T000000Z"}' \
    > "$(d_sidecar_path "$legacy")" )
cout2="$( cd "$ro" && bash "$DISPATCH" console 2>&1 )"
# the legacy row defaults harness->codex and model->— (no field present)
assert_contains "$cout2" "20200101T000000Z-legacy" "console lists the legacy dispatch"
line="$(printf '%s\n' "$cout2" | grep legacy)"
assert_contains "$line" "codex" "legacy harness defaults to codex"
assert_contains "$line" "—"     "legacy model defaults to —"

# attach on an unknown id is refused.
out="$( cd "$ro" && bash "$DISPATCH" attach nope --no-follow 2>&1 )"; rc=$?
assert_eq "$rc" "1" "attach refuses an unknown id"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it; expect FAIL (`attach`/`console` still stubbed; `lib/console.sh` absent)**

Run: `bash tests/dispatch_console_test.sh`
Expected: FAIL — `bin/dispatch attach` dies "arrives in Phase 1b".

- [ ] **Step 3: Create `lib/console.sh`**

```bash
#!/usr/bin/env bash
# lib/console.sh — dispatch observability READERS (Subsystem E Phase 1b, §5.5).
#   attach  = live-tail one dispatch's event log ("switch into what it's doing")
#   console = the cross-model board: every dispatch's id/harness/backend/model/status
# SOURCE this AFTER lib/dispatch-lib.sh — it uses d_events_path/d_sc_get/d_list_ids/
# d_in_git_repo/die. The WRITER (d_event) lives in the library so begin/codex-run/
# verify/record/land can all append; the readers here add no write paths.
[ -n "${_DISPATCH_CONSOLE_SOURCED:-}" ] && return 0
_DISPATCH_CONSOLE_SOURCED=1

# d_attach <id> [--no-follow] [--lines N] — surface one dispatch's event stream.
# Default FOLLOWS (tail -f) for live use; --no-follow prints what exists and exits
# (tests + non-interactive callers). Each {ts,phase,kind,line} renders as
#   <ts>  [<phase>/<kind>] <line>
d_attach() {
  local id="" follow=1 lines=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-follow) follow=0; shift;;
      --lines) lines="$2"; shift 2;;
      -*) die "unknown flag: $1";;
      *) if [ -z "$id" ]; then id="$1"; else die "attach takes one id (extra: $1)"; fi; shift;;
    esac
  done
  [ -n "$id" ] || die "attach requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local p fmt; p="$(d_events_path "$id")"
  fmt='"\(.ts)  [\(.phase)/\(.kind)] \(.line)"'
  [ -f "$p" ] || { echo "no events yet for $id"; return 0; }
  if [ "$follow" -eq 1 ]; then
    jq -rc "$fmt" "$p" 2>/dev/null || true
    # follow new lines; codex is non-interactive, so this is read-only live-tail.
    tail -n 0 -f "$p" 2>/dev/null | while IFS= read -r l; do
      printf '%s\n' "$l" | jq -rc "$fmt" 2>/dev/null || true
    done
  else
    if [ "$lines" -gt 0 ]; then tail -n "$lines" "$p"; else cat "$p"; fi \
      | jq -rc "$fmt" 2>/dev/null || true
  fi
}

# d_console — one board across every dispatch in this repo:
#   id · harness · backend · model · status · last-activity
# Defaults harness->codex and model->— for LEGACY sidecars (field absent),
# mirroring backend's defaulting (AC3). last-activity = newest event ts, else
# the sidecar's updated_at.
d_console() {
  d_in_git_repo || die "not in a git repository"
  local ids; ids="$(d_list_ids)"
  if [ -z "$ids" ]; then echo "No dispatches for this repo."; return 0; fi
  echo "Dispatch console (this repo):"
  printf '  %-30s %-8s %-8s %-12s %-13s %s\n' "ID" "HARNESS" "BACKEND" "MODEL" "STATUS" "LAST-ACTIVITY"
  local id harness backend model status last ep
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    harness="$(d_sc_get "$id" '.harness')"; [ -n "$harness" ] || harness="codex"
    backend="$(d_sc_get "$id" '.backend')"; [ -n "$backend" ] || backend="codex"
    model="$(d_sc_get "$id" '.model')";     [ -n "$model" ]   || model="—"
    status="$(d_sc_get "$id" '.status')"
    ep="$(d_events_path "$id")"
    if [ -f "$ep" ]; then last="$(tail -n 1 "$ep" | jq -r '.ts' 2>/dev/null)"; else last=""; fi
    [ -n "$last" ] || last="$(d_sc_get "$id" '.updated_at')"
    printf '  %-30s %-8s %-8s %-12s %-13s %s\n' "$id" "$harness" "$backend" "$model" "$status" "$last"
  done <<< "$ids"
}
```

- [ ] **Step 4: Source console + route `attach`/`console` in `bin/dispatch`**

Add a source line after the `lib/dispatch.sh` source:
```bash
source "$ROOT/lib/console.sh"      # attach/console readers
```

Add arms in `main()` above `land)`:
```bash
    attach)    d_attach "$@" ;;
    console)   d_console "$@" ;;
```
and DELETE the now-empty not-yet stub (both lines):
```bash
    attach|console)
      die "'$sub' arrives in Phase 1b — not yet implemented" ;;
```

- [ ] **Step 5: Run the console test; expect PASS**

Run: `bash tests/dispatch_console_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 6: Full suite green, then commit**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===`.

```bash
git add lib/console.sh bin/dispatch tests/dispatch_console_test.sh
git commit -m "$(cat <<'EOF'
feat(dispatch): add console.sh — attach (tail one stream) + the cross-model board

Subsystem E Phase 1b, Task 4. d_attach renders/follows one dispatch's
events.jsonl; d_console boards every dispatch (id/harness/backend/model/status/
last-activity), defaulting harness->codex and model->— for legacy sidecars
(AC3). bin/dispatch now wires every Phase 1b verb — the not-yet stub is gone.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Two-axis acceptance proof (AC7) — test only, no implementation

**Files:**
- Test: `tests/dispatch_addmodel_test.sh`

This proves the design Task 2 already delivers: adding a **cloud model** is a `-m <model>` passthrough with **no code change**; adding a **provider** is a **single `d_backend_args` arm and no new files**.

- [ ] **Step 1: Write `tests/dispatch_addmodel_test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"
log="$PS_SANDBOX/argv.log"

# --- AC7a: a NEW cloud model is a pure -m passthrough — NO code change. --------
# A model string never mentioned anywhere in the code threads straight through.
: > "$log"
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T170000Z bash "$DISPATCH" begin am --label gpt-5.4 )"
( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
    bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.4 "x" >/dev/null 2>&1 )
assert_contains "$(cat "$log")" "-m gpt-5.4" "new cloud model threads via -m with no code change"

# --- AC7b: a NEW provider is ONE d_backend_args arm and NO new files. ---------
# Simulate the one-line contributor edit by overriding d_backend_args in a driver
# that adds a transport-only `vllm` arm, then codex-run --backend vllm.
drv="$PS_SANDBOX/addprovider.sh"; cat > "$drv" <<'EOF'
set -uo pipefail
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch.sh"
# The entire "add a provider" change: ONE new case arm (transport-only).
d_backend_args() {
  case "${1:-codex}" in
    codex) : ;;
    vllm)  printf '%s' '--oss --local-provider vllm' ;;
    *)     return 1 ;;
  esac
}
# export so the grandchild fake codex (spawned inside d_codex_run) sees them —
# an inline VAR=x prefix on a FUNCTION call does not reliably reach child procs.
export CODEX_DISPATCH_CODEX_BIN="$FAKE" FAKE_CODEX_ARGV_LOG="$LOG"
cd "$REPO"
id="$(CODEX_DISPATCH_NOW=20260613T171000Z d_begin prov --label m1)"
d_codex_run "$id" --backend vllm -m m1 "x" >/dev/null
EOF
: > "$log"
REPO="$ro" FAKE="$fake" LOG="$log" PS_REPO_ROOT="$PS_REPO_ROOT" bash "$drv"
assert_contains "$(cat "$log")" "--local-provider vllm" "new provider's transport bundle threads from one arm"
assert_contains "$(cat "$log")" "-m m1" "the model axis still threads for the new provider"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it; expect PASS** (no implementation — this validates Task 2's design)

Run: `bash tests/dispatch_addmodel_test.sh`
Expected: `(4 checks, 0 failed)`.

- [ ] **Step 3: Full suite green, then commit**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===`.

```bash
git add tests/dispatch_addmodel_test.sh
git commit -m "$(cat <<'EOF'
test(dispatch): prove the two-axis worker surface (AC7)

Subsystem E Phase 1b, Task 5. Adding a cloud model is a -m passthrough with no
code change; adding a provider is one transport-only d_backend_args arm and no
new files. Both proven against codex-run via argv capture.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `skills/dispatch/SKILL.md` — the dispatch-cell contract

**Files:**
- Create: `skills/dispatch/SKILL.md`
- Test: `tests/dispatch_skill_md_test.sh`

- [ ] **Step 1: Write `tests/dispatch_skill_md_test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MD="$PS_REPO_ROOT/skills/dispatch/SKILL.md"

assert_file "$MD" "dispatch SKILL.md exists"
body="$(cat "$MD")"
# YAML frontmatter
assert_contains "$body" "name: dispatch" "frontmatter names the skill"
assert_contains "$body" "description:" "frontmatter has a description"
# the rigid contract (compose -> delegate -> verify -> report), threading <id>
assert_contains "$body" "begin" "documents begin"
assert_contains "$body" "codex-run" "documents codex-run delegation"
assert_contains "$body" "verify" "documents verify"
assert_contains "$body" "record" "documents record"
assert_contains "$body" "thread" "tells the cell to thread the begin-returned <id>"
# E10 + the never-land rule
assert_contains "$body" "Claude model" "states Claude models are implemented directly (E10)"
assert_contains "$body" "never" "states the cell never lands"

ps_report
```

- [ ] **Step 2: Run it; expect FAIL (file absent)**

Run: `bash tests/dispatch_skill_md_test.sh`
Expected: FAIL — `missing [.../skills/dispatch/SKILL.md]`.

- [ ] **Step 3: Create `skills/dispatch/SKILL.md`**

```markdown
---
name: dispatch
description: Run a single dispatch as a native Agent cell — compose a precise codex prompt from repo context, delegate the implementation to `codex exec -m <model>` (gpt/qwen) or implement a Claude model directly, verify once, and return a structured verdict to the orchestrator. Use when the orchestrator has spawned you (a subagent) to carry out one dispatch on a `(backend, model)` worker. You never land — landing is the orchestrator's reviewed decision.
---

# dispatch (the cell contract)

You are a **dispatch cell** — a native Claude subagent the orchestrator spawned to
carry out exactly one dispatch on a `(backend, model)` worker. You shell to the
`dispatch` CLI (`~/.claude/profile-system/bin/dispatch`, on PATH). Because every Bash
call is a **fresh shell**, you MUST capture the `<id>` that `begin` echoes and thread
it through every later call. You **never** run raw `git worktree`/`git merge`/`codex`
and you **never** land.

## The rigid spine: compose → begin → delegate → verify → record → report

1. **Compose (E5).** Use Read/Grep/Glob to understand the task in repo context.
   Produce a precise codex prompt: target files, constraints, acceptance criteria,
   the definition of done. This codebase understanding is your core value — do not
   pass the task through verbatim.

2. **Begin.** `dispatch begin <slug> --label <model> [--verify checks|review|both]`
   → opens a library-owned worktree + ledger entry (`status=running`) and **echoes the
   `<id>`**. Capture it:
   ```
   id="$(dispatch begin add-widget --label gpt-5.5 --verify checks)"
   ```
   `--label` is your model; it embeds in the id/branch so parallel same-slug
   contestants never collide.

3. **Delegate by `(backend, model)` (E4).**
   - **Claude model** (`model=claude/opus/sonnet/…`): implement directly — edit the
     files in the `begin`-returned worktree yourself. Do NOT `codex-run` a Claude
     model; the library refuses it (E10).
   - **Non-Claude** (gpt-5.5, qwen2.5, …): delegate —
     ```
     dispatch codex-run "$id" --backend <codex|ollama> -m <model> "<your composed prompt>"
     ```
     `--backend` picks the transport flag-bundle; `-m` picks the model. The codex
     `--json` progress streams to the event log (watch it with `dispatch attach "$id"`).

4. **Verify ONCE, then decide.** `dispatch verify "$id" --check '<cmd>' [--check '<cmd2>']`
   runs the checks **once** and records them. There is **no auto-retry** — *you* decide:
   - checks pass → `dispatch record "$id" --status needs_review`
   - fixable failure → `dispatch codex-run "$id" …` again (or edit directly) with sharper
     guidance, then re-verify
   - stuck/out of scope → `dispatch record "$id" --status failed`

5. **Return a structured verdict** to the orchestrator: `id`, `harness`, `backend`,
   `model`, `status`, the diffstat (`dispatch show "$id"` — NOT `--diff`, keep it
   cheap), the check summary, and whether the diff `touches_tests`. The orchestrator
   reviews and lands exactly one.

## Red flags — STOP

| Thought | Reality |
|---|---|
| "I'll `dispatch land` it since checks passed" | The cell NEVER lands. Return the verdict; the orchestrator lands after review. |
| "I'll `codex-run` with `-m opus`" | Claude models are implemented directly in the cell — the library refuses a Claude `codex-run` (E10). |
| "I'll re-run begin to get the worktree path" | Each Bash call is a fresh shell — thread the **captured** `$id`; read paths via `dispatch show "$id"`. |
| "I'll loop verify until it passes" | `verify` is single-shot by design. You decide resume-vs-fail; there is no retry budget on the cell path. |
```

- [ ] **Step 4: Run the lint; expect PASS**

Run: `bash tests/dispatch_skill_md_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 5: Full suite green, then commit**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===`.

```bash
git add skills/dispatch/SKILL.md tests/dispatch_skill_md_test.sh
git commit -m "$(cat <<'EOF'
feat(dispatch): add the dispatch-cell SKILL contract (compose->delegate->verify->report)

Subsystem E Phase 1b, Task 6. The rigid cell contract: capture begin's <id> and
thread it; delegate non-Claude via codex-run -m, implement Claude models
directly (E10); verify once then decide; never land. Linted for structure.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `/dispatch` command + `bin/dispatch` on PATH

**Files:**
- Create: `commands/dispatch.md`
- Modify: `lib/install-common.sh` (one symlink in the PATH block)
- Test: `tests/dispatch_command_md_test.sh`, `tests/dispatch_install_path_test.sh`

- [ ] **Step 1: Write `tests/dispatch_command_md_test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MD="$PS_REPO_ROOT/commands/dispatch.md"

assert_file "$MD" "/dispatch command markdown exists"
body="$(cat "$MD")"
assert_contains "$body" "argument-hint:" "frontmatter has an argument-hint"
assert_contains "$body" "allowed-tools:" "frontmatter declares allowed-tools"
assert_contains "$body" "dispatch skill" "delegates to the dispatch skill"
assert_contains "$body" "\$ARGUMENTS" "expands the user task"
assert_contains "$body" "codex-implement" "notes the /codex-implement alias relationship"

ps_report
```

- [ ] **Step 2: Run it; expect FAIL (file absent)**

Run: `bash tests/dispatch_command_md_test.sh`
Expected: FAIL — `missing [.../commands/dispatch.md]`.

- [ ] **Step 3: Create `commands/dispatch.md`**

```markdown
---
description: Run a single dispatch at a (backend, model) worker via a native Agent cell — compose, delegate to codex (gpt/qwen) or implement Claude directly, verify, report; you (the orchestrator) land
argument-hint: [--model <model>] [--backend codex|ollama] [--verify mode] [--check 'cmd'] "<task>"
allowed-tools: Bash, Read, Agent, Task
---

Spawn a **dispatch cell** (the `dispatch` skill) to carry out the user's task on a
`(backend, model)` worker, then review its verdict and land.

Task: `$ARGUMENTS`

- Default worker is `(codex, gpt-5.5)`. Parse `--model`/`--backend`/`--verify`/`--check`
  from `$ARGUMENTS` to override; the rest is the task description.
- Spawn the cell with the `Agent` tool (default `run_in_background: true`). The cell
  follows the `dispatch` skill: `begin` → compose → `codex-run -m <model>` (or implement
  a Claude model directly) → `verify` once → `record` → return a structured verdict.
  Drive the CLI at `~/.claude/profile-system/bin/dispatch`.
- When the cell returns: if its verify mode includes review, run `dispatch show <id> --diff`
  and actually review the diff (watch for weakened/deleted tests). Then take exactly one of
  `dispatch land <id>` / re-dispatch with feedback / `dispatch abandon <id>`. **Only the
  orchestrator lands** — the cell never does.
- Never run raw git/codex yourself; always go through the `dispatch` CLI.

> Supersedes `/codex-implement`, which remains as a back-compat alias driving the
> `harness=codex` autonomous loop (`codex_dispatch.sh`) for in-flight work (E8).
```

- [ ] **Step 4: Run the command lint; expect PASS**

Run: `bash tests/dispatch_command_md_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 5: Add the `bin/dispatch` PATH symlink to `lib/install-common.sh`**

In `lib/install-common.sh`, inside the `if [ "${CCP_SKIP_PATH:-0}" != "1" ]; then` block (after the `local-ask` symlink, before the closing `fi` — i.e. after line 45), add:
```bash
  ln -sfn "$SRC/bin/dispatch" "$HOME/.local/bin/dispatch"
  echo "  Linked dispatch -> $HOME/.local/bin/dispatch"
```

- [ ] **Step 6: Write `tests/dispatch_install_path_test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
INSTALL="$PS_REPO_ROOT/install.sh"

# Redirect HOME so the PATH symlinks land in the sandbox, not the real ~/.local/bin.
fakehome="$PS_SANDBOX/home"; mkdir -p "$fakehome"

# PATH wiring ENABLED (CCP_SKIP_PATH unset): dispatch is symlinked onto PATH.
HOME="$fakehome" CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
assert_symlink "$fakehome/.local/bin/dispatch" "install links bin/dispatch onto PATH"
tgt="$(readlink "$fakehome/.local/bin/dispatch")"
assert_eq "$tgt" "$PS_REPO_ROOT/bin/dispatch" "symlink points at the repo's bin/dispatch"

# PATH wiring SKIPPED (CCP_SKIP_PATH=1): no symlink created.
fakehome2="$PS_SANDBOX/home2"; mkdir -p "$fakehome2"
HOME="$fakehome2" CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
[ -e "$fakehome2/.local/bin/dispatch" ] && { echo "  FAIL: CCP_SKIP_PATH did not skip the dispatch symlink"; exit 1; }
assert_eq "ok" "ok" "CCP_SKIP_PATH=1 skips the dispatch PATH symlink"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 7: Run it; expect PASS**

Run: `bash tests/dispatch_install_path_test.sh`
Expected: `(… checks, 0 failed)`.

- [ ] **Step 8: Full suite green, then commit**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===`.

```bash
git add commands/dispatch.md lib/install-common.sh \
        tests/dispatch_command_md_test.sh tests/dispatch_install_path_test.sh
git commit -m "$(cat <<'EOF'
feat(dispatch): add /dispatch command + put bin/dispatch on PATH

Subsystem E Phase 1b, Task 7. /dispatch spawns a dispatch cell for a single
(backend, model) worker and gates landing through the orchestrator; it
supersedes /codex-implement (kept as the harness=codex back-compat alias, E8).
install links bin/dispatch into ~/.local/bin (CCP_SKIP_PATH-gated) so the cell
can shell to `dispatch`.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Spec revision note (Status UNCHANGED) + plan close-out

**Files:**
- Modify: `docs/specs/2026-06-13-dispatch-harness-decoupling-design.md` (append to §10, do NOT touch `Status:`)

- [ ] **Step 1: Append a Phase-1b implementation note to the spec's §10**

At the end of the "Resolved in spec review (2026-06-13)" list in §10, add:
```markdown

### Resolved in Phase 1b implementation (2026-06-13)
- **`d_backend_args` left unchanged; `-m` is a separately-appended axis.** `dispatch_backend_ollama_test.sh` pins the existing arm output (incl. the `ollama` arm's default `-m qwen2.5-coder`), so `codex-run` appends `-m <model>` after the transport bundle. For `(codex, *)` this is exactly `-m <model>` (empty bundle); for the one model-conflated `ollama` arm the cell's `-m` wins last (harmless redundant earlier `-m`). Keeps back-compat green while delivering the clean two-axis (AC7).
- **`bin/dispatch` sources the codex adapter** (`lib/dispatch.sh`) for `codex-run`; the portable `lib/dispatch-lib.sh` stays codex-free (Invariant 2). Observability readers are `lib/console.sh`; the `d_event` writer lives in the library so every verb can append.
- **`verify` persists `requested_checks`** (the cmds it ran) so the unchanged `land` can replay them on its post-rebase re-verify for cell-path dispatches.
- **Status line intentionally unchanged** — pending author re-read.
```

- [ ] **Step 2: Confirm `Status:` is untouched**

Run: `grep -n '^- \*\*Status:\*\*' docs/specs/2026-06-13-dispatch-harness-decoupling-design.md`
Expected: still `- **Status:** Approved (design); pending spec review`.

- [ ] **Step 3: Full suite green, then commit**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===`.

```bash
git add docs/specs/2026-06-13-dispatch-harness-decoupling-design.md \
        docs/plans/2026-06-13-dispatch-harness-phase1b.md
git commit -m "$(cat <<'EOF'
docs(subsystem-e): record Phase 1b implementation decisions + plan

Subsystem E Phase 1b, Task 8. Append the implementation-resolved micro-decisions
to the design spec §10 (two-axis via unchanged d_backend_args + appended -m;
bin/dispatch sources the adapter; verify persists requested_checks). Spec Status
line intentionally unchanged pending author re-read.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Acceptance check (Phase 1b done when all true)

- [ ] `bash tests/run.sh` green; **10** new test files (`dispatch_begin`, `dispatch_bakeoff_id`, `dispatch_codex_run`, `dispatch_pair_validation`, `dispatch_cell_spine`, `dispatch_console`, `dispatch_addmodel`, `dispatch_skill_md`, `dispatch_command_md`, `dispatch_install_path`).
- [ ] **AC2:** a `begin → codex-run -m <gpt-model> → verify → record → (orchestrator) land` flow runs; work lands in the **library-owned worktree**; the full diff is NOT auto-dumped. *(cell-spine + codex-run tests)*
- [ ] **AC3:** `attach <id>` renders the event stream; `console` lists `id · harness · backend · model · status · last-activity`, defaulting harness/model for legacy sidecars. *(console test)*
- [ ] **AC5 / E10:** `codex-run` refuses a Claude model and a codex-less non-Claude model, loudly, with the right next move. *(pair-validation test)*
- [ ] **AC7:** new cloud model = `-m` passthrough, no code; new provider = one `d_backend_args` arm, no new files. *(addmodel test)*
- [ ] **Back-compat (E8):** `codex_dispatch.sh` `dispatch`/`resume`/`quick`/`land` unchanged; `d_backend_args` byte-identical (ollama test still green).
- [ ] `lib/dispatch-lib.sh` still sources standalone with no codex/paths/local hard dep (Phase 1a extraction test still green).

## Execution handoff

After the plan is reviewed, choose an execution mode (per superpowers:executing-plans / subagent-driven-development). Each task is independently green and committable, in order (Task 2 depends on Task 1's `begin`/`d_event`; Tasks 3–7 depend on Task 2's `codex-run`; Task 8 closes out).

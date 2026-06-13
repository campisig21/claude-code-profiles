# Subsystem E — Phase 1a (Pure extraction: `lib/dispatch-lib.sh` + `bin/dispatch` + the `d_on_land` hook) — Implementation Plan

> **For agentic workers:** Implemented via the project's **Claude-plans / codex-implements** workflow (REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` or `superpowers:executing-plans`). Each task is a self-contained, independently-landable unit suitable for `/codex-implement` dispatch (`codex_dispatch.sh dispatch --verify checks --check 'bash tests/run.sh' …`), Claude-gated. Steps use checkbox (`- [ ]`) syntax. Tasks are ordered so each leaves `tests/run.sh` green. **This is a pure-refactor phase with zero behavior change** — the existing Subsystem-C suite is the regression net for Tasks 1–4; Task 5 adds the one new isolation/hook test the spec names.

**Goal:** Carve the harness-agnostic primitives **and** the worker-agnostic orchestration commands (`land`/`abandon`/`doctor`/`verification_satisfied`/`emit_*`/`list`/`show`) out of `lib/dispatch.sh` + `codex_dispatch.sh` into a new portable `lib/dispatch-lib.sh`, exposed through a new `bin/dispatch` CLI — while keeping `codex_dispatch.sh`'s existing behavior byte-identical. This is the bisect-clean checkpoint that relocates the safety-critical `land` code before any new dispatch-cell features (Phase 1b) are built on top.

**Architecture:** `lib/dispatch-lib.sh` becomes the **portable library** (the §5.2 left column, from both source files). `lib/dispatch.sh` slims to the **codex adapter** (`d_codex_exec`/`d_codex_resume`/`d_codex_session_id`/`d_backend_args`) and `source`s `dispatch-lib.sh` so every existing caller transparently keeps the full symbol set. `codex_dispatch.sh` keeps the autonomous loop (`cmd_dispatch`/`finish_verify`/`cmd_resume`/`cmd_quick` — E8 back-compat) and routes its shared verbs to the new `d_*` functions. The subsystem-B curator feed inside `land` is pulled into an **overridable `d_on_land` hook** whose default body is guarded by `command -v resolve_active_profile`/`profile_dir`, so the library has **no hard dependency** on `lib/paths.sh` and is a no-op in a portable embedding, yet the feed still fires from both CLIs (which source `paths.sh`). `bin/dispatch` is a thin, symlink-resolving CLI front (the `ccp` pattern) exposing the worker-agnostic verbs.

**Tech Stack:** bash (`#!/usr/bin/env bash`, `set -uo pipefail`), `jq`, git worktrees; the repo's dependency-free bash harness (`tests/lib.sh`, `tests/run.sh` — auto-discovers `*_test.sh`), sandbox-isolated, with the fake-codex double (`CODEX_DISPATCH_CODEX_BIN`) and deterministic ids (`CODEX_DISPATCH_NOW`).

**Spec:** `docs/specs/2026-06-13-dispatch-harness-decoupling-design.md` (decisions E1/E7/E9; §5.2 extraction; §6 Phase 1a; AC1; MC-F/MC-H). Builds on Subsystem C (`docs/specs/2026-05-31-codex-dispatch-design.md`).

---

## File structure (created / modified)

| File | New/Mod | Responsibility |
|---|---|---|
| `lib/dispatch-lib.sh` | **New** | Portable library: identity, git ctx, worktree/gitignore/`d_sync_deps`, sidecar I/O, `d_run_checks`, commit/diff helpers, `die`, `d_emit_*`, `d_verification_satisfied`, `d_list`/`d_show`, `d_land`/`d_abandon`/`d_doctor`, and the overridable `d_on_land` hook. No codex, no hard `paths.sh`/`local.sh` dependency. |
| `lib/dispatch.sh` | Mod (slim) | Codex adapter only (`d_codex_exec`/`d_codex_resume`/`d_codex_session_id`/`d_backend_args`); `source`s `dispatch-lib.sh` at the top (include-guarded). |
| `codex_dispatch.sh` | Mod | Keeps the autonomous loop (`cmd_dispatch`/`finish_verify`/`cmd_resume`/`cmd_quick`) + `main`; routes `list`/`show`/`land`/`abandon`/`doctor` to the moved `d_*`; drops its own `die`/`emit_*`/`verification_satisfied`/`cmd_land`/`cmd_abandon`/`cmd_doctor`/`cmd_list`/`cmd_show`. |
| `bin/dispatch` | **New** | Symlink-resolving CLI front exposing the worker-agnostic verbs (`land`/`abandon`/`doctor`/`list`/`show`); `begin`/`codex-run`/`verify`/`record`/`attach`/`console` reserved for Phase 1b. |
| `tests/dispatch_lib_extraction_test.sh` | **New** | Proves the library is sourceable standalone (carries `d_land`, does **not** drag in the codex adapter), `d_land` lands with only the lib sourced, and `d_on_land` fires when the profile machinery is present / no-ops when absent. |

**Conventions (from the repo):** sourced bash libs; `set -uo pipefail`; standard error exit `die() { echo "codex-dispatch: $*" >&2; exit 1; }`; tests `source "$(dirname "$0")/lib.sh"`, `ps_setup_sandbox` → `ps_make_sandbox_repo`/`ps_make_fake_codex`, `assert_eq`/`assert_contains`/`assert_file`, end with `ps_teardown_sandbox; ps_report; exit $?`; deterministic ids via `CODEX_DISPATCH_NOW`, fake codex via `CODEX_DISPATCH_CODEX_BIN`; `tests/run.sh` globs `*_test.sh` so a correctly-named new test needs **no** registration.

---

## Task 1 — Carve worker-agnostic primitives into `lib/dispatch-lib.sh`

**Files:** Create `lib/dispatch-lib.sh`; Modify `lib/dispatch.sh`. No new test — refactor under the existing suite.

The fault line: `lib/dispatch.sh` today holds both worker-agnostic primitives and the codex adapter. Move the former into `dispatch-lib.sh`; leave the adapter; make `dispatch.sh` source the lib so `codex_dispatch.sh` and every test that does `source lib/dispatch.sh` keep working unchanged.

- [ ] **Step 1: Create `lib/dispatch-lib.sh` with an include guard + the moved primitives.**

Header (new), then **move verbatim** from `lib/dispatch.sh` (cut from there in Step 2) these functions, in order:
`d_now`, `d_slugify`, `d_short`, `d_in_git_repo`, `d_repo_root`, `d_git_dir`, `d_tree_dirty`, `d_cur_branch`, `d_head_sha`, `d_worktree_root`, `d_sidecar_dir`, `d_sidecar_path`, `d_sidecar_exists`, `d_ensure_worktree_gitignore`, `d_sync_deps`, `d_sc_get`, `d_sc_set`, `d_list_ids`, `d_run_checks` (with its `D_CHECKS_JSON='[]'` global), `d_commit_worktree`, `d_changed_files`, `d_diffstat`, `d_full_diff`, `d_has_changes`, `d_touches_tests`.

Start the file with:

```bash
#!/usr/bin/env bash
# lib/dispatch-lib.sh — the harness-agnostic CALLED LIBRARY for dispatch (Subsystem E).
# Portable: knows nothing about codex/workers and has NO hard dependency on
# lib/paths.sh or lib/local.sh. SOURCE this. Depends on lib/jsonutil.sh (js_get).
# Consumed by lib/dispatch.sh (codex adapter), codex_dispatch.sh, and bin/dispatch.
[ -n "${_DISPATCH_LIB_SOURCED:-}" ] && return 0
_DISPATCH_LIB_SOURCED=1

# Standard error exit (shared by every CLI that sources this lib).
die() { echo "codex-dispatch: $*" >&2; exit 1; }

# --- identity ---------------------------------------------------------------
# (moved verbatim from lib/dispatch.sh: d_now, d_slugify, d_short, git ctx,
#  worktree mgmt, gitignore, d_sync_deps, sidecar I/O, d_run_checks, commit/diff)
```

- [ ] **Step 2: Slim `lib/dispatch.sh` to the codex adapter + source the lib.**

Replace the header and delete the moved functions, leaving only `d_codex_exec`, `d_codex_resume`, `d_codex_session_id`, `d_backend_args`. New top of `lib/dispatch.sh`:

```bash
#!/usr/bin/env bash
# lib/dispatch.sh — the codex-family worker ADAPTER. SOURCE this.
# Slimmed in Subsystem E: the harness-agnostic primitives now live in
# lib/dispatch-lib.sh (sourced below); this file is just the codex call site
# (d_codex_exec/_resume/_session_id) + the backend selector (d_backend_args).
# Depends on lib/jsonutil.sh (js_get) being sourced first.
_here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_here/dispatch-lib.sh"

# --- codex invocation (the ONLY place codex is called — see spec R4) --------
```

(Keep `d_codex_exec`/`d_codex_resume`/`d_codex_session_id`/`d_backend_args` exactly as they are.)

- [ ] **Step 3: Verify the suite stays green.**

Run: `bash tests/run.sh`
Expected: same pass count as before this task (every `dispatch_*_test.sh` sources `lib/dispatch.sh` and transparently gets the primitives via the new `source`). This is a refactor under existing coverage.

- [ ] **Step 4: Commit.**

```bash
git add lib/dispatch-lib.sh lib/dispatch.sh
git commit -m "refactor(dispatch): extract harness-agnostic primitives into lib/dispatch-lib.sh"
```

---

## Task 2 — Move read-only orchestration (`emit_*`, `verification_satisfied`, `list`, `show`, `die`) into the lib

**Files:** Modify `lib/dispatch-lib.sh` (add functions); Modify `codex_dispatch.sh` (delete moved defs, rename call sites). No new test — covered by `dispatch_show_list_test.sh` + `dispatch_guardrails_test.sh`.

These functions only read sidecars / format output — they are worker-agnostic and belong in the library. Move them verbatim under `d_`-prefixed names; `codex_dispatch.sh` already sources the lib (via `dispatch.sh`), so its `main` just routes to the new names.

- [ ] **Step 1: Move + rename into `lib/dispatch-lib.sh`** (append after the primitives). Move these from `codex_dispatch.sh` verbatim, renaming the symbol and updating internal references:
  - `emit_next_actions` → `d_emit_next_actions` (body unchanged — **keep the `codex_dispatch.sh …` hint text verbatim** for zero behavior change; re-pointing the hints to `dispatch …` is a Phase-1b concern).
  - `emit_result` → `d_emit_result` (its one call to `emit_next_actions` becomes `d_emit_next_actions`).
  - `verification_satisfied` → `d_verification_satisfied` (body unchanged).
  - `cmd_list` → `d_list` (body unchanged).
  - `cmd_show` → `d_show` (its call to `emit_result` becomes `d_emit_result`).

- [ ] **Step 2: Delete the originals from `codex_dispatch.sh`** — remove its `die()` (line ~13; now provided by the lib, sourced at the top before any use), `emit_next_actions`, `emit_result`, `verification_satisfied`, `cmd_list`, `cmd_show`.

- [ ] **Step 3: Re-point the surviving call sites in `codex_dispatch.sh`.** In `cmd_dispatch` and `cmd_resume`, change `emit_result "$id"` → `d_emit_result "$id"` (two sites in `cmd_dispatch`, two in `cmd_resume`). In `main`, change the arms: `show) d_show "$@" ;;` and `list) d_list "$@" ;;`.

- [ ] **Step 4: Verify.**

Run: `bash tests/run.sh`
Expected: green. `dispatch_show_list_test.sh` (drives `list`/`show` via the engine) and `dispatch_guardrails_test.sh` (asserts the `ALLOWED NEXT ACTIONS` text) confirm the output is byte-identical.

- [ ] **Step 5: Commit.**

```bash
git add lib/dispatch-lib.sh codex_dispatch.sh
git commit -m "refactor(dispatch): move read-only orchestration (emit/verify/list/show) into the library"
```

---

## Task 3 — Move `land`/`abandon`/`doctor` into the lib + extract the `d_on_land` hook (the safety-critical move)

**Files:** Modify `lib/dispatch-lib.sh` (add `d_land`/`d_abandon`/`d_doctor`/`d_on_land`); Modify `codex_dispatch.sh` (delete moved defs, route `main`). No new test — covered by `dispatch_land_test.sh` + `dispatch_doctor_test.sh`. **This is the bisect checkpoint: isolate it so a regression here is unambiguous.**

- [ ] **Step 1: Add the overridable `d_on_land` hook to `lib/dispatch-lib.sh`** (this is the §5.2 / MC-H decision — the subsystem-B feed, pulled out of `land`, default-on but dependency-free):

```bash
# d_on_land <id> — overridable post-land hook. DEFAULT: feed the landed dispatch's
# codex log to the subsystem-B curator inbox, IFF the profile machinery is present
# (resolve_active_profile / profile_dir come from lib/paths.sh, which the CLIs
# source but the library does NOT). A standalone/portable embedding without those
# symbols gets a clean no-op. Redefine this function after sourcing the lib to
# customize. Keeps lib/dispatch-lib.sh free of any hard paths.sh dependency.
d_on_land() {
  local id="$1"
  command -v resolve_active_profile >/dev/null 2>&1 || return 0
  command -v profile_dir          >/dev/null 2>&1 || return 0
  local _prof _inbox _log _task _backend _ts
  _prof="$(resolve_active_profile)"
  _inbox="$(profile_dir "$_prof")/curator/inbox"
  _log="$(d_sidecar_dir)/$id.codexlog.jsonl"
  [ -f "$_log" ] || return 0
  _task="$(d_sc_get "$id" '.prompt')"
  _backend="$(d_sc_get "$id" '.backend')"; [ -n "$_backend" ] || _backend="codex"
  _ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$_inbox"
  jq -nc --arg ts "$_ts" --arg prof "$_prof" --arg id "$id" --arg log "$_log" \
         --arg task "$_task" --arg be "$_backend" \
    '{kind:"codex_run", captured_at:$ts, profile:$prof, dispatch_id:$id,
      log_path:$log, task:$task, backend:$be}' \
    > "$_inbox/${_ts}-codex-${id}.json" 2>/dev/null || true
}
```

- [ ] **Step 2: Move `cmd_land` → `d_land` into the lib, replacing the inline B.2 block with the hook call.** Move the function verbatim, with exactly one change: delete the inline curator-feed block (the `# B.2 feed:` comment through the `fi` that closes `if [ -f "$_log" ]`) and replace it with a single call, so the tail reads:

```bash
  d_sc_set "$id" '.status="landed"|.updated_at=$u' --arg u "$(d_now)"
  d_on_land "$id"
  echo "Landed $id onto $(d_cur_branch) (branch $branch merged, worktree removed)."
}
```

- [ ] **Step 3: Move `cmd_abandon` → `d_abandon` into the lib** (body verbatim).

- [ ] **Step 4: Move `cmd_doctor` → `d_doctor` into the lib, guarding the `local.sh` dependency** so the lib stays importable standalone. Change only the local-backend line:

```bash
  # was: echo "  local backend: $(l_probe)  (endpoint $(l_endpoint))"
  local _lb="n/a (local backend not loaded)"
  command -v l_probe >/dev/null 2>&1 && _lb="$(l_probe)  (endpoint $(l_endpoint))"
  echo "  local backend: $_lb"
```

- [ ] **Step 5: Delete `cmd_land`/`cmd_abandon`/`cmd_doctor` from `codex_dispatch.sh`** and re-point `main`: `land) d_land "$@" ;;`, `abandon) d_abandon "$@" ;;`, `doctor) d_doctor "$@" ;;`.

- [ ] **Step 6: Verify.**

Run: `bash tests/run.sh`
Expected: green. `dispatch_land_test.sh` exercises the happy path, the failed/review/conflict guardrails, and abandon; `dispatch_doctor_test.sh` exercises reconciliation. Behavior is identical because `codex_dispatch.sh` still sources `lib/paths.sh`, so the guarded `d_on_land` default fires exactly as the old inline block did.

- [ ] **Step 7: Commit.**

```bash
git add lib/dispatch-lib.sh codex_dispatch.sh
git commit -m "refactor(dispatch): move land/abandon/doctor into the library behind an injectable d_on_land hook"
```

---

## Task 4 — `bin/dispatch` CLI front (worker-agnostic verbs)

**Files:** Create `bin/dispatch` (executable). Smoke-verified manually here; automated parity lands in Task 5.

- [ ] **Step 1: Create `bin/dispatch`** (the `ccp` symlink-resolving pattern, then route to the `d_*` verbs):

```bash
#!/usr/bin/env bash
# bin/dispatch — the harness-agnostic dispatch CLI (Subsystem E).
# Exposes lib/dispatch-lib.sh primitives as subcommands. The native dispatch
# CELL and the orchestrator shell to this; it initiates nothing on its own.
# Phase 1a surface: the worker-agnostic verbs. Phase 1b adds
# begin/codex-run/verify/record/attach/console.
set -uo pipefail

# Resolve symlinks so `dispatch` works when invoked via a PATH symlink
# (e.g. ~/.local/bin/dispatch -> <repo>/bin/dispatch). macOS has no `readlink -f`.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$DIR/$SOURCE";; esac
done
HERE="$(cd -P "$(dirname "$SOURCE")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

source "$ROOT/lib/jsonutil.sh"
source "$ROOT/lib/dispatch-lib.sh"
source "$ROOT/lib/local.sh"    # d_doctor reports the local backend probe
source "$ROOT/lib/paths.sh"    # enables the default d_on_land curator feed

main() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    land)     d_land "$@" ;;
    abandon)  d_abandon "$@" ;;
    doctor)   d_doctor "$@" ;;
    list)     d_list "$@" ;;
    show)     d_show "$@" ;;
    begin|codex-run|verify|record|attach|console)
      die "'$sub' arrives in Phase 1b — not yet implemented" ;;
    *) die "unknown subcommand: $sub" ;;
  esac
}
main "$@"
```

- [ ] **Step 2: Make it executable.**

Run: `chmod +x bin/dispatch`

- [ ] **Step 3: Smoke-verify parity by hand** (in a throwaway git repo with a dispatch already at `needs_review`, or simply against an empty repo for `list`):

Run: `( cd /tmp && git init -q dz && cd dz && "$PWD/../.."/bin/dispatch list )` — adjust the path; expected: `No dispatches for this repo.` (identical to `codex_dispatch.sh list`).

- [ ] **Step 4: Commit.**

```bash
git add bin/dispatch
git commit -m "feat(dispatch): add bin/dispatch CLI front for the harness-agnostic verbs"
```

---

## Task 5 — `tests/dispatch_lib_extraction_test.sh` (standalone library + `d_on_land` hook + CLI parity)

**Files:** Create `tests/dispatch_lib_extraction_test.sh`. Auto-discovered by `tests/run.sh` (no registration).

This is the new guarantee the spec names: the library is sourceable in isolation, `d_land` lands with **only** the lib sourced (no `codex_dispatch.sh`), and the `d_on_land` hook fires/no-ops correctly. Part C confirms `bin/dispatch` is at parity with the engine.

- [ ] **Step 1: Write the test.**

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"

# --- Part A: the library is sourceable STANDALONE (no codex_dispatch.sh, no adapter) ---
drv="$PS_SANDBOX/lib-only.sh"; cat > "$drv" <<'EOF'
set -uo pipefail
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
printf 'slug=%s\n'      "$(d_slugify 'Hello, World! 123')"
printf 'has_land=%s\n'  "$(command -v d_land      >/dev/null && echo yes || echo no)"
printf 'has_codex=%s\n' "$(command -v d_codex_exec >/dev/null && echo yes || echo no)"
EOF
out="$(PS_REPO_ROOT="$PS_REPO_ROOT" bash "$drv" 2>&1)"
assert_contains "$out" "slug=hello-world-123" "d_slugify works with only dispatch-lib sourced"
assert_contains "$out" "has_land=yes"  "library carries d_land standalone"
assert_contains "$out" "has_codex=no"  "library does NOT pull in the codex adapter (clean one-way seam)"

# --- Part B: d_land + the d_on_land hook, driven with ONLY the library sourced ---
# Reach needs_review via the engine (we are testing land/hook, not dispatch).
ro="$(ps_make_sandbox_repo ok)"
( cd "$ro" && CODEX_DISPATCH_NOW=20260613T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    FAKE_CODEX_BEHAVIOR=pass bash "$ENGINE" dispatch --verify checks \
    --check 'bash check.sh' --retry 1 --slug land-iso "do x" >/dev/null 2>&1 )
id="20260613T120000Z-land-iso"

land_drv="$PS_SANDBOX/land-iso.sh"; cat > "$land_drv" <<'EOF'
set -uo pipefail
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
if [ "${WITH_PROFILE:-0}" = 1 ]; then
  resolve_active_profile() { printf 'testprof\n'; }
  profile_dir()           { printf '%s/profiles/%s\n' "$CC_PROFILE_ROOT" "$1"; }
fi
cd "$REPO"
d_land "$ID"
EOF

# B1: profile machinery present => land succeeds AND the curator inbox json appears.
inbox="$CC_PROFILE_ROOT/profiles/testprof/curator/inbox"
REPO="$ro" ID="$id" WITH_PROFILE=1 PS_REPO_ROOT="$PS_REPO_ROOT" \
  CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$land_drv" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "d_land lands with only dispatch-lib sourced"
assert_eq "$(cat "$ro/IMPL")" "ok" "standalone d_land merged the change into the working tree"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$id" '.status')" "landed" "sidecar status landed" )
hit="$(ls "$inbox"/*-codex-"$id".json 2>/dev/null | head -1)"
assert_file "$hit" "d_on_land fired: curator inbox json written when profile present"

# B2: no profile machinery => land still succeeds; hook is a clean no-op.
ro2="$(ps_make_sandbox_repo ok2)"
( cd "$ro2" && CODEX_DISPATCH_NOW=20260613T121000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    FAKE_CODEX_BEHAVIOR=pass bash "$ENGINE" dispatch --verify checks \
    --check 'bash check.sh' --retry 1 --slug land-iso2 "do x" >/dev/null 2>&1 )
id2="20260613T121000Z-land-iso2"
REPO="$ro2" ID="$id2" WITH_PROFILE=0 PS_REPO_ROOT="$PS_REPO_ROOT" \
  CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$land_drv" >/dev/null 2>&1; rc2=$?
assert_eq "$rc2" "0" "d_land lands even with no profile machinery (portable embedding)"
assert_eq "$(cat "$ro2/IMPL")" "ok" "standalone d_land merged without the hook firing"

# --- Part C: bin/dispatch is at parity with the engine for the moved verbs ---
rc3="$(ps_make_sandbox_repo cli)"
a="$( cd "$rc3" && bash "$ENGINE" list 2>&1 )"
b="$( cd "$rc3" && bash "$PS_REPO_ROOT/bin/dispatch" list 2>&1 )"
assert_eq "$b" "$a" "bin/dispatch list matches codex_dispatch.sh list"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it to verify it passes.**

Run: `bash tests/dispatch_lib_extraction_test.sh`
Expected: `(N checks, 0 failed)` and exit 0.

- [ ] **Step 3: Run the whole suite.**

Run: `bash tests/run.sh`
Expected: all files pass, including the new one.

- [ ] **Step 4: Commit.**

```bash
git add tests/dispatch_lib_extraction_test.sh
git commit -m "test(dispatch): standalone library + d_on_land hook + bin/dispatch parity"
```

---

## Sequencing & landing

1 → 2 → 3 → 4 → 5, in order. Each task lands via `/codex-implement` with `--verify checks --check 'bash tests/run.sh'`, Claude-gated. Tasks 1–4 are behavior-preserving refactors held green by the **existing** Subsystem-C suite; Task 3 (the `land` relocation) is deliberately isolated so any regression bisects to one commit. Task 5 adds the new isolation/hook coverage and is the AC checkpoint for "C's existing tests still pass against the slimmed `dispatch.sh`" plus the standalone-library guarantee.

After Task 5: the seam exists and is proven. Phase 1b (separate plan) builds on it — `begin`/`codex-run`/`verify`/`record`, the sidecar `harness`/`model` fields, `console.sh` (`attach`/`console`), `skills/dispatch/SKILL.md`, `/dispatch`, and wiring `bin/dispatch` onto PATH via `install.sh` (the `ccp` symlink mechanism).

## Out of scope (Phase 1a) — deliberately deferred to keep this diff minimal

- **Relocating the autonomous loop** (`cmd_dispatch`/`finish_verify`/`cmd_resume`/`cmd_quick`) from `codex_dispatch.sh` into `lib/dispatch.sh` to make `codex_dispatch.sh` a truly thin front (the §5.1 end-state). It is cosmetic churn with no behavior change and is kept out of the safety-critical `land` move. Defer to 1b or a follow-up cleanup task.
- **Re-pointing `d_emit_next_actions` hint text** from `codex_dispatch.sh …` to `dispatch …` — a behavior change to user-facing output; do it in 1b alongside `/dispatch`.
- **The new subcommands** `begin`/`codex-run`/`verify`/`record`/`attach`/`console`, the `harness`/`model` sidecar fields, the event log, and `console.sh` — all Phase 1b.
- **`install.sh` PATH symlink for `bin/dispatch`** — wired in 1b when the cell needs it on PATH; until then invoke by absolute path / profile symlink.

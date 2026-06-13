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

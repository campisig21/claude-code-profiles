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

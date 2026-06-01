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

# input guards: non-integer --retry is refused BEFORE any worktree is created
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" dispatch --retry abc --check true "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "non-integer --retry refused"
assert_contains "$out" "integer" "explains --retry must be an integer"

# an explicit --slug with slashes/spaces/caps is sanitized; the dispatch still succeeds
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260531T125900Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug 'Feat/Bar Baz' "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "sanitized --slug dispatch succeeds"
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_contains "$(d_sc_get 20260531T125900Z-feat-bar-baz '.branch')" "codex/feat-bar-baz-" "slug sanitized in branch"
)

ps_teardown_sandbox
ps_report; exit $?

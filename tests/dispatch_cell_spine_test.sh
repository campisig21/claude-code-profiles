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

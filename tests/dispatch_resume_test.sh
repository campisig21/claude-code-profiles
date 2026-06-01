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

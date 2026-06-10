#!/usr/bin/env bash
# NO-OP detection: a backend run that produces zero file changes must surface as a
# distinct 'noop' status (loud + resumable), never masquerade as needs_review, and
# never silently burn the retry budget in the auto-correct loop.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"

# ---------------------------------------------------------------------------
# 1) Fresh dispatch where the model changes nothing → status 'noop'.
#    verify=checks is requested, but the engine must NOT run/trust checks on an
#    empty tree and must NOT report needs_review.
# ---------------------------------------------------------------------------
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260601T100000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        FAKE_CODEX_BEHAVIOR=noop \
        bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug zilch "do nothing" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "noop dispatch exits 0"
assert_contains "$out" "noop" "status surfaced as noop"
assert_contains "$out" "no changes" "explains the model produced no changes"
case "$out" in *needs_review*) echo "  FAIL: noop masqueraded as needs_review"; PS_FAILS=$((PS_FAILS+1)); echo x >> "$PS_COUNT_DIR/fails";; esac
assert_contains "$out" "ALLOWED NEXT ACTIONS" "next-actions block present on noop"
assert_contains "$out" "resume" "noop next-actions offer resume"

id="20260601T100000Z-zilch"
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_sc_get "$id" '.status')" "noop" "sidecar status is noop"
  # no checks should have been recorded (we never trusted the empty tree)
  assert_eq "$(d_sc_get "$id" '.checks | length')" "0" "no checks recorded on noop"
  wt="$(d_sc_get "$id" '.worktree')"
  assert_file "$wt" "worktree kept for a noop (resumable)"
)

# ---------------------------------------------------------------------------
# 2) A noop dispatch is resumable: a resume that DOES make changes recovers it
#    to needs_review with passing checks.
# ---------------------------------------------------------------------------
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260601T100500Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        bash "$ENGINE" resume "$id" "actually do the work this time" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "resume of a noop exits 0"
assert_contains "$out" "needs_review" "resume recovers noop to needs_review"
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_sc_get "$id" '.status')" "needs_review" "sidecar recovered to needs_review"
)

# ---------------------------------------------------------------------------
# 3) Auto-retry loop: the exec makes a (failing) change, every corrective resume
#    no-ops. The engine must STOP at the first no-op resume → 'failed', WITHOUT
#    spinning the whole retry budget.
# ---------------------------------------------------------------------------
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260601T101000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        FAKE_CODEX_BEHAVIOR=fail FAKE_CODEX_RESUME_BEHAVIOR=noop \
        bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --retry 3 --slug stuck "try" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "stuck dispatch exits 0"
assert_contains "$out" "failed" "stuck dispatch ends failed"
assert_contains "$out" "no changes" "explains the corrective resume produced no changes"
id3="20260601T101000Z-stuck"
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_sc_get "$id3" '.status')" "failed" "sidecar status failed"
  # broke on the FIRST no-op corrective resume — did not consume retries 1..3
  assert_eq "$(d_sc_get "$id3" '.retries_used')" "0" "retry budget not burned by a stuck model"
)

# ---------------------------------------------------------------------------
# 4) quick (in-place) no-op prints a clear no-change notice rather than an
#    ambiguous empty diff.
# ---------------------------------------------------------------------------
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_BEHAVIOR=noop \
        bash "$ENGINE" quick --snapshot "do nothing in place" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "quick noop exits 0"
assert_contains "$out" "no changes" "quick noop states no changes were made"

ps_teardown_sandbox
ps_report; exit $?

#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"

# --backend local is REFUSED when the model is not ready, with the local-up hint
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        bash "$ENGINE" dispatch --backend local --verify checks --check 'bash check.sh' "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "local dispatch refused when not ready"
assert_contains "$out" "local-up" "refusal names the fix"
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_list_ids | wc -l | tr -d ' ')" "0" "no sidecar/worktree created on refusal" )

# --backend local PROCEEDS when ready
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260601T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        CODEX_DISPATCH_FAKE_STATE=ready \
        bash "$ENGINE" dispatch --backend local --verify checks --check 'bash check.sh' --slug loc "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "local dispatch proceeds when ready"
assert_contains "$out" "needs_review" "reaches needs_review"

# bogus backend is refused up front
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" \
        bash "$ENGINE" dispatch --backend nope --check true "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "bogus backend refused"
assert_contains "$out" "codex|local" "lists valid backends"

ps_teardown_sandbox
ps_report; exit $?

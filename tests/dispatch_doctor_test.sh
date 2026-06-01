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

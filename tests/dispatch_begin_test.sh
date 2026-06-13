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

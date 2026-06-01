#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

run() { ( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" "$@" 2>&1 ); }

# dispatch outside a repo
o="$( cd "$PS_SANDBOX" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" dispatch --check true "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "dispatch refused outside repo"

# invalid verify mode
o="$(run dispatch --verify bogus "x")"; rc=$?
assert_eq "$rc" "1" "invalid verify refused"

# unknown id across commands
for c in show land resume abandon; do
  o="$(run "$c" ghost ${c:+x})"; rc=$?
  assert_eq "$rc" "1" "$c unknown id refused"
done

# every terminal-state command prints ALLOWED NEXT ACTIONS
( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
   bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug g "x" >/dev/null 2>&1 )
id="20260531T120000Z-g"
assert_contains "$(run show "$id")" "ALLOWED NEXT ACTIONS" "show emits next actions"

# land refused on wrong status (force-set to running)
( cd "$repo"; d_sc_set "$id" '.status="running"' )
o="$(run land "$id")"; rc=$?
assert_eq "$rc" "1" "land refused on running status"
( cd "$repo"; d_sc_set "$id" '.status="needs_review"' )   # restore

ps_teardown_sandbox
ps_report; exit $?

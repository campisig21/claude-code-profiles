#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CLI="$PS_REPO_ROOT/bin/curator"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$CLI" pause default >/dev/null 2>&1
assert_eq "$(jq -r '.paused' "$CC_PROFILE_ROOT/.curator_state")" "true" "pause sets flag"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$CLI" resume default >/dev/null 2>&1
assert_eq "$(jq -r '.paused' "$CC_PROFILE_ROOT/.curator_state")" "false" "resume clears flag"

out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$CLI" status default 2>&1)"
assert_contains "$out" "run_count" "status shows metrics"

ps_teardown_sandbox
ps_report; exit $?

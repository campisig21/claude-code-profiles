#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$PS_REPO_ROOT/lib/jsonutil.sh"
ps_setup_sandbox

# curator state init
state="$CC_PROFILE_ROOT/.curator_state"
js_init_curator_state "$state"
assert_file "$state" "state created"
assert_eq "$(jq -r '.paused' "$state")" "false" "paused default false"
assert_eq "$(jq -r '.run_count' "$state")" "0" "run_count default 0"
assert_eq "$(jq -r '.last_run_at' "$state")" "null" "last_run_at null"
# idempotent: mutate then re-init must not clobber
jq '.run_count = 5' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
js_init_curator_state "$state"
assert_eq "$(jq -r '.run_count' "$state")" "5" "init idempotent (no clobber)"

# js_get
assert_eq "$(js_get "$state" '.run_count')" "5" "js_get field"
assert_eq "$(js_get "$state" '.last_run_at')" "" "js_get null -> empty"
assert_eq "$(js_get /no/such/file '.x')" "" "js_get missing file -> empty"

# hook merge (additive + idempotent)
s="$CC_PROFILE_ROOT/settings.json"
js_merge_command_hook "$s" SessionStart "bash /abs/profile-wakeup.sh"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | length' "$s")" "1" "one SessionStart hook"
js_merge_command_hook "$s" SessionStart "bash /abs/profile-wakeup.sh"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | length' "$s")" "1" "merge idempotent"
js_merge_command_hook "$s" Stop "bash /abs/learn-capture.sh"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" "bash /abs/learn-capture.sh" "Stop hook added"
assert_eq "$(jq -r '.enabledPlugins["superpowers@official"]' "$s")" "true" "existing keys preserved"

ps_teardown_sandbox
ps_report; exit $?

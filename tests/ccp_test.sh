#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
fake="$(ps_make_fake_claude)"
CCP="$PS_REPO_ROOT/bin/ccp"

# default profile: no arg -> CLAUDE_CONFIG_DIR unset, CLAUDE_PROFILE=default
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CCP_CLAUDE_BIN="$fake" bash "$CCP")"
assert_contains "$out" "CLAUDE_CONFIG_DIR=<unset>" "default unsets config dir"
assert_contains "$out" "CLAUDE_PROFILE=default" "default profile name"
assert_eq "$(cat "$CC_PROFILE_ROOT/active_profile")" "default" "active_profile=default"

# missing named profile -> error, exit 1, no launch
set +e
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CCP_CLAUDE_BIN="$fake" bash "$CCP" ghost 2>&1)"; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "missing profile exits 1"
assert_contains "$out" "not found" "missing profile message"

# existing named profile -> sets config dir + profile + active_profile, passes args
mkdir -p "$CC_PROFILE_ROOT/profiles/work"
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CCP_CLAUDE_BIN="$fake" bash "$CCP" work --resume)"
assert_contains "$out" "CLAUDE_CONFIG_DIR=$CC_PROFILE_ROOT/profiles/work" "config dir set"
assert_contains "$out" "CLAUDE_PROFILE=work" "profile name set"
assert_contains "$out" "ARGS=--resume" "args forwarded"
assert_eq "$(cat "$CC_PROFILE_ROOT/active_profile")" "work" "active_profile=work"

ps_teardown_sandbox
ps_report; exit $?

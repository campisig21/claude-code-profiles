#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
FLAG="$PS_REPO_ROOT/bin/learn-flag"

out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$FLAG" \
        --type skill --title "ripgrep over grep" \
        --body "Prefer rg for code search" --context "came up debugging" 2>&1)"; rc=$?
assert_eq "$rc" "0" "learn-flag succeeds"
f="$(find "$CC_PROFILE_ROOT/curator/inbox" -type f -name '*.json' | head -1)"
assert_file "$f" "candidate written to inbox"
assert_eq "$(jq -r '.kind' "$f")" "flag" "kind=flag"
assert_eq "$(jq -r '.type' "$f")" "skill" "type carried"
assert_eq "$(jq -r '.title' "$f")" "ripgrep over grep" "title carried"

n0="$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$FLAG" --type skill --body x >/dev/null 2>&1; rc2=$?
n1="$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')"
assert_eq "$rc2" "1" "missing --title rejected"
assert_eq "$n0" "$n1" "rejected flag writes nothing"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$FLAG" --type bogus --title t --body b >/dev/null 2>&1
assert_eq "$?" "1" "invalid type rejected"

ps_teardown_sandbox
ps_report; exit $?

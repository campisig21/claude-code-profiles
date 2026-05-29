#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
MGMT="$PS_REPO_ROOT/profile_mgmt.sh"

# Pre-stage _shared so symlink targets exist (install.sh does this for real).
mkdir -p "$CC_PROFILE_ROOT/profiles/_shared"
ln -sfn "$PS_REPO_ROOT/hooks"     "$CC_PROFILE_ROOT/profiles/_shared/hooks"
ln -sfn "$PS_REPO_ROOT/commands"  "$CC_PROFILE_ROOT/profiles/_shared/commands"
ln -sfn "$PS_REPO_ROOT/skills"    "$CC_PROFILE_ROOT/profiles/_shared/skills"
ln -sfn "$PS_REPO_ROOT/templates" "$CC_PROFILE_ROOT/profiles/_shared/templates"

out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work 2>&1)"; rc=$?
assert_eq "$rc" "0" "create succeeds"
P="$CC_PROFILE_ROOT/profiles/work"
assert_file "$P/CLAUDE.md" "persona created"
assert_contains "$(cat "$P/CLAUDE.md")" "work Profile" "persona name substituted"
assert_file "$P/settings.json" "settings created"
assert_eq "$(jq -r '.enabledPlugins["superpowers@official"]' "$P/settings.json")" "true" "inherited plugins"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | any(test("profile-wakeup"))' "$P/settings.json")" "true" "wakeup hook registered"
assert_eq "$(jq '[.hooks.Stop[].hooks[].command] | any(test("learn-capture"))' "$P/settings.json")" "true" "stop hook registered"
assert_file "$P/.curator_state" "curator state created"
assert_eq "$(jq -r '.run_count' "$P/.curator_state")" "0" "curator state init"
assert_symlink "$P/plugins" "plugins symlinked"
assert_symlink "$P/commands/profile.md" "command symlinked"
[ -d "$P/skills" ] && assert_eq dir dir "skills dir" || assert_eq nodir dir "skills dir missing"
[ -d "$P/curator/inbox" ] && assert_eq ok ok "inbox dir" || assert_eq no ok "inbox missing"

# duplicate create fails
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "duplicate create fails"

# reserved names fail
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create default >/dev/null 2>&1; r1=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create _shared >/dev/null 2>&1; r2=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create "bad/name" >/dev/null 2>&1; r3=$?
set -e 2>/dev/null || true
assert_eq "$r1" "1" "reserved: default"
assert_eq "$r2" "1" "reserved: _shared"
assert_eq "$r3" "1" "invalid: slash"

ps_teardown_sandbox
ps_report; exit $?

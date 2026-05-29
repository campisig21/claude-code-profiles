#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
MGMT="$PS_REPO_ROOT/profile_mgmt.sh"

mkdir -p "$CC_PROFILE_ROOT/profiles/_shared"
ln -sfn "$PS_REPO_ROOT/templates" "$CC_PROFILE_ROOT/profiles/_shared/templates"
ln -sfn "$PS_REPO_ROOT/hooks"    "$CC_PROFILE_ROOT/profiles/_shared/hooks"
ln -sfn "$PS_REPO_ROOT/commands" "$CC_PROFILE_ROOT/profiles/_shared/commands"
ln -sfn "$PS_REPO_ROOT/skills"   "$CC_PROFILE_ROOT/profiles/_shared/skills"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work >/dev/null 2>&1

# switch: prints the ccp command, does not move anything
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" switch work)"
assert_contains "$out" "ccp work" "switch prints ccp command"

# doctor: repairs a deliberately broken plugins symlink
rm -f "$CC_PROFILE_ROOT/profiles/work/plugins"
ln -sfn "/nonexistent/target" "$CC_PROFILE_ROOT/profiles/work/plugins"
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" doctor work 2>&1)"
assert_contains "$out" "repair" "doctor reports a repair"
assert_eq "$(readlink "$CC_PROFILE_ROOT/profiles/work/plugins")" "$CC_PROFILE_ROOT/plugins" "plugins relinked"

# archive: moves to profiles/.archived/work, never deletes
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" archive work 2>&1)"; rc=$?
assert_eq "$rc" "0" "archive succeeds"
[ -d "$CC_PROFILE_ROOT/profiles/work" ] && assert_eq present absent "work should be moved" || assert_eq absent absent "work moved"
assert_file "$CC_PROFILE_ROOT/profiles/.archived/work/CLAUDE.md" "archived copy exists"

# archiving default is refused
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" archive default >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "cannot archive default"

ps_teardown_sandbox
ps_report; exit $?

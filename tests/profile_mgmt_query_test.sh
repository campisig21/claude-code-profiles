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
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" provision work >/dev/null 2>&1
echo "work" > "$CC_PROFILE_ROOT/active_profile"

# list: shows default + work, marks active
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" list)"
assert_contains "$out" "default" "list shows default"
assert_contains "$out" "work" "list shows work"
assert_contains "$out" "*" "active marker present"

# show: persona + counts
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" show work)"
assert_contains "$out" "work" "show names profile"
assert_contains "$out" "Skills" "show lists skills count"

# status: curator state of work
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" status work)"
assert_contains "$out" "paused" "status shows paused flag"
assert_contains "$out" "run_count" "status shows run_count"

# cmd_show must not crash on an empty CLAUDE.md (grep no-match under set -e)
: > "$CC_PROFILE_ROOT/profiles/work/CLAUDE.md"   # truncate to empty
set +e
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" show work 2>&1)"; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "0" "show survives empty CLAUDE.md"
assert_contains "$out" "Persona: (none)" "empty CLAUDE.md -> persona none"

# list and no-arg status agree on the active profile (from active_profile file, no env)
echo "work" > "$CC_PROFILE_ROOT/active_profile"
out_list="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE= CLAUDE_CONFIG_DIR= bash "$MGMT" list)"
assert_contains "$out_list" "work *" "list marks file-active profile"
out_status="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE= CLAUDE_CONFIG_DIR= bash "$MGMT" status)"
assert_contains "$out_status" "for 'work'" "no-arg status uses same active profile as list"

ps_teardown_sandbox
ps_report; exit $?

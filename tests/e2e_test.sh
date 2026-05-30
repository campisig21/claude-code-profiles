#!/usr/bin/env bash
# Exercises install -> create -> ccp(stub) -> wakeup against a sandbox.
# Covers spec §5 criteria reachable without launching real claude.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
fake="$(ps_make_fake_claude)"

# Seed default settings with an existing hook
cat > "$CC_PROFILE_ROOT/settings.json" <<'JSON'
{ "enabledPlugins": {"superpowers@official": true},
  "hooks": {"SessionStart":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/role-wakeup.sh"}]}]} }
JSON

# §A install + adopt
CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/install.sh" >/dev/null 2>&1

# §5.1 create scaffolds everything
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/profile_mgmt.sh" create demo >/dev/null 2>&1
assert_file "$CC_PROFILE_ROOT/profiles/demo/CLAUDE.md" "5.1 persona"
assert_symlink "$CC_PROFILE_ROOT/profiles/demo/plugins" "5.1 plugins link"

# §5.2 ccp sets env + active_profile
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CCP_CLAUDE_BIN="$fake" bash "$PS_REPO_ROOT/bin/ccp" demo)"
assert_contains "$out" "CLAUDE_CONFIG_DIR=$CC_PROFILE_ROOT/profiles/demo" "5.2 config dir"
assert_contains "$out" "CLAUDE_PROFILE=demo" "5.2 profile env"
assert_eq "$(cat "$CC_PROFILE_ROOT/active_profile")" "demo" "5.2 active_profile"

# §5.4 shared skills present in profile (placeholders resolve)
assert_symlink "$CC_PROFILE_ROOT/profiles/demo/skills/codex-implement" "5.4 codex-implement skill"

# §5.6 wakeup block correct for the profile
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=demo \
       CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/demo" bash "$PS_REPO_ROOT/hooks/profile-wakeup.sh")"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "PROFILE WAKEUP: demo" "5.6 wakeup header"
assert_contains "$ctx" "0 pending" "5.6 zero pending on fresh profile"

# §5.7 default profile additive: role-wakeup preserved, profile hooks added
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command]|any(test("role-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "5.7 role hook preserved"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command]|any(test("profile-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "5.7 profile hook added"

# §5.9 mismatch guard
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=demo \
       CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/WRONG" bash "$PS_REPO_ROOT/hooks/profile-wakeup.sh")"
assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" "PROFILE MISMATCH" "5.9 guard"

ps_teardown_sandbox
ps_report; exit $?

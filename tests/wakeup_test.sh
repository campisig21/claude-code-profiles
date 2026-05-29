#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
HOOK="$PS_REPO_ROOT/hooks/profile-wakeup.sh"

# default profile: emits wakeup JSON with additionalContext naming "default"
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=default bash "$HOOK")"
assert_contains "$out" '"hookEventName": "SessionStart"' "wakeup is SessionStart"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "PROFILE WAKEUP: default" "default wakeup header"
assert_contains "$ctx" "Curator:" "curator status line present"

# named profile with persona + pending inbox + one learned skill
mkdir -p "$CC_PROFILE_ROOT/profiles/work/skills/my-skill" \
         "$CC_PROFILE_ROOT/profiles/work/curator/inbox"
printf '# Work Profile\nBackend specialist.\n' > "$CC_PROFILE_ROOT/profiles/work/CLAUDE.md"
echo '{}' > "$CC_PROFILE_ROOT/profiles/work/curator/inbox/item1.json"
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=work \
        CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/work" bash "$HOOK")"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "PROFILE WAKEUP: work" "named header"
assert_contains "$ctx" "Persona: Work Profile" "persona summary has leading # stripped"
assert_contains "$ctx" "1 pending" "pending inbox count"
assert_contains "$ctx" "1 learned skill" "learned skill count"

# mismatch guard: CLAUDE_PROFILE=work but config dir points elsewhere
out="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=work \
        CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/OTHER" bash "$HOOK")"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "PROFILE MISMATCH" "mismatch guard fires"

ps_teardown_sandbox
ps_report; exit $?

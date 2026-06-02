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

# --- curator notification surfaced + consumed ---
mkdir -p "$CC_PROFILE_ROOT/curator/notifications"
cat > "$CC_PROFILE_ROOT/curator/notifications/20260601T000000Z.json" <<'EOF'
{"run_at":"20260601T000000Z","created":["skill:use-rg"],"updated":[],"pruned":["skill:stale"],"merged":[],"summary":"1 created, 1 pruned"}
EOF
ctx="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/hooks/profile-wakeup.sh" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "CURATOR UPDATE" "curator update block present"
assert_contains "$ctx" "use-rg" "created skill shown"
assert_contains "$ctx" "stale" "pruned skill shown"
moved="$(find "$CC_PROFILE_ROOT/curator/notifications/shown" -type f -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$moved" "1" "notification moved to shown/"
remain="$(find "$CC_PROFILE_ROOT/curator/notifications" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$remain" "0" "notification consumed from queue"

ps_teardown_sandbox
ps_report; exit $?

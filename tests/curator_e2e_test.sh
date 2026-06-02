#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/skills"; printf '# default\n@curator/INDEX.md\n' > "$CC_PROFILE_ROOT/CLAUDE.md"
mkdir -p "$CC_PROFILE_ROOT/curator"; echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"

# 1. flag via bin/learn-flag
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/bin/learn-flag" \
  --type skill --title "use rg" --body "prefer ripgrep" --context "search" >/dev/null 2>&1

# 2. run with a fake claude that creates the skill
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"decisions":[{"action":"create","kind":"skill","name":"use-rg","path":"skills/use-rg/SKILL.md","content":"---\nname: use-rg\ndescription: use ripgrep\n---\n# use rg","use_when":"searching","reason":"flagged"}],"new_skill_candidates":[]}'
EOF
chmod +x "$fakebin/claude"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$PS_REPO_ROOT/bin/curator.py" run default >/dev/null 2>&1

# 3. assert end-state
assert_file "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md" "skill filed"
assert_contains "$(cat "$CC_PROFILE_ROOT/curator/INDEX.md")" "use-rg" "INDEX updated"
ctx="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/hooks/profile-wakeup.sh" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "CURATOR UPDATE" "wakeup shows the new skill"

ps_teardown_sandbox
ps_report; exit $?

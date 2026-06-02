#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox" "$CC_PROFILE_ROOT/skills/use-rg"
echo "# use rg" > "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"

tdir="$PS_SANDBOX/transcripts"; mkdir -p "$tdir"
cat > "$tdir/t1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"use-rg"}}]}}
EOF
echo "{\"session_id\":\"s1\",\"transcript_path\":\"$tdir/t1.jsonl\",\"cwd\":\"/w\",\"ended_at\":\"x\"}" \
  > "$CC_PROFILE_ROOT/curator/sessions.jsonl"

fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"decisions":[],"new_skill_candidates":[]}'
EOF
chmod +x "$fakebin/claude"
echo '{"kind":"flag","type":"auto","title":"t","body":"b","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c1.json"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
stats="$CC_PROFILE_ROOT/curator/skill-stats.json"
assert_file "$stats" "skill-stats written"
assert_eq "$(jq -r '."use-rg".times_triggered' "$stats")" "1" "usage counted from transcript"
assert_eq "$(jq -r '."use-rg".runs_since_used' "$stats")" "0" "runs_since_used reset on use"

ps_teardown_sandbox
ps_report; exit $?

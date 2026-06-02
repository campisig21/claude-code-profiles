#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox" "$CC_PROFILE_ROOT/skills/use-rg"
echo "# use rg" > "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"

logdir="$PS_SANDBOX/logs"; mkdir -p "$logdir"
cat > "$logdir/d1.codexlog.jsonl" <<'EOF'
{"type":"item.completed","item":{"type":"tool_use","name":"Skill","input":{"skill":"use-rg"}}}
{"type":"item.completed","item":{"type":"command_execution","command":"rg foo"}}
EOF
cat > "$CC_PROFILE_ROOT/curator/inbox/codex1.json" <<EOF
{"kind":"codex_run","profile":"default","dispatch_id":"d1","log_path":"$logdir/d1.codexlog.jsonl","task":"x","backend":"local"}
EOF

fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"decisions":[],"new_skill_candidates":[{"title":"do X","rationale":"repeated","source_backend":"local"}]}'
EOF
chmod +x "$fakebin/claude"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
stats="$CC_PROFILE_ROOT/curator/skill-stats.json"
assert_eq "$(jq -r '."use-rg".times_triggered' "$stats")" "1" "local run additive: usage counted"

mined="$(grep -l 'do X' "$CC_PROFILE_ROOT"/curator/inbox/*.json 2>/dev/null | head -1)"
assert_file "$mined" "mined candidate re-queued"
assert_eq "$(jq -r '.kind' "$mined")" "flag" "mined candidate is a flag"
assert_eq "$(jq -r '.source_backend' "$mined")" "local" "mined candidate tagged local provenance"

ps_teardown_sandbox
ps_report; exit $?

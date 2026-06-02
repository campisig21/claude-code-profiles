#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"

fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo "Sure! Here is the plan:"
echo '```json'
echo '{"decisions":[{"action":"skip","candidate_ref":"c1","reason":"dup"}],"new_skill_candidates":[]}'
echo '```'
EOF
chmod +x "$fakebin/claude"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
echo '{"kind":"flag","type":"auto","title":"t","body":"b","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c1.json"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')" "0" "fenced-JSON parsed; inbox drained on skip"

cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo "no json here at all"
EOF
echo '{"kind":"flag","type":"auto","title":"t2","body":"b2","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c2.json"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f -name c2.json | wc -l | tr -d ' ')" "1" "malformed -> candidate retained"
assert_eq "$(jq -r '.failures_total' "$CC_PROFILE_ROOT/.curator_state")" "1" "failures_total bumped"

ps_teardown_sandbox
ps_report; exit $?

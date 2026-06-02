#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"

mkdir -p "$CC_PROFILE_ROOT/curator/inbox" "$CC_PROFILE_ROOT/skills"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
echo '{"kind":"flag","type":"skill","title":"use rg","body":"prefer ripgrep","context":"search"}' \
  > "$CC_PROFILE_ROOT/curator/inbox/c1.json"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"

fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"decisions":[{"action":"create","kind":"skill","name":"use-rg",
  "path":"skills/use-rg/SKILL.md","content":"# use rg\nPrefer ripgrep.","use_when":"searching code","reason":"flagged"}],
 "new_skill_candidates":[]}
JSON
EOF
chmod +x "$fakebin/claude"
cat > "$fakebin/flock" <<'EOF'
#!/usr/bin/env python3
import fcntl
import os
import sys

fd = int(sys.argv[1])
fcntl.flock(fd, fcntl.LOCK_EX)
os.read(0, 1)
EOF
chmod +x "$fakebin/flock"
export PATH="$fakebin:$PATH"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" \
  CURATOR_IDLE_THRESHOLD_SECONDS=600 python3 "$CURATOR" run default >/dev/null 2>&1

assert_file "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md" "skill created"
assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')" "0" "inbox drained"
assert_eq "$(jq -r '.run_count' "$CC_PROFILE_ROOT/.curator_state")" "1" "run_count bumped"
assert_eq "$(jq -r '.accepted_total' "$CC_PROFILE_ROOT/.curator_state")" "1" "accepted metric"
nf="$(find "$CC_PROFILE_ROOT/curator/notifications" -type f -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$nf" "1" "notification emitted"

echo '{"kind":"flag","type":"memory","title":"x","body":"y","context":""}' \
  > "$CC_PROFILE_ROOT/curator/inbox/c2.json"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"decisions":[{"action":"create","kind":"memory","name":"evil","path":"CLAUDE.md","content":"HACKED","reason":"x"}],"new_skill_candidates":[]}'
EOF
before="$(cat "$CC_PROFILE_ROOT/CLAUDE.md" 2>/dev/null || echo MISSING)"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
after="$(cat "$CC_PROFILE_ROOT/CLAUDE.md" 2>/dev/null || echo MISSING)"
assert_eq "$before" "$after" "CLAUDE.md untouched (allowlist)"
assert_eq "$(jq -r '.rejected_total' "$CC_PROFILE_ROOT/.curator_state")" "1" "rejected metric bumped"

( exec 9>"$CC_PROFILE_ROOT/curator/.curator.lock"; flock 9
  echo '{"kind":"flag","type":"skill","title":"z","body":"z","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c3.json"
  CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
  assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f -name c3.json | wc -l | tr -d ' ')" "1" "skipped under lock (candidate retained)"
)

jq '.paused=true' "$CC_PROFILE_ROOT/.curator_state" > "$CC_PROFILE_ROOT/.cs.tmp" && mv "$CC_PROFILE_ROOT/.cs.tmp" "$CC_PROFILE_ROOT/.curator_state"
echo '{"kind":"flag","type":"skill","title":"p","body":"p","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c4.json"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f -name c4.json | wc -l | tr -d ' ')" "1" "skipped when paused"

ps_teardown_sandbox
ps_report; exit $?

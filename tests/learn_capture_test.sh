#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
HOOK="$PS_REPO_ROOT/hooks/learn-capture.sh"

# default profile: writes a breadcrumb into cc_root/curator/inbox/
mkdir -p "$CC_PROFILE_ROOT/curator/inbox"
input='{"session_id":"abc123","transcript_path":"/tmp/t.jsonl","cwd":"/repo"}'
out="$(printf '%s' "$input" | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=default bash "$HOOK")"
count="$(find "$CC_PROFILE_ROOT/curator/inbox" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$count" "1" "one breadcrumb written"
f="$(find "$CC_PROFILE_ROOT/curator/inbox" -maxdepth 1 -type f -name '*.json' | head -1)"
assert_eq "$(jq -r '.session_id' "$f")" "abc123" "session_id captured"
assert_eq "$(jq -r '.transcript_path' "$f")" "/tmp/t.jsonl" "transcript captured"
assert_eq "$(jq -r '.profile' "$f")" "default" "profile captured"

# never fails the session even on malformed input, and still writes a breadcrumb
rm -f "$CC_PROFILE_ROOT"/curator/inbox/*.json
set +e
printf 'not json' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=default bash "$HOOK" >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "0" "malformed input still exits 0"
mf="$(find "$CC_PROFILE_ROOT/curator/inbox" -maxdepth 1 -type f -name '*.json' | head -1)"
assert_eq "$(jq -r '.session_id' "$mf")" "unknown" "malformed -> session_id unknown"

# truly empty stdin -> session_id normalized to "unknown", still exits 0
rm -f "$CC_PROFILE_ROOT"/curator/inbox/*.json
set +e
printf '' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CLAUDE_PROFILE=default bash "$HOOK" >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "0" "empty stdin still exits 0"
ef="$(find "$CC_PROFILE_ROOT/curator/inbox" -maxdepth 1 -type f -name '*.json' | head -1)"
assert_eq "$(jq -r '.session_id' "$ef")" "unknown" "empty stdin -> session_id unknown"

ps_teardown_sandbox
ps_report; exit $?

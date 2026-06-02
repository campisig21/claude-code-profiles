#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
HOOK="$PS_REPO_ROOT/hooks/learn-capture.sh"

# default profile: Stop hook indexes the session and stamps activity; writes NO inbox candidate.
mkdir -p "$CC_PROFILE_ROOT/curator/inbox"
echo '{"session_id":"sess-1","transcript_path":"/tmp/t.jsonl","cwd":"/work/acme"}' \
  | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$HOOK" >/dev/null 2>&1

idx="$CC_PROFILE_ROOT/curator/sessions.jsonl"
assert_file "$idx" "sessions.jsonl written"
assert_contains "$(cat "$idx")" "sess-1" "session id indexed"
assert_contains "$(cat "$idx")" "/tmp/t.jsonl" "transcript path indexed"
assert_file "$CC_PROFILE_ROOT/curator/last_activity" "last_activity stamped"
inbox_n="$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')"
assert_eq "$inbox_n" "0" "no inbox breadcrumb written"

# always exits 0 even on garbage stdin
echo 'not json' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$HOOK" >/dev/null 2>&1
assert_eq "$?" "0" "never fails the session"

ps_teardown_sandbox
ps_report; exit $?

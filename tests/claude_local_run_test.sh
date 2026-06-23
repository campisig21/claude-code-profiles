#!/usr/bin/env bash
# Unit test for claude_local_run (the non-exec cell worker path): it runs claude -p
# as a SUBPROCESS (control returns), captures stream-json NDJSON to a file, runs the
# worker inside <dir>, isolates the caller's cwd, and propagates the worker's exit code.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/claude-local.sh"

# A fake `claude -p`: writes a file into its cwd, emits canned NDJSON on stdout, exits 7.
fake="$PS_SANDBOX/fake-claude-lib"
cat > "$fake" <<'SH'
#!/usr/bin/env bash
echo "ran in $(pwd)" > RAN_HERE
cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"RAN_HERE"}}]}}
{"type":"result","subtype":"success","is_error":false}
JSON
exit 7
SH
chmod +x "$fake"
export CLAUDE_BIN="$fake"

wd="$PS_SANDBOX/wt"; mkdir -p "$wd"
stream="$PS_SANDBOX/run.ndjson"
before_pwd="$(pwd)"

out="$(claude_local_run "$wd" "$stream" "do the thing")"; rc=$?
assert_eq "$rc" "7"                "claude_local_run returns the worker's exit code (non-exec: control returned)"
assert_eq "$(pwd)" "$before_pwd"   "claude_local_run does not change the caller's cwd (subshell)"
assert_eq "$out" ""                "claude_local_run emits nothing on stdout (stream goes to the file)"
assert_file "$wd/RAN_HERE"         "worker ran inside the target dir (cwd was the worktree)"
assert_contains "$(cat "$stream")" '"type":"result"' "stream-json NDJSON captured to the stream file"
assert_contains "$(cat "$stream")" '"tool_use"'      "stream carries the tool_use event"

# cd-failure path: nonzero exit + a stderr diagnostic (not a silent empty stream)
err="$(claude_local_run "$PS_SANDBOX/does-not-exist" "$PS_SANDBOX/empty.ndjson" "x" 2>&1 >/dev/null)"; rcbad=$?
assert_eq "$rcbad" "1" "claude_local_run returns nonzero when cd fails"
assert_contains "$err" "no stream captured" "claude_local_run warns to stderr on cd failure (not silent)"

ps_teardown_sandbox
ps_report; exit $?

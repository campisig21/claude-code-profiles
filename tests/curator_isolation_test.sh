#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"
echo '{"kind":"flag","type":"auto","title":"t","body":"b","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c1.json"

log="$PS_SANDBOX/claude-call.log"; : > "$log"
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<EOF
#!/usr/bin/env bash
{ echo "ARGV: \$*"; echo "KEY: \${ANTHROPIC_API_KEY:-UNSET}"; } >> "$log"
echo '{"decisions":[],"new_skill_candidates":[]}'
EOF
chmod +x "$fakebin/claude"

# run the curator with a BAD key exported; the curator must strip it before invoking claude
ANTHROPIC_API_KEY="bad-key-should-be-stripped" \
  CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" \
  python3 "$CURATOR" run default >/dev/null 2>&1

assert_file "$log" "claude was invoked"
assert_contains "$(cat "$log")" "--allowedTools" "tools-disabled flag passed"
assert_contains "$(cat "$log")" "--strict-mcp-config" "MCP isolated"
assert_contains "$(cat "$log")" "--append-system-prompt" "non-agentic system prompt appended"
assert_contains "$(cat "$log")" "KEY: UNSET" "ANTHROPIC_API_KEY stripped from claude env"

ps_teardown_sandbox
ps_report; exit $?

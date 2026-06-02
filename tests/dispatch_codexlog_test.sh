#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/paths.sh"
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch.sh"

repo="$PS_SANDBOX/repo"; mkdir -p "$repo"; ( cd "$repo" && git init -q && git commit -q --allow-empty -m init )
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"th-123"}'
echo '{"type":"item.completed","item":{"type":"command_execution","command":"pytest"}}'
EOF
chmod +x "$fakebin/codex"
export CODEX_DISPATCH_CODEX_BIN="$fakebin/codex"

cd "$repo"
lastmsg="$PS_SANDBOX/last.txt"
sid="$(d_codex_exec "abc123" "$repo" "$lastmsg" "do a thing")"
log="$(d_sidecar_dir)/abc123.codexlog.jsonl"

assert_eq "$sid" "th-123" "session/thread id still parsed"
assert_file "$log" "codex log persisted to sidecar"
assert_contains "$(cat "$log")" "command_execution" "log retains tool events"

ps_teardown_sandbox
ps_report; exit $?

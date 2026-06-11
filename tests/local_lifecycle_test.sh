#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/local.sh"

# --- l_probe via the FAKE_STATE override (no network) -----------------------
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=ready          l_probe)" "ready"         "probe: ready"
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=up-not-loaded  l_probe)" "up-not-loaded" "probe: up-not-loaded"
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=unreachable    l_probe)" "unreachable"   "probe: unreachable"
( CODEX_DISPATCH_FAKE_STATE=ready         l_ready ); assert_eq "$?" "0" "ready -> l_ready 0"
( CODEX_DISPATCH_FAKE_STATE=up-not-loaded l_ready ); assert_eq "$?" "1" "not-loaded -> l_ready 1"

# --- l_probe REAL parse via a fake curl emitting router-mode JSON -----------
fcurl="$PS_SANDBOX/fake-curl"
cat > "$fcurl" <<'SH'
#!/usr/bin/env bash
# Emits a router-mode /v1/models body; FAKE_CURL_RC!=0 simulates connection failure.
[ "${FAKE_CURL_RC:-0}" != "0" ] && exit "$FAKE_CURL_RC"
printf '{"data":[{"id":"local-model","status":{"value":"%s"}},{"id":"other","status":{"value":"loaded"}}]}\n' "${FAKE_QWEN_STATUS:-loaded}"
SH
chmod +x "$fcurl"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_QWEN_STATUS=loaded   l_probe)" "ready"         "parse: alias loaded -> ready"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_QWEN_STATUS=unloaded l_probe)" "up-not-loaded" "parse: alias not loaded -> up-not-loaded"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_CURL_RC=7           l_probe)" "unreachable"   "parse: curl failure -> unreachable"

# --- l_up / l_down via fake ssh (FAKE_STATE drives readiness; preload no-ops) ---
fssh="$(ps_make_fake_ssh)"
sshlog="$PS_SANDBOX/ssh.log"; : > "$sshlog"

# defaults are generic and leave remote control opt-in
assert_eq "$(l_up_cmd)"   "" "default up cmd is empty"
assert_eq "$(l_down_cmd)" "" "default down cmd is empty"

# l_up: runs the remote up command, then polls to readiness (fake=ready -> instant)
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" \
        CODEX_DISPATCH_LOCAL_SSH='test@host' \
        CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' CODEX_DISPATCH_FAKE_STATE=ready \
        l_up 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_up succeeds when model becomes ready"
assert_contains "$out" "ready" "l_up reports readiness"
assert_contains "$(cat "$sshlog")" "UPMARK" "l_up ran the remote up command"

# l_up: stays not-loaded -> times out (fast via tiny interval/timeout)
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' \
        CODEX_DISPATCH_LOCAL_SSH='test@host' \
        CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        CODEX_DISPATCH_LOCAL_POLL_INTERVAL=1 CODEX_DISPATCH_LOCAL_POLL_TIMEOUT=1 l_up 2>&1 )"; rc=$?
assert_eq "$rc" "1" "l_up times out when never ready"
assert_contains "$out" "timed out" "l_up explains the timeout"

# l_up: a failing remote up command is surfaced
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_RC=255 CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' \
        CODEX_DISPATCH_LOCAL_SSH='test@host' \
        CODEX_DISPATCH_FAKE_STATE=up-not-loaded l_up 2>&1 )"; rc=$?
assert_eq "$rc" "1" "l_up fails when remote up command fails"

# l_up: with no remote config, skip ssh and only poll/preload
: > "$sshlog"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" \
        CODEX_DISPATCH_FAKE_STATE=ready l_up 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_up succeeds without remote config when endpoint is ready"
assert_eq "$(cat "$sshlog")" "" "l_up without remote config does not call ssh"

# l_down: with no remote config, return 0 and explain that nothing is configured
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" l_down 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_down without remote config succeeds"
assert_contains "$out" "nothing to stop" "l_down without remote config explains the no-op"

# l_down: explicit remote stop path still runs via ssh
: > "$sshlog"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" \
        CODEX_DISPATCH_LOCAL_SSH='test@host' \
        CODEX_DISPATCH_LOCAL_DOWN_CMD='docker compose stop' l_down 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_down succeeds"
assert_contains "$(cat "$sshlog")" "docker compose stop" "l_down runs the explicit stop command"

# --- engine subcommands route to the helpers --------------------------------
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fssh2="$(ps_make_fake_ssh)"; slog2="$PS_SANDBOX/ssh2.log"; : > "$slog2"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh2" FAKE_SSH_LOG="$slog2" \
        CODEX_DISPATCH_LOCAL_SSH='test@host' \
        CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' CODEX_DISPATCH_FAKE_STATE=ready \
        bash "$ENGINE" local-up 2>&1 )"; rc=$?
assert_eq "$rc" "0" "local-up subcommand exits 0"
assert_contains "$(cat "$slog2")" "UPMARK" "local-up subcommand runs up cmd"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh2" FAKE_SSH_LOG="$slog2" \
        CODEX_DISPATCH_LOCAL_SSH='test@host' \
        CODEX_DISPATCH_LOCAL_DOWN_CMD='docker compose stop' \
        bash "$ENGINE" local-down 2>&1 )"; rc=$?
assert_eq "$rc" "0" "local-down subcommand exits 0"
assert_contains "$(cat "$slog2")" "docker compose stop" "local-down subcommand stops container"

# l_up with timeout=0 must not crash on an unset $state (set -u safe)
out="$( CODEX_DISPATCH_SSH_BIN="$fssh2" CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' \
        CODEX_DISPATCH_LOCAL_SSH='test@host' \
        CODEX_DISPATCH_FAKE_STATE=up-not-loaded CODEX_DISPATCH_LOCAL_POLL_TIMEOUT=0 l_up 2>&1 )"; rc=$?
assert_eq "$rc" "1" "l_up timeout=0 exits 1 without unbound-var error"
assert_contains "$out" "last state:" "l_up timeout=0 prints last state safely"

ps_teardown_sandbox
ps_report; exit $?

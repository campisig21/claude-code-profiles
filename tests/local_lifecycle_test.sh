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
printf '{"data":[{"id":"qwen36-35b","status":{"value":"%s"}},{"id":"other","status":{"value":"loaded"}}]}\n' "${FAKE_QWEN_STATUS:-loaded}"
SH
chmod +x "$fcurl"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_QWEN_STATUS=loaded   l_probe)" "ready"         "parse: alias loaded -> ready"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_QWEN_STATUS=unloaded l_probe)" "up-not-loaded" "parse: alias not loaded -> up-not-loaded"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_CURL_RC=7           l_probe)" "unreachable"   "parse: curl failure -> unreachable"

ps_teardown_sandbox
ps_report; exit $?

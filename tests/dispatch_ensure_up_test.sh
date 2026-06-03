#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
fssh="$(ps_make_fake_ssh)"
repo="$(ps_make_sandbox_repo)"

# 1. Without --ensure-up, refusal now also advertises the flag.
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        bash "$ENGINE" quick --backend local "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "quick local still refused when not ready and no --ensure-up"
assert_contains "$out" "--ensure-up" "refusal advertises --ensure-up"

# 2. With --ensure-up and not ready, l_up IS invoked (then times out under fake ssh).
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        CODEX_DISPATCH_SSH_BIN="$fssh" CODEX_DISPATCH_LOCAL_POLL_TIMEOUT=1 CODEX_DISPATCH_LOCAL_POLL_INTERVAL=1 \
        bash "$ENGINE" quick --backend local --ensure-up "x" 2>&1 )"; rc=$?
assert_contains "$out" "local-up:" "--ensure-up invokes l_up when not ready"

# 3. With --ensure-up and already ready, proceeds normally (no l_up needed).
qlog="$PS_SANDBOX/eu.log"; : > "$qlog"
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=ready \
        FAKE_CODEX_ARGV_LOG="$qlog" bash "$ENGINE" quick --backend local --ensure-up "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "quick local --ensure-up proceeds when already ready"
assert_contains "$(cat "$qlog")" "-p local-headless" "still uses the headless profile"

# 4. dispatch also accepts --ensure-up when ready.
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260603T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        CODEX_DISPATCH_FAKE_STATE=ready \
        bash "$ENGINE" dispatch --backend local --ensure-up --verify checks --check 'bash check.sh' --slug eu "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "dispatch local --ensure-up proceeds when ready"

ps_teardown_sandbox
ps_report; exit $?

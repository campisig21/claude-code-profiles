#!/usr/bin/env bash
# Linux daemon path of install.sh: forces PS_OS=linux so it runs even on a macOS
# CI host, and writes the systemd user service+timer into a sandboxed dir.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
INSTALL="$PS_REPO_ROOT/install.sh"
export CODEX_HOME="$CC_PROFILE_ROOT/dot-codex"        # keep the codex step hermetic
export SYSTEMD_USER_DIR="$PS_SANDBOX/systemd-user"    # sandbox the unit dir

CCP_SKIP_PATH=1 PS_OS=linux CC_PROFILE_ROOT="$CC_PROFILE_ROOT" \
  SYSTEMD_USER_DIR="$SYSTEMD_USER_DIR" CURATOR_INTERVAL_SECONDS=900 \
  bash "$INSTALL" >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0" "install (linux path) succeeds"

service="$SYSTEMD_USER_DIR/profile-system-curator.service"
timer="$SYSTEMD_USER_DIR/profile-system-curator.timer"
assert_file "$service" "systemd curator service installed"
assert_file "$timer" "systemd curator timer installed"
assert_contains "$(cat "$service")" "curator.py" "service ExecStart points at the daemon"
assert_contains "$(cat "$service")" "CURATOR_CLAUDE_BIN" "service pins the claude binary (systemd PATH is minimal)"
assert_contains "$(cat "$service")" "Environment=PATH=" "service sets a PATH"
assert_contains "$(cat "$service")" "Type=oneshot" "service is oneshot (driven by the timer)"
assert_contains "$(cat "$timer")" "OnUnitActiveSec=900" "timer honors CURATOR_INTERVAL_SECONDS"
assert_contains "$(cat "$timer")" "WantedBy=timers.target" "timer is installable"

# No launchd plist should be produced on the linux path.
if [ -e "$CC_PROFILE_ROOT/Library/LaunchAgents/com.profile-system.curator.plist" ]; then
  echo "  FAIL: linux path must not write a launchd plist"; exit 1
fi

# idempotent + non-clobbering: hand-edit, re-run, edit preserved
echo "# HANDEDIT" >> "$service"
CCP_SKIP_PATH=1 PS_OS=linux CC_PROFILE_ROOT="$CC_PROFILE_ROOT" \
  SYSTEMD_USER_DIR="$SYSTEMD_USER_DIR" CURATOR_INTERVAL_SECONDS=900 \
  bash "$INSTALL" >/dev/null 2>&1
assert_contains "$(cat "$service")" "# HANDEDIT" "existing service unit left untouched on re-run"

ps_teardown_sandbox
ps_report; exit $?

#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
INSTALL="$PS_REPO_ROOT/install.sh"
export CODEX_HOME="$CC_PROFILE_ROOT/dot-codex"   # keep the local-profile step hermetic
export LAUNCH_AGENTS_DIR="$PS_SANDBOX/LaunchAgents"

CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS_DIR" \
  bash "$INSTALL" >/dev/null 2>&1
plist="$LAUNCH_AGENTS_DIR/com.profile-system.curator.plist"
assert_file "$plist" "curator plist installed"
assert_contains "$(cat "$plist")" "com.profile-system.curator" "plist label correct"
assert_contains "$(cat "$plist")" "curator.py" "plist points at daemon"
assert_contains "$(cat "$plist")" "EnvironmentVariables" "plist sets environment for launchd"
assert_contains "$(cat "$plist")" "CURATOR_CLAUDE_BIN" "plist pins the claude binary (launchd PATH excludes ~/.local/bin)"
assert_contains "$(cat "$plist")" "<key>PATH</key>" "plist sets a PATH"

# idempotent + non-clobbering: hand-edit, re-run, edit preserved
echo "HANDEDIT" >> "$plist"
CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS_DIR" \
  bash "$INSTALL" >/dev/null 2>&1
assert_contains "$(cat "$plist")" "HANDEDIT" "existing plist left untouched"

ps_teardown_sandbox
ps_report; exit $?

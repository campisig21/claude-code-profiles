#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
export CODEX_HOME="$CC_PROFILE_ROOT/dot-codex"
INSTALL="$PS_REPO_ROOT/install.sh"

# Seed a realistic default settings.json with an EXISTING hook to prove additivity.
cat > "$CC_PROFILE_ROOT/settings.json" <<'JSON'
{ "enabledPlugins": {"superpowers@official": true},
  "hooks": {"SessionStart": [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/role-wakeup.sh"}]}]} }
JSON

CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" 2>&1
rc=$?
assert_eq "$rc" "0" "install succeeds"

# C.1: local-backend codex profile written, with provider + model + endpoint
PROF="$CODEX_HOME/local.config.toml"
assert_file "$PROF" "local codex profile written"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'model_provider = "llamacpp"' "profile declares llamacpp provider"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'wire_api = "responses"' "profile uses responses wire_api (codex 0.135 dropped chat)"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'qwen36-35b' "profile defaults to the qwen36-35b alias"
# no env_key SETTING (line-start): codex would require that env var to exist; omitting = no auth.
# (A comment mentioning env_key is fine — only a real `env_key = ...` key is disallowed.)
if grep -q '^env_key' "$PROF"; then echo "  FAIL: profile must not set an env_key"; exit 1; fi
# idempotent + non-clobbering: user edit survives a re-run
printf '\n# user edit\n' >> "$PROF"
CCP_SKIP_PATH=1 CODEX_HOME="$CODEX_HOME" CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
assert_contains "$(cat "$PROF")" "# user edit" "existing profile left untouched on re-run"

# _shared populated (symlinks into repo)
assert_symlink "$CC_PROFILE_ROOT/profiles/_shared/hooks" "_shared/hooks"
assert_symlink "$CC_PROFILE_ROOT/profiles/_shared/commands" "_shared/commands"

# default profile adopted additively
assert_file "$CC_PROFILE_ROOT/.curator_state" "default curator state"
[ -d "$CC_PROFILE_ROOT/curator/inbox" ] && assert_eq ok ok "default inbox" || assert_eq no ok "inbox missing"
# existing role-wakeup hook preserved
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | any(test("role-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "role-wakeup preserved"
# profile hooks added
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | any(test("profile-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "profile-wakeup added"
assert_eq "$(jq '[.hooks.Stop[].hooks[].command] | any(test("learn-capture"))' "$CC_PROFILE_ROOT/settings.json")" "true" "learn-capture added"
# existing plugins preserved
assert_eq "$(jq -r '.enabledPlugins["superpowers@official"]' "$CC_PROFILE_ROOT/settings.json")" "true" "plugins preserved"
# machinery commands symlinked into default (all of _shared/commands/*.md, smoke finding 2)
assert_symlink "$CC_PROFILE_ROOT/commands/profile.md" "default /profile command"
assert_symlink "$CC_PROFILE_ROOT/commands/codex-implement.md" "default /codex-implement command"
# settings backup created
ls "$CC_PROFILE_ROOT"/settings.json.bak.* >/dev/null 2>&1 && assert_eq ok ok "settings backed up" || assert_eq no ok "no backup"

# idempotent: second run does not duplicate hooks
CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(test("profile-wakeup"))) | length' "$CC_PROFILE_ROOT/settings.json")" "1" "no duplicate profile-wakeup on rerun"
assert_eq "$(jq '[.hooks.Stop[].hooks[].command] | map(select(test("learn-capture"))) | length' "$CC_PROFILE_ROOT/settings.json")" "1" "no duplicate learn-capture on rerun"

# no pre-existing settings.json -> install creates a valid one with both hooks
rm -f "$CC_PROFILE_ROOT/settings.json"
CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
assert_eq "$(jq -e . "$CC_PROFILE_ROOT/settings.json" >/dev/null 2>&1; echo $?)" "0" "fresh settings.json is valid JSON"
assert_eq "$(jq '[.hooks.SessionStart[].hooks[].command]|any(test("profile-wakeup"))' "$CC_PROFILE_ROOT/settings.json")" "true" "fresh install adds profile-wakeup"
assert_eq "$(jq '[.hooks.Stop[].hooks[].command]|any(test("learn-capture"))' "$CC_PROFILE_ROOT/settings.json")" "true" "fresh install adds learn-capture"

ps_teardown_sandbox
ps_report; exit $?

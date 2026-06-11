#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ps_setup_sandbox
export CODEX_HOME="$CC_PROFILE_ROOT/dot-codex"
INSTALL="$PS_REPO_ROOT/install.sh"

CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
if [ -e "$CODEX_HOME/config.toml" ]; then echo "  FAIL: bare install must not write $CODEX_HOME/config.toml"; exit 1; fi
if [ -e "$CC_PROFILE_ROOT/local.env" ]; then echo "  FAIL: bare install must not write $CC_PROFILE_ROOT/local.env"; exit 1; fi
ps_teardown_sandbox

ps_setup_sandbox
export CODEX_HOME="$CC_PROFILE_ROOT/dot-codex"
INSTALL="$PS_REPO_ROOT/install.sh"

CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" --with-local=ollama >/dev/null 2>&1
assert_file "$CC_PROFILE_ROOT/local.env" "ollama opt-in writes local.env"
assert_contains "$(cat "$CC_PROFILE_ROOT/local.env" 2>/dev/null)" 'CODEX_DISPATCH_LOCAL_BACKEND=ollama' "ollama local.env records backend"
if [ -e "$CODEX_HOME/config.toml" ]; then echo "  FAIL: ollama opt-in must not write $CODEX_HOME/config.toml"; exit 1; fi
ps_teardown_sandbox

ps_setup_sandbox
export CODEX_HOME="$CC_PROFILE_ROOT/dot-codex"
INSTALL="$PS_REPO_ROOT/install.sh"

CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" --with-local=llamacpp >/dev/null 2>&1

# C.1: local-backend provider declared in config.toml; the PROFILE itself lives
# ONLY in the local-headless.config.toml overlay (codex >=0.136 rejects a
# [profiles.<name>] table in config.toml when you pass `--profile <name>`).
PROF="$CODEX_HOME/config.toml"
HEADLESS="$CODEX_HOME/local-headless.config.toml"
assert_file "$PROF" "codex config.toml written"
assert_file "$HEADLESS" "local-headless.config.toml overlay written"
assert_contains "$(cat "$PROF" 2>/dev/null)" '[model_providers.llamacpp]' "config declares llamacpp provider"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'wire_api = "responses"' "provider uses responses wire_api (codex 0.135 dropped chat)"
assert_contains "$(cat "$HEADLESS" 2>/dev/null)" 'model = "local-model"' "headless profile pins the generic local-model alias"
assert_contains "$(cat "$HEADLESS" 2>/dev/null)" 'model_provider = "llamacpp"' "headless profile uses llamacpp provider"
assert_contains "$(cat "$HEADLESS" 2>/dev/null)" 'model_context_window' "headless profile supplies ctx metadata"
if grep -q '^\[tui\]' "$HEADLESS"; then echo "  FAIL: headless profile must not carry TUI config"; exit 1; fi
if grep -q '^env_key' "$HEADLESS"; then echo "  FAIL: headless profile must not set an env_key"; exit 1; fi
if grep -q '^\[profiles\.local-headless\]' "$PROF"; then echo "  FAIL: config.toml must NOT declare [profiles.local-headless] (codex >=0.136 rejects it under --profile)"; exit 1; fi
assert_contains "$(cat "$HEADLESS" 2>/dev/null)" 'model_context_window' "profile lives in the overlay, not config.toml"
assert_file "$CC_PROFILE_ROOT/local.env" "llamacpp opt-in writes local.env"
assert_contains "$(cat "$CC_PROFILE_ROOT/local.env" 2>/dev/null)" 'CODEX_DISPATCH_LOCAL_BACKEND=llamacpp' "llamacpp local.env records backend"
# idempotent + non-clobbering: user edit survives, provider not duplicated on re-run
printf '\n# user edit\n' >> "$PROF"
CCP_SKIP_PATH=1 CODEX_HOME="$CODEX_HOME" CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" --with-local=llamacpp >/dev/null 2>&1
assert_contains "$(cat "$PROF")" "# user edit" "existing config left untouched on re-run"
assert_eq "$(grep -c '^\[model_providers\.llamacpp\]' "$PROF")" "1" "no duplicate llamacpp provider on rerun"

# self-heal: a stale [profiles.local-headless] table (from an older install) is
# stripped on the next run, while surrounding config survives.
cat >> "$PROF" <<'LEGACY'

[profiles.local-headless]
model = "local-model"
model_provider = "llamacpp"
model_context_window = 262144

[keepme]
sentinel = "yes"
LEGACY
CCP_SKIP_PATH=1 CODEX_HOME="$CODEX_HOME" CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" --with-local=llamacpp >/dev/null 2>&1
assert_eq "$(grep -c '^\[profiles\.local-headless\]' "$PROF")" "0" "legacy [profiles.local-headless] stripped on re-run (codex >=0.136)"
assert_contains "$(cat "$PROF")" "sentinel = \"yes\"" "config following the stripped table survives"
assert_eq "$(grep -c '^\[model_providers\.llamacpp\]' "$PROF")" "1" "provider still single after strip"

ps_teardown_sandbox
ps_report; exit $?

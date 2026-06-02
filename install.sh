#!/usr/bin/env bash
# install.sh — wire this repo into the live Claude Code config and adopt the
# default profile (~/.claude) into the profile structure, additively.
# Idempotent. Honors CC_PROFILE_ROOT (tests) and CCP_SKIP_PATH (skip PATH symlink).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SRC/lib/paths.sh"
source "$SRC/lib/jsonutil.sh"

ROOT="$(cc_root)"
SHARED="$(shared_dir)"

echo "Installing profile-system into: $ROOT"
mkdir -p "$SHARED" "$ROOT/profiles" "$ROOT/curator/inbox" "$ROOT/commands"

# 1. _shared/* -> repo/* (so repo edits propagate to runtime)
ln -sfn "$SRC/hooks"     "$SHARED/hooks"
ln -sfn "$SRC/commands"  "$SHARED/commands"
ln -sfn "$SRC/skills"    "$SHARED/skills"
ln -sfn "$SRC/templates" "$SHARED/templates"

# 2. Adopt default profile: curator state (idempotent)
js_init_curator_state "$ROOT/.curator_state"

# 3. Back up settings.json, then additively register the two profile hooks.
if [ -f "$ROOT/settings.json" ]; then
  cp "$ROOT/settings.json" "$ROOT/settings.json.bak.$(date -u +%Y%m%d%H%M%S)"
else
  echo '{}' > "$ROOT/settings.json"
fi
js_merge_command_hook "$ROOT/settings.json" SessionStart "bash $SHARED/hooks/profile-wakeup.sh"
js_merge_command_hook "$ROOT/settings.json" Stop          "bash $SHARED/hooks/learn-capture.sh"

# 4. Machinery commands + skills into the default profile (additive symlinks).
for c in "$SHARED/commands"/*.md; do
  [ -e "$c" ] || continue
  ln -sfn "$c" "$ROOT/commands/$(basename "$c")"
done
mkdir -p "$ROOT/skills"
for s in "$SHARED/skills"/*/; do
  [ -d "$s" ] || continue
  ln -sfn "${s%/}" "$ROOT/skills/$(basename "$s")"
done

# 5. ccp onto PATH (skip in tests).
if [ "${CCP_SKIP_PATH:-0}" != "1" ]; then
  target="$HOME/.local/bin/ccp"
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$SRC/bin/ccp" "$target"
  echo "  Linked ccp -> $target (ensure ~/.local/bin is on PATH)"
fi

# 6. Codex local-model dispatch backend (C.1) — define a NATIVE codex profile
#    `[profiles.<name>]` (+ shared `[model_providers.llamacpp]`) INSIDE config.toml,
#    so `codex -p <name>` resolves in BOTH interactive and headless (`codex exec`)
#    runs — which is what `--backend local` uses (lib/dispatch.sh d_backend_args).
#    A standalone `<name>.config.toml` only loads via `--profile-v2`, NOT `-p`, so
#    on codex 0.135 `codex exec -p local` would error "config profile not found".
#    Idempotent + non-clobbering: each table is appended only if absent; existing
#    config is never rewritten.
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG="$CODEX_HOME_DIR/config.toml"
LOCAL_PROFILE_NAME="${CODEX_DISPATCH_LOCAL_PROFILE:-local}"
mkdir -p "$CODEX_HOME_DIR"
[ -e "$CODEX_CONFIG" ] || : > "$CODEX_CONFIG"

if grep -q '^\[model_providers\.llamacpp\]' "$CODEX_CONFIG"; then
  echo "  codex config already declares [model_providers.llamacpp] (left untouched)"
else
  cat >> "$CODEX_CONFIG" <<TOML

[model_providers.llamacpp]
name     = "llama.cpp (workstation)"
base_url = "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://100.64.0.4:8080/v1}"
# codex 0.135 dropped wire_api="chat" for custom providers — it requires the
# Responses API, which the llama.cpp router (build b9209+) serves at /v1/responses.
# No env_key: codex would demand that env var EXIST; omitting it sends no auth,
# which the local router accepts.
wire_api = "responses"
TOML
  echo "  added [model_providers.llamacpp] to $CODEX_CONFIG"
fi

if grep -q "^\[profiles\.${LOCAL_PROFILE_NAME}\]" "$CODEX_CONFIG"; then
  echo "  codex config already declares [profiles.${LOCAL_PROFILE_NAME}] (left untouched)"
else
  cat >> "$CODEX_CONFIG" <<TOML

# Local dispatch backend — selected by:  codex -p ${LOCAL_PROFILE_NAME}  (--backend local).
# 'model' must match the alias your router advertises at /v1/models (verify it).
# model_context_window supplies the metadata codex can't fetch for a custom-provider
# model (match the router's --ctx-size); it silences the "fallback metadata" warning.
[profiles.${LOCAL_PROFILE_NAME}]
model = "${CODEX_DISPATCH_LOCAL_MODEL:-qwen36-35b}"
model_provider = "llamacpp"
model_context_window = ${CODEX_DISPATCH_LOCAL_CTX:-262144}
TOML
  echo "  added [profiles.${LOCAL_PROFILE_NAME}] to $CODEX_CONFIG"
fi

# launchd curator job (subsystem B) — write only if absent (never clobber).
LA_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
mkdir -p "$LA_DIR"
plist="$LA_DIR/com.profile-system.curator.plist"
if [ ! -f "$plist" ]; then
  interval="${CURATOR_INTERVAL_SECONDS:-1800}"
  logdir="$ROOT"
  sed -e "s#__CURATOR_PY__#$SRC/bin/curator.py#g" \
      -e "s#__INTERVAL__#$interval#g" \
      -e "s#__LOGDIR__#$logdir#g" \
      "$SRC/templates/curator.plist" > "$plist"
  echo "  Installed launchd curator job -> $plist"
  echo "  Load it with:  launchctl load $plist"
else
  echo "  launchd curator job exists; leaving untouched: $plist"
fi

echo "Done. Default profile adopted. Create more with: /profile create <name>  (or  $SRC/profile_mgmt.sh create <name>)"

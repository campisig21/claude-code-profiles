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

# 6. Codex profile for the local-model dispatch backend (C.1) — idempotent,
#    non-clobbering. Lives under $CODEX_HOME so `codex -p local` picks it up.
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
LOCAL_PROFILE="$CODEX_HOME_DIR/${CODEX_DISPATCH_LOCAL_PROFILE:-local}.config.toml"
if [ -e "$LOCAL_PROFILE" ]; then
  echo "  local-backend codex profile exists: $LOCAL_PROFILE (left untouched)"
else
  mkdir -p "$CODEX_HOME_DIR"
  cat > "$LOCAL_PROFILE" <<TOML
# Codex profile for the C.1 local dispatch backend (llama.cpp router on the workstation).
# Selected by:  codex -p ${CODEX_DISPATCH_LOCAL_PROFILE:-local}   (via --backend local).
# 'model' must match the alias your router advertises at /v1/models (verify it).
model          = "${CODEX_DISPATCH_LOCAL_MODEL:-qwen36-35b}"
model_provider = "llamacpp"

[model_providers.llamacpp]
name     = "llama.cpp (workstation)"
base_url = "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://100.64.0.4:8080/v1}"
wire_api = "chat"
env_key  = "LLAMACPP_API_KEY"
TOML
  echo "  wrote local-backend codex profile: $LOCAL_PROFILE"
fi

echo "Done. Default profile adopted. Create more with: /profile create <name>  (or  $SRC/profile_mgmt.sh create <name>)"

# install-common.sh — cross-platform installer core. Sourced by install.sh
# AFTER it has defined $SRC, $ROOT, $SHARED and sourced lib/paths.sh +
# lib/jsonutil.sh. Everything here is OS-agnostic; the platform-specific
# background-curator daemon is installed separately by lib/daemon-<os>.sh.

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
  ln -sfn "$SRC/bin/local-ask" "$HOME/.local/bin/local-ask"
  echo "  Linked local-ask -> $HOME/.local/bin/local-ask"
  ln -sfn "$SRC/bin/dispatch" "$HOME/.local/bin/dispatch"
  echo "  Linked dispatch -> $HOME/.local/bin/dispatch"
fi

# 6. Codex local-model dispatch backend (C.1) is opt-in only.
if [ -n "${PS_WITH_LOCAL:-}" ]; then
  case "${PS_LOCAL_BACKEND:-}" in
    llamacpp)
      # define the shared provider in config.toml and write the codex 0.136 file
      # overlay loaded by `codex -p <name>`.
      # NOTE: do NOT write a `[profiles.<name>]` table into config.toml — codex >=0.136
      # refuses `--profile <name>` when config.toml still declares that profile table
      # (the legacy 0.135 form); the per-profile `<name>.config.toml` overlay is the
      # only supported location. Idempotent + non-clobbering: each file is written
      # only if absent.
      CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
      CODEX_CONFIG="$CODEX_HOME_DIR/config.toml"
      LOCAL_PROFILE_NAME="${CODEX_DISPATCH_LOCAL_PROFILE:-local-headless}"
      mkdir -p "$CODEX_HOME_DIR"
      [ -e "$CODEX_CONFIG" ] || : > "$CODEX_CONFIG"

      if grep -q '^\[model_providers\.llamacpp\]' "$CODEX_CONFIG"; then
        echo "  codex config already declares [model_providers.llamacpp] (left untouched)"
      else
        cat >> "$CODEX_CONFIG" <<TOML

[model_providers.llamacpp]
name     = "llama.cpp (workstation)"
base_url = "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://localhost:8080/v1}"
# codex 0.135 dropped wire_api="chat" for custom providers — it requires the
# Responses API, which the llama.cpp router (build b9209+) serves at /v1/responses.
# No env_key: codex would demand that env var EXIST; omitting it sends no auth,
# which the local router accepts.
wire_api = "responses"
TOML
        echo "  added [model_providers.llamacpp] to $CODEX_CONFIG"
      fi

      HEADLESS_OVERLAY="$CODEX_HOME_DIR/${LOCAL_PROFILE_NAME}.config.toml"
      if [ -e "$HEADLESS_OVERLAY" ]; then
        echo "  codex ${LOCAL_PROFILE_NAME}.config.toml exists (left untouched)"
      else
        cat > "$HEADLESS_OVERLAY" <<TOML
# Claude-driven (headless) codex profile — selected by:  codex -p ${LOCAL_PROFILE_NAME}
# Used by --backend local (codex_dispatch.sh) and bin/local-ask. No TUI: this
# profile never drives an interactive session — that is the separate 'local' profile.
model = "${CODEX_DISPATCH_LOCAL_MODEL:-local-model}"
model_provider = "llamacpp"
model_context_window = ${CODEX_DISPATCH_LOCAL_CTX:-262144}

[model_providers.llamacpp]
name     = "llama.cpp (workstation)"
base_url = "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://localhost:8080/v1}"
wire_api = "responses"
TOML
        echo "  wrote $HEADLESS_OVERLAY"
      fi

      # codex >=0.136: a stale [profiles.<name>] table in config.toml (written by older
      # installs) makes `codex -p <name>` fail to load. Strip it if present so the
      # overlay above is the single source of truth. Leaves all other config intact.
      if grep -q "^\[profiles\.${LOCAL_PROFILE_NAME}\]" "$CODEX_CONFIG"; then
        awk -v hdr="[profiles.${LOCAL_PROFILE_NAME}]" '
          $0 == hdr { skip=1; next }                 # drop the table header
          skip && /^\[/ { skip=0 }                    # next table ends the skip
          skip && /^[[:space:]]*$/ { next }           # drop blank lines inside it
          skip { next }                               # drop body lines
          { print }
        ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp" && mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
        echo "  removed legacy [profiles.${LOCAL_PROFILE_NAME}] from $CODEX_CONFIG (codex >=0.136)"
      fi

      printf '%s\n' 'CODEX_DISPATCH_LOCAL_BACKEND=llamacpp' > "$ROOT/local.env"
      ;;
    ollama)
      cat > "$ROOT/local.env" <<'ENV'
CODEX_DISPATCH_LOCAL_BACKEND=ollama
CODEX_DISPATCH_LOCAL_MODEL=qwen2.5-coder
ENV
      echo "  configured local backend: ollama (model qwen2.5-coder) in $ROOT/local.env"
      ;;
  esac
fi

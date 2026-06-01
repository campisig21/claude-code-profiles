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

echo "Done. Default profile adopted. Create more with: /profile create <name>  (or  $SRC/profile_mgmt.sh create <name>)"

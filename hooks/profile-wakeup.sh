#!/usr/bin/env bash
# SessionStart hook for the profile system. Independent of role-wakeup.sh.
# Emits a PROFILE WAKEUP context block with live status, plus a loud warning
# if CLAUDE_PROFILE and CLAUDE_CONFIG_DIR disagree. Read-only; never blocks.
set -uo pipefail
cat >/dev/null 2>&1 || true   # drain stdin (hook input JSON, unused here)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/paths.sh"
source "$HERE/../lib/jsonutil.sh"

name="$(resolve_active_profile)"
pdir="$(profile_dir "$name")"

# --- mismatch guard ---
warning=""
if [ -n "${CLAUDE_PROFILE:-}" ]; then
  exp="$(expected_config_dir "$CLAUDE_PROFILE")"
  ccd="${CLAUDE_CONFIG_DIR:-}"
  if [ "$CLAUDE_PROFILE" = "default" ]; then
    if [ -n "$ccd" ] && [ "$ccd" != "$(cc_root)" ]; then
      warning="!! PROFILE MISMATCH: CLAUDE_PROFILE=default but CLAUDE_CONFIG_DIR=$ccd (expected unset or $(cc_root)). Data may land in the wrong profile."
    fi
  elif [ "$ccd" != "$exp" ]; then
    warning="!! PROFILE MISMATCH: CLAUDE_PROFILE=$CLAUDE_PROFILE but CLAUDE_CONFIG_DIR=${ccd:-<unset>} (expected $exp). Data may land in the wrong profile."
  fi
fi

# --- symlink self-heal (named profiles only; default owns real dirs) ---
if [ "$name" != "default" ] && [ -d "$pdir" ]; then
  [ -e "$pdir/plugins" ] || ln -sfn "$(cc_root)/plugins" "$pdir/plugins" 2>/dev/null || true
  [ -e "$pdir/hooks" ]   || ln -sfn "$(shared_dir)/hooks" "$pdir/hooks" 2>/dev/null || true
fi

# --- gather status ---
persona="(no persona set)"
if [ -f "$pdir/CLAUDE.md" ]; then
  persona="$(grep -m1 -E '^[^[:space:]]' "$pdir/CLAUDE.md" | sed -E 's/^#+ *//')"
  [ -n "$persona" ] || persona="(empty CLAUDE.md)"
fi
state="$pdir/.curator_state"
last_run="never"
if [ -f "$state" ]; then
  lr="$(js_get "$state" '.last_run_at')"; [ -n "$lr" ] && last_run="$lr"
fi
pending=0
[ -d "$pdir/curator/inbox" ] && pending="$(find "$pdir/curator/inbox" -maxdepth 1 -type f | wc -l | tr -d ' ')"
learned=0
[ -d "$pdir/skills" ] && learned="$(find "$pdir/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

ctx="===== PROFILE WAKEUP: $name =====
Persona: $persona
Curator: last run $last_run · $pending pending learning candidate(s)
Skills:  $learned learned skill(s)"
[ -n "$warning" ] && ctx="$warning

$ctx"
ctx="$ctx
===== END PROFILE WAKEUP ====="

jq -n --arg msg "Profile: $name" --arg ctx "$ctx" \
  '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

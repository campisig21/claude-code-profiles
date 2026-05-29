#!/usr/bin/env bash
# Path resolution for the profile system. SOURCE this; do not execute.
# Single source of truth for where profiles live. No side effects.

# Base dir holding profiles/, active_profile; IS the default profile.
# Overridable via CC_PROFILE_ROOT (tests).
cc_root() { printf '%s\n' "${CC_PROFILE_ROOT:-$HOME/.claude}"; }

profiles_dir() { printf '%s\n' "$(cc_root)/profiles"; }
shared_dir()   { printf '%s\n' "$(cc_root)/profiles/_shared"; }

# profile_dir [name]: "default"/empty => cc_root; else profiles/<name>.
profile_dir() {
  local name="${1:-default}"
  if [ "$name" = "default" ]; then cc_root; else printf '%s\n' "$(profiles_dir)/$name"; fi
}

profile_exists() { [ -d "$(profile_dir "$1")" ]; }

# Echo the active profile name from env: CLAUDE_PROFILE wins, else derive
# from CLAUDE_CONFIG_DIR (under profiles/<name> => name; cc_root/unset => default).
resolve_active_profile() {
  if [ -n "${CLAUDE_PROFILE:-}" ]; then printf '%s\n' "$CLAUDE_PROFILE"; return; fi
  local ccd="${CLAUDE_CONFIG_DIR:-}"
  if [ -z "$ccd" ] || [ "$ccd" = "$(cc_root)" ]; then printf '%s\n' "default"; return; fi
  local pdir; pdir="$(profiles_dir)"
  case "$ccd" in
    "$pdir"/*) printf '%s\n' "$(basename "$ccd")" ;;
    *)         printf '%s\n' "default" ;;
  esac
}

# Where CLAUDE_CONFIG_DIR should point for <name>. default => "" (unset/cc_root ok).
expected_config_dir() {
  local name="$1"
  if [ "$name" = "default" ]; then printf '%s\n' ""; else profile_dir "$name"; fi
}

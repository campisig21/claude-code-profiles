#!/usr/bin/env bash
# JSON helpers (jq-based). SOURCE this; do not execute.

# Write a fresh curator-state file iff absent (idempotent).
js_init_curator_state() {
  local path="$1"
  [ -f "$path" ] && return 0
  jq -n '{last_run_at: null, last_run_duration_seconds: null, last_run_summary: null, paused: false, run_count: 0}' > "$path"
}

# Print a field; empty string if file missing or value null.
js_get() {
  local file="$1" filter="$2"
  [ -f "$file" ] || { printf '\n'; return 0; }
  jq -r "$filter // empty" "$file" 2>/dev/null || printf '\n'
}

# Add a {type:command} hook under <event> if that exact command is not already
# present. Additive (keeps existing entries), idempotent. Creates .hooks/.hooks[event].
js_merge_command_hook() {
  local file="$1" event="$2" cmd="$3" tmp
  tmp="$(mktemp)"
  jq --arg ev "$event" --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks[$ev] //= [] |
    if any(.hooks[$ev][]?; (.hooks[]?|.command) == $cmd)
    then .
    else .hooks[$ev] += [{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}]
    end
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

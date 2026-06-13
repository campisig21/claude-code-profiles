#!/usr/bin/env bash
# lib/console.sh — dispatch observability READERS (Subsystem E Phase 1b, §5.5).
#   attach  = live-tail one dispatch's event log ("switch into what it's doing")
#   console = the cross-model board: every dispatch's id/harness/backend/model/status
# SOURCE this AFTER lib/dispatch-lib.sh — it uses d_events_path/d_sc_get/d_list_ids/
# d_in_git_repo/die. The WRITER (d_event) lives in the library so begin/codex-run/
# verify/record/land can all append; the readers here add no write paths.
[ -n "${_DISPATCH_CONSOLE_SOURCED:-}" ] && return 0
_DISPATCH_CONSOLE_SOURCED=1

# d_attach <id> [--no-follow] [--lines N] — surface one dispatch's event stream.
# Default FOLLOWS (tail -f) for live use; --no-follow prints what exists and exits
# (tests + non-interactive callers). Each {ts,phase,kind,line} renders as
#   <ts>  [<phase>/<kind>] <line>
d_attach() {
  local id="" follow=1 lines=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-follow) follow=0; shift;;
      --lines) lines="$2"; shift 2;;
      -*) die "unknown flag: $1";;
      *) if [ -z "$id" ]; then id="$1"; else die "attach takes one id (extra: $1)"; fi; shift;;
    esac
  done
  [ -n "$id" ] || die "attach requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local p fmt; p="$(d_events_path "$id")"
  fmt='"\(.ts)  [\(.phase)/\(.kind)] \(.line)"'
  [ -f "$p" ] || { echo "no events yet for $id"; return 0; }
  if [ "$follow" -eq 1 ]; then
    jq -rc "$fmt" "$p" 2>/dev/null || true
    # follow new lines; codex is non-interactive, so this is read-only live-tail.
    tail -n 0 -f "$p" 2>/dev/null | while IFS= read -r l; do
      printf '%s\n' "$l" | jq -rc "$fmt" 2>/dev/null || true
    done
  else
    if [ "$lines" -gt 0 ]; then tail -n "$lines" "$p"; else cat "$p"; fi \
      | jq -rc "$fmt" 2>/dev/null || true
  fi
}

# d_console — one board across every dispatch in this repo:
#   id · harness · backend · model · status · last-activity
# Defaults harness->codex and model->— for LEGACY sidecars (field absent),
# mirroring backend's defaulting (AC3). last-activity = newest event ts, else
# the sidecar's updated_at.
d_console() {
  d_in_git_repo || die "not in a git repository"
  local ids; ids="$(d_list_ids)"
  if [ -z "$ids" ]; then echo "No dispatches for this repo."; return 0; fi
  echo "Dispatch console (this repo):"
  printf '  %-30s %-8s %-8s %-12s %-13s %s\n' "ID" "HARNESS" "BACKEND" "MODEL" "STATUS" "LAST-ACTIVITY"
  local id harness backend model status last ep
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    harness="$(d_sc_get "$id" '.harness')"; [ -n "$harness" ] || harness="codex"
    backend="$(d_sc_get "$id" '.backend')"; [ -n "$backend" ] || backend="codex"
    model="$(d_sc_get "$id" '.model')";     [ -n "$model" ]   || model="—"
    status="$(d_sc_get "$id" '.status')"
    ep="$(d_events_path "$id")"
    if [ -f "$ep" ]; then last="$(tail -n 1 "$ep" | jq -r '.ts' 2>/dev/null)"; else last=""; fi
    [ -n "$last" ] || last="$(d_sc_get "$id" '.updated_at')"
    printf '  %-30s %-8s %-8s %-12s %-13s %s\n' "$id" "$harness" "$backend" "$model" "$status" "$last"
  done <<< "$ids"
}

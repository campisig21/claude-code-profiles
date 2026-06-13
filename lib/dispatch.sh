#!/usr/bin/env bash
# lib/dispatch.sh — the codex-family worker ADAPTER. SOURCE this.
# Slimmed in Subsystem E: the harness-agnostic primitives now live in
# lib/dispatch-lib.sh (sourced below); this file is just the codex call site
# (d_codex_exec/_resume/_session_id) + the backend selector (d_backend_args).
# Depends on lib/jsonutil.sh (js_get) being sourced first.
_here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_here/dispatch-lib.sh"

# --- codex invocation (the ONLY place codex is called — see spec R4) --------
# d_codex_exec <id> <worktree> <lastmsg_file> <prompt> [backend-flags...]  -> echoes captured session id
d_codex_exec() {
  local id="$1" wt="$2" lastmsg="$3" prompt="$4"; shift 4   # remaining args = backend flags
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}" log
  log="$(d_sidecar_dir)/$id.codexlog.jsonl"
  mkdir -p "$(d_sidecar_dir)" 2>/dev/null || true
  # stdin from /dev/null: headless codex exec otherwise blocks forever on
  # "Reading additional input from stdin..." when stdin is a non-TTY pipe.
  "$bin" exec "$@" --dangerously-bypass-approvals-and-sandbox --json \
         -C "$wt" -o "$lastmsg" "$prompt" </dev/null > "$log" 2>&1 || true
  d_codex_session_id "$log"
}

# d_codex_resume <id> <worktree> <session_id|""> <prompt> [backend-flags...]
# Primary path: `--last -C <wt>` (cwd-scoped, schema-independent). Uses an
# explicit session id when one was captured.
d_codex_resume() {
  local id="$1" wt="$2" session="$3" prompt="$4"; shift 4   # remaining args = backend flags
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}" log
  log="$(d_sidecar_dir)/$id.codexlog.jsonl"
  mkdir -p "$(d_sidecar_dir)" 2>/dev/null || true
  if [ -n "$session" ]; then
    "$bin" exec resume "$session" "$@" --dangerously-bypass-approvals-and-sandbox \
           -C "$wt" "$prompt" </dev/null >> "$log" 2>&1 || true
  else
    "$bin" exec resume --last "$@" --dangerously-bypass-approvals-and-sandbox \
           -C "$wt" "$prompt" </dev/null >> "$log" 2>&1 || true
  fi
}

# d_codex_session_id <stream-file>  -> best-effort session id (empty if none)
# codex <=0.x emitted "session_id"; codex 0.135+ emits "thread_id" on
# thread.started. Match either (session_id first for older streams) so the
# explicit-id resume path keeps working across codex versions.
d_codex_session_id() {
  local stream="$1"
  [ -f "$stream" ] || { printf '\n'; return 0; }
  grep -oE '"(session_id|thread_id)":"[^"]*"' "$stream" 2>/dev/null \
    | head -1 | sed 's/.*:"//; s/"$//'
}

# --- backend selection (C.1) ------------------------------------------------
# d_backend_args <backend> -> echo extra codex flags for that backend.
#   codex (default) -> (nothing)        local -> -p <profile>
# Returns nonzero on an unknown backend so the caller can die loudly.
d_backend_args() {
  case "${1:-codex}" in
    codex) : ;;
    local) printf '%s %s' '-p' "${CODEX_DISPATCH_LOCAL_PROFILE:-local-headless}" ;;
    ollama) printf '%s' "--oss --local-provider ollama -m ${CODEX_DISPATCH_LOCAL_MODEL:-qwen2.5-coder}" ;;
    *)     return 1 ;;
  esac
}

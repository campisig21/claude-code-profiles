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

# --- codex-run: the Subsystem-E cell delegation verb (E4/E6/E10) -------------
# d_codex_run <id> --backend <codex|ollama|local|…> -m <model> "<composed-prompt>"
# Runs `codex exec` (via the single d_codex_exec call site) in the dispatch's
# worktree, threading the two orthogonal sub-axes: --backend selects the transport
# flag-bundle (the UNCHANGED d_backend_args), -m selects the model — appended as its
# own axis. For the `codex` backend the bundle is empty, so argv is exactly
# `-m <model>`; for `ollama` the cell's -m wins over the arm's baked-in default
# (last-wins, harmless). The verbatim --json stream stays in <id>.codexlog.jsonl;
# a compact projection is forwarded into <id>.events.jsonl (MC-I). Updates the
# sidecar (.backend/.model/.session_id/.prompt) and commits the work.
# E10 (MC-J): REFUSES a Claude model (Claude cells implement directly, never via
# codex) and a non-Claude model when no codex binary is available — each loudly.
d_codex_run() {
  local id="" backend="codex" model="" prompt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --backend)  backend="$2"; shift 2;;
      -m|--model) model="$2"; shift 2;;
      --) shift; break;;
      -*) die "unknown flag: $1";;
      *) if [ -z "$id" ]; then id="$1"; else prompt="$1"; fi; shift;;
    esac
  done
  [ -n "$prompt" ] || prompt="${1:-}"
  [ -n "$id" ]     || die "codex-run requires a dispatch id"
  [ -n "$prompt" ] || die "codex-run requires a composed prompt"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  [ -n "$model" ]  || die "codex-run requires -m <model> (the worker model axis)"
  # E10: a Claude model is implemented by the cell directly — never delegated to codex.
  case "$model" in
    claude|claude-*|sonnet|opus|haiku|fable)
      die "model '$model' is a Claude model — implement it directly in the cell; do NOT codex-run it (E10).";;
  esac
  # E10: a non-Claude model needs a codex binary to ride in through.
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}"
  command -v "$bin" >/dev/null 2>&1 \
    || die "no codex binary ('$bin') available — install codex, or pick a Claude model to implement directly (E10)."
  local bargs; bargs="$(d_backend_args "$backend")" || die "invalid --backend: $backend"
  local wt; wt="$(d_sc_get "$id" '.worktree')"
  [ -d "$wt" ] || die "worktree missing for '$id' (run: dispatch doctor)"

  d_event "$id" codex-run start "backend=$backend model=$model"
  local lastmsg session; lastmsg="$(mktemp)"
  # $bargs is intentionally unquoted (word-split into flags, as in cmd_dispatch);
  # -m "$model" is the separate model axis appended last.
  session="$(d_codex_exec "$id" "$wt" "$lastmsg" "$prompt" $bargs -m "$model")"
  d_sc_set "$id" \
    '.session_id=(if $s=="" then null else $s end)|.codex_last_message=$m|.backend=$b|.model=$mo|.prompt=$p|.updated_at=$u' \
    --arg s "$session" --arg m "$(cat "$lastmsg" 2>/dev/null)" \
    --arg b "$backend" --arg mo "$model" --arg p "$prompt" --arg u "$(d_now)"
  rm -f "$lastmsg"

  # project the verbatim codex stream into the console event log (MC-I).
  local cl; cl="$(d_sidecar_dir)/$id.codexlog.jsonl"
  if [ -f "$cl" ]; then
    local pl
    while IFS= read -r pl; do
      [ -n "$pl" ] && d_event "$id" codex-run progress "$pl"
    done < <(jq -rc 'select(.type) | "\(.type) \(.session_id // .thread_id // .item.item_type // .item.type // "")"' "$cl" 2>/dev/null)
  fi

  d_commit_worktree "$wt" "codex-run: $id ($backend -m $model)" || true
  d_event "$id" codex-run done "$(d_sc_get "$id" '.codex_last_message')"
  echo "codex-run $id done (backend=$backend model=$model). Next: dispatch verify $id --check '<cmd>'"
}

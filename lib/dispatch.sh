#!/usr/bin/env bash
# lib/dispatch.sh — primitives for the codex dispatch engine. SOURCE this.
# Operates on the CURRENT working repo (cwd), independent of the profile root.
# Depends on lib/jsonutil.sh (js_get) being sourced first.

# --- identity ---------------------------------------------------------------
d_now()     { printf '%s\n' "${CODEX_DISPATCH_NOW:-$(date -u +%Y%m%dT%H%M%SZ)}"; }
d_slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
                | sed -E 's/^-+//; s/-+$//' | cut -c1-32; }
d_short()   { printf '%s' "$1" | cksum | tr -d ' ' | cut -c1-6; }

# --- git context (operate on cwd's repo) ------------------------------------
d_in_git_repo() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
d_repo_root()   { git rev-parse --show-toplevel; }
d_git_dir()     { git rev-parse --absolute-git-dir; }
d_tree_dirty()  { [ -n "$(git status --porcelain 2>/dev/null)" ]; }
d_cur_branch()  { git rev-parse --abbrev-ref HEAD; }
d_head_sha()    { git rev-parse HEAD; }

d_worktree_root() {
  local repo; repo="$(d_repo_root)"
  printf '%s\n' "$(dirname "$repo")/.codex-dispatch-worktrees/$(basename "$repo")"
}
d_sidecar_dir()  { printf '%s\n' "$(d_git_dir)/codex-dispatch"; }
d_sidecar_path() { printf '%s\n' "$(d_sidecar_dir)/$1.json"; }
d_sidecar_exists() { [ -f "$(d_sidecar_path "$1")" ]; }

# --- sidecar JSON I/O -------------------------------------------------------
# d_sc_get <id> <jq-filter>  -> field (empty if null/missing)
d_sc_get() { js_get "$(d_sidecar_path "$1")" "$2"; }

# d_sc_set <id> <jq-filter> [jq args...]  -> apply filter in place
d_sc_set() {
  local id="$1" filter="$2"; shift 2
  local p t; p="$(d_sidecar_path "$id")"; t="$(mktemp)"
  jq "$@" "$filter" "$p" > "$t" && mv "$t" "$p"
}

# d_list_ids -> one id per line (no sidecars => no output)
d_list_ids() {
  local dir f; dir="$(d_sidecar_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do [ -e "$f" ] || continue; basename "$f" .json; done
}

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
    local) printf '%s %s' '-p' "${CODEX_DISPATCH_LOCAL_PROFILE:-local}" ;;
    *)     return 1 ;;
  esac
}

# --- checks -----------------------------------------------------------------
# d_run_checks <worktree> <cmd>...  -> sets D_CHECKS_JSON; returns 0 iff all pass.
D_CHECKS_JSON='[]'
d_run_checks() {
  local wt="$1"; shift
  local overall=0 c out code tail entries='[]'
  for c in "$@"; do
    [ -n "$c" ] || continue
    out="$(cd "$wt" && bash -c "$c" 2>&1)"; code=$?
    tail="$(printf '%s\n' "$out" | tail -n 20)"
    entries="$(printf '%s' "$entries" \
      | jq --arg c "$c" --argjson e "$code" --arg t "$tail" \
           '. + [{cmd:$c, exit:$e, output_tail:$t}]')"
    [ "$code" -ne 0 ] && overall=1
  done
  D_CHECKS_JSON="$entries"
  return "$overall"
}

# --- worktree commit + diff -------------------------------------------------
# d_commit_worktree <wt> <msg>  -> commits all changes; 0 if a commit was made, 1 if none.
d_commit_worktree() {
  local wt="$1" msg="$2"
  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet; then return 1; fi
  git -C "$wt" commit -q -m "$msg"
}

d_changed_files() { git -C "$1" diff --name-only "$2"..HEAD; }
d_diffstat()      { git -C "$1" diff --stat       "$2"..HEAD; }
d_full_diff()     { git -C "$1" diff              "$2"..HEAD; }

# d_touches_tests  (reads file list on stdin) -> 0 if any path looks like a test
d_touches_tests() {
  grep -Eiq '(^|/)(tests?|__tests__|spec)(/|$)|_test\.|\.test\.|_spec\.|\.spec\.'
}

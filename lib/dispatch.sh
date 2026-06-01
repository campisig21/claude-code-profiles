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

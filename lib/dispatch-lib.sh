#!/usr/bin/env bash
# lib/dispatch-lib.sh — the harness-agnostic CALLED LIBRARY for dispatch (Subsystem E).
# Portable: knows nothing about codex/workers and has NO hard dependency on
# lib/paths.sh or lib/local.sh. SOURCE this. Depends on lib/jsonutil.sh (js_get).
# Consumed by lib/dispatch.sh (codex adapter), codex_dispatch.sh, and bin/dispatch.
[ -n "${_DISPATCH_LIB_SOURCED:-}" ] && return 0
_DISPATCH_LIB_SOURCED=1

# Standard error exit (shared by every CLI that sources this lib).
die() { echo "codex-dispatch: $*" >&2; exit 1; }

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
  # Project-local so node_modules/deps installed during dispatch are findable
  # from the project root, and so worktrees show up in tooling/IDE that scopes
  # to the project. Auto-gitignored by d_ensure_worktree_gitignore on dispatch.
  printf '%s\n' "$(d_repo_root)/.codex-dispatch-worktrees"
}
d_sidecar_dir()  { printf '%s\n' "$(d_git_dir)/codex-dispatch"; }
d_sidecar_path() { printf '%s\n' "$(d_sidecar_dir)/$1.json"; }
d_sidecar_exists() { [ -f "$(d_sidecar_path "$1")" ]; }

# Ensure .codex-dispatch-worktrees/ is in the repo's .gitignore (idempotent).
# Creates .gitignore if absent. Called on every dispatch — cheap, safe.
d_ensure_worktree_gitignore() {
  local repo="$1" gi="$1/.gitignore" pat='.codex-dispatch-worktrees/'
  if [ -f "$gi" ]; then
    grep -qxF "$pat" "$gi" 2>/dev/null && return 0
    grep -qxF '.codex-dispatch-worktrees' "$gi" 2>/dev/null && return 0
    printf '\n# codex-dispatch worktrees (local, ephemeral)\n%s\n' "$pat" >> "$gi"
  else
    printf '# codex-dispatch worktrees (local, ephemeral)\n%s\n' "$pat" > "$gi"
  fi
}

# Post-merge dep sync. After a dispatch's commits land, run the install
# command for any changed lockfile in the main repo so node_modules / .venv /
# target / etc. stay in sync with what the dispatch verified against.
# Known lockfiles auto-install; unknown ones get a warning.
d_sync_deps() {
  local repo="$1" pre="$2" post="$3"
  [ "$pre" = "$post" ] && return 0
  local changed; changed="$(git -C "$repo" diff --name-only "$pre".."$post" 2>/dev/null)"
  [ -n "$changed" ] || return 0
  local f
  while IFS= read -r f; do
    case "$f" in
      package-lock.json|*/package-lock.json)
        echo "codex-dispatch: package-lock.json changed → npm install in $(basename "$repo")"
        (cd "$repo" && npm install --no-audit --no-fund) \
          || echo "codex-dispatch: warning: npm install failed; run it manually." >&2 ;;
      yarn.lock|*/yarn.lock)
        echo "codex-dispatch: yarn.lock changed → yarn install in $(basename "$repo")"
        (cd "$repo" && yarn install) \
          || echo "codex-dispatch: warning: yarn install failed; run it manually." >&2 ;;
      pnpm-lock.yaml|*/pnpm-lock.yaml)
        echo "codex-dispatch: pnpm-lock.yaml changed → pnpm install in $(basename "$repo")"
        (cd "$repo" && pnpm install) \
          || echo "codex-dispatch: warning: pnpm install failed; run it manually." >&2 ;;
      bun.lock|bun.lockb|*/bun.lock|*/bun.lockb)
        echo "codex-dispatch: bun.lock changed → bun install in $(basename "$repo")"
        (cd "$repo" && bun install) \
          || echo "codex-dispatch: warning: bun install failed; run it manually." >&2 ;;
      Cargo.lock|*/Cargo.lock)
        echo "codex-dispatch: Cargo.lock changed → cargo fetch in $(basename "$repo")"
        (cd "$repo" && cargo fetch --quiet) \
          || echo "codex-dispatch: warning: cargo fetch failed; run it manually." >&2 ;;
      go.sum|*/go.sum)
        echo "codex-dispatch: go.sum changed → go mod download in $(basename "$repo")"
        (cd "$repo" && go mod download) \
          || echo "codex-dispatch: warning: go mod download failed; run it manually." >&2 ;;
      uv.lock|*/uv.lock)
        echo "codex-dispatch: uv.lock changed → uv sync in $(basename "$repo")"
        (cd "$repo" && uv sync) \
          || echo "codex-dispatch: warning: uv sync failed; run it manually." >&2 ;;
      Pipfile.lock|*/Pipfile.lock)
        echo "codex-dispatch: Pipfile.lock changed → pipenv install in $(basename "$repo")"
        (cd "$repo" && pipenv install) \
          || echo "codex-dispatch: warning: pipenv install failed; run it manually." >&2 ;;
      poetry.lock|*/poetry.lock)
        echo "codex-dispatch: poetry.lock changed → poetry install in $(basename "$repo")"
        (cd "$repo" && poetry install --no-interaction) \
          || echo "codex-dispatch: warning: poetry install failed; run it manually." >&2 ;;
      composer.lock|*/composer.lock|Gemfile.lock|*/Gemfile.lock|mix.lock|*/mix.lock)
        echo "codex-dispatch: warning: lockfile '$f' changed but auto-install not wired — run the install manually." >&2 ;;
    esac
  done <<< "$changed"
}

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

# --- checks -----------------------------------------------------------------
# d_run_checks <worktree> <cmd>...  -> sets D_CHECKS_JSON; returns 0 iff all pass.
D_CHECKS_JSON='[]'
d_run_checks() {
  local wt="$1"; shift
  local overall=0 c out code tail entries='[]'
  for c in "$@"; do
    [ -n "$c" ] || continue
    out="$(cd "$wt" && bash -c "$c" </dev/null 2>&1)"; code=$?
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

# d_has_changes <wt> <base-ref>  -> 0 if HEAD diverges from base (real work was
# produced), 1 if the branch is identical to base (a NO-OP run). Used to detect
# a backend that returned without changing anything.
d_has_changes()   { ! git -C "$1" diff --quiet "$2"..HEAD 2>/dev/null; }

# d_touches_tests  (reads file list on stdin) -> 0 if any path looks like a test
d_touches_tests() {
  grep -Eiq '(^|/)(tests?|__tests__|spec)(/|$)|_test\.|\.test\.|_spec\.|\.spec\.'
}

# --- orchestration: read-only (emit / verify / list / show) -----------------
# Moved verbatim from codex_dispatch.sh (Subsystem E Phase 1a). Worker-agnostic:
# they only read sidecars and format output. The hint text intentionally still
# names `codex_dispatch.sh` — re-pointing it to `dispatch …` is a Phase-1b change.

# Print the ALLOWED NEXT ACTIONS block for a dispatch in a given status.
d_emit_next_actions() {
  local id="$1" status="$2" verify="$3"
  echo
  echo "ALLOWED NEXT ACTIONS (pick exactly one):"
  case "$status" in
    needs_review)
      [ "$verify" != checks ] && echo "  codex_dispatch.sh show $id --diff      # review the diff"
      echo "  codex_dispatch.sh land $id            # after review/checks pass"
      echo "  codex_dispatch.sh resume $id \"<fb>\"    # send fixes to codex"
      echo "  codex_dispatch.sh abandon $id          # discard"
      ;;
    failed)
      echo "  codex_dispatch.sh show $id --diff      # inspect"
      echo "  codex_dispatch.sh resume $id \"<fb>\"    # retry with guidance"
      echo "  codex_dispatch.sh abandon $id          # discard"
      ;;
    noop)
      echo "  codex_dispatch.sh resume $id \"<fb>\"    # re-prompt with sharper, more explicit guidance"
      echo "  codex_dispatch.sh abandon $id          # discard (or take the change over yourself)"
      ;;
    landed|abandoned)
      echo "  (none — dispatch $status)"
      ;;
  esac
}

# Print the standard result summary for a dispatch id (diffstat by default).
d_emit_result() {
  local id="$1"
  local status verify branch wt base touches
  status="$(d_sc_get "$id" '.status')"
  verify="$(d_sc_get "$id" '.verify')"
  branch="$(d_sc_get "$id" '.branch')"
  wt="$(d_sc_get "$id" '.worktree')"
  base="$(d_sc_get "$id" '.base_ref')"
  touches="$(d_sc_get "$id" '.touches_tests')"
  echo "Dispatch $id"
  echo "  status:   $status"
  echo "  verify:   $verify   retries_used: $(d_sc_get "$id" '.retries_used')/$(d_sc_get "$id" '.retry_budget')"
  local be; be="$(d_sc_get "$id" '.backend')"; [ -n "$be" ] || be="codex"
  echo "  backend:  $be"
  echo "  branch:   $branch"
  echo "  worktree: $wt"
  echo "  codex:    $(d_sc_get "$id" '.codex_last_message')"
  if [ "$status" = noop ]; then
    echo "  ⚠ backend produced NO changes (empty diff vs base) — nothing to review or land."
  elif [ "$(d_sc_get "$id" '.noop_resume')" = "true" ]; then
    echo "  ⚠ a corrective resume produced no changes — the model is stuck; re-prompt more explicitly or take over."
  fi
  [ "$touches" = "true" ] && echo "  ⚠ diff modifies tests — review recommended before landing"
  echo "  checks:"
  d_sc_get "$id" '.checks[] | "    [\(.exit)] \(.cmd)"' 2>/dev/null || true
  echo "  diffstat:"
  if [ -d "$wt" ]; then d_diffstat "$wt" "$base" | sed 's/^/    /'; else echo "    (worktree removed)"; fi
  d_emit_next_actions "$id" "$status" "$verify"
}

# d_verification_satisfied <id> <verify> <reviewed-flag> — 0 if landing is allowed.
d_verification_satisfied() {
  local id="$1" verify="$2" reviewed="$3"
  case "$verify" in
    checks|both)
      # every recorded check must have exited 0, and there must be at least one
      local n bad
      n="$(d_sc_get "$id" '.checks | length')"; [ "${n:-0}" -ge 1 ] || return 1
      bad="$(d_sc_get "$id" '[.checks[] | select(.exit != 0)] | length')"
      [ "${bad:-0}" -eq 0 ] || return 1
      ;;
  esac
  # review-only REQUIRES --reviewed. 'both' is satisfied by passing checks alone:
  # the diff-review for 'both' is Claude's skill-enforced responsibility, not something
  # the engine can verify, so 'both' returns 0 here even without --reviewed.
  case "$verify" in
    review|both) [ "$reviewed" -eq 1 ] || { [ "$verify" = both ] && return 0; return 1; } ;;
  esac
  return 0
}

d_show() {
  local id="" want_diff=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --diff) want_diff=1; shift;;
      -*) die "unknown flag: $1";;
      *) id="$1"; shift;;
    esac
  done
  [ -n "$id" ] || die "show requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  d_emit_result "$id"
  if [ "$want_diff" -eq 1 ]; then
    local wt base; wt="$(d_sc_get "$id" '.worktree')"; base="$(d_sc_get "$id" '.base_ref')"
    echo
    echo "FULL DIFF ($id):"
    if [ -d "$wt" ]; then d_full_diff "$wt" "$base"; else echo "  (worktree gone)"; fi
  fi
}

d_list() {
  d_in_git_repo || die "not in a git repository"
  local ids; ids="$(d_list_ids)"
  if [ -z "$ids" ]; then echo "No dispatches for this repo."; return 0; fi
  echo "Dispatches (this repo):"
  printf '  %-26s %-13s %-8s %-7s %s\n' "ID" "STATUS" "VERIFY" "BACKEND" "BRANCH"
  local id be
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    be="$(d_sc_get "$id" '.backend')"; [ -n "$be" ] || be="codex"
    printf '  %-26s %-13s %-8s %-7s %s\n' \
      "$id" "$(d_sc_get "$id" '.status')" "$(d_sc_get "$id" '.verify')" "$be" "$(d_sc_get "$id" '.branch')"
  done <<< "$ids"
}

# --- orchestration: mutating (land / abandon / doctor + the on-land hook) ----
# Moved verbatim from codex_dispatch.sh (Subsystem E Phase 1a, Task 3). These
# mutate git state but stay worker-agnostic. The subsystem-B curator feed that
# used to live inline in land is pulled into the overridable d_on_land hook.

# d_on_land <id> — overridable post-land hook. DEFAULT: feed the landed dispatch's
# codex log to the subsystem-B curator inbox, IFF the profile machinery is present
# (resolve_active_profile / profile_dir come from lib/paths.sh, which the CLIs
# source but the library does NOT). A standalone/portable embedding without those
# symbols gets a clean no-op. Redefine this function after sourcing the lib to
# customize. Keeps lib/dispatch-lib.sh free of any hard paths.sh dependency.
d_on_land() {
  local id="$1"
  command -v resolve_active_profile >/dev/null 2>&1 || return 0
  command -v profile_dir          >/dev/null 2>&1 || return 0
  local _prof _inbox _log _task _backend _ts
  _prof="$(resolve_active_profile)"
  _inbox="$(profile_dir "$_prof")/curator/inbox"
  _log="$(d_sidecar_dir)/$id.codexlog.jsonl"
  [ -f "$_log" ] || return 0
  _task="$(d_sc_get "$id" '.prompt')"
  _backend="$(d_sc_get "$id" '.backend')"; [ -n "$_backend" ] || _backend="codex"
  _ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$_inbox"
  jq -nc --arg ts "$_ts" --arg prof "$_prof" --arg id "$id" --arg log "$_log" \
         --arg task "$_task" --arg be "$_backend" \
    '{kind:"codex_run", captured_at:$ts, profile:$prof, dispatch_id:$id,
      log_path:$log, task:$task, backend:$be}' \
    > "$_inbox/${_ts}-codex-${id}.json" 2>/dev/null || true
}

d_land() {
  local id="" reviewed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reviewed) reviewed=1; shift;;
      -*) die "unknown flag: $1";;
      *) id="$1"; shift;;
    esac
  done
  [ -n "$id" ] || die "land requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local status verify branch wt repo
  status="$(d_sc_get "$id" '.status')"
  verify="$(d_sc_get "$id" '.verify')"
  branch="$(d_sc_get "$id" '.branch')"
  wt="$(d_sc_get "$id" '.worktree')"
  repo="$(d_repo_root)"

  [ "$status" = needs_review ] || die "cannot land: status is '$status' (need needs_review)"
  if ! d_verification_satisfied "$id" "$verify" "$reviewed"; then
    case "$verify" in
      review|both) die "verify=$verify requires confirming your review: pass --reviewed to land $id";;
      *)           die "checks did not all pass — resume or abandon $id";;
    esac
  fi
  [ -d "$wt" ] || die "worktree missing for '$id' (run: codex_dispatch.sh doctor)"

  # rebase the dispatch branch onto current HEAD inside the worktree (R1/flag #2)
  local cur; cur="$(d_head_sha)"
  if ! git -C "$wt" rebase "$cur" >/dev/null 2>&1; then
    git -C "$wt" rebase --abort >/dev/null 2>&1 || true
    d_sc_set "$id" '.updated_at=$u' --arg u "$(d_now)"   # status stays needs_review
    echo "codex-dispatch: land aborted — rebase conflict against current HEAD." >&2
    echo "codex-dispatch: worktree kept at $wt; resolve, then resume/land, or abandon $id." >&2
    return 1
  fi
  # re-run checks post-rebase for checks modes
  case "$verify" in
    checks|both)
      local -a cmds=()
      while IFS= read -r line; do [ -n "$line" ] && cmds+=("$line"); done \
        < <(d_sc_get "$id" '.requested_checks[]')
      if [ "${#cmds[@]}" -gt 0 ]; then
        d_run_checks "$wt" "${cmds[@]}" || die "checks failed after rebase — resume or abandon $id"
        d_sc_set "$id" '.checks=$c' --argjson c "$D_CHECKS_JSON"
      fi
      ;;
  esac

  # fast-forward merge into the working branch, then clean up
  local pre_merge_sha; pre_merge_sha="$(d_head_sha)"
  git -C "$repo" merge --ff-only "$branch" >/dev/null 2>&1 \
    || die "merge failed unexpectedly for $branch"
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 \
    || echo "codex-dispatch: warning: merged, but could not remove worktree $wt (remove manually; doctor reconciles)." >&2
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  d_sync_deps "$repo" "$pre_merge_sha" "$(d_head_sha)"
  d_sc_set "$id" '.status="landed"|.updated_at=$u' --arg u "$(d_now)"
  d_on_land "$id"
  echo "Landed $id onto $(d_cur_branch) (branch $branch merged, worktree removed)."
}

d_abandon() {
  local id="${1:-}"
  [ -n "$id" ] || die "abandon requires a dispatch id"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local wt branch repo; wt="$(d_sc_get "$id" '.worktree')"; branch="$(d_sc_get "$id" '.branch')"
  repo="$(d_repo_root)"
  if [ -d "$wt" ]; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 \
      || echo "codex-dispatch: warning: could not remove worktree $wt (remove it manually)." >&2
  fi
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  d_sc_set "$id" '.status="abandoned"|.updated_at=$u' --arg u "$(d_now)"
  echo "Abandoned $id (worktree + branch removed)."
}

# doctor: reconcile sidecars against reality, prune nothing destructively but mark
# orphans (worktree gone while still 'active'), and report the codex version.
d_doctor() {
  d_in_git_repo || die "not in a git repository"
  echo "codex-dispatch doctor"
  local ver; ver="$(${CODEX_DISPATCH_CODEX_BIN:-codex} --version 2>/dev/null || echo 'codex: NOT FOUND')"
  echo "  codex version: $ver"
  local _lb="n/a (local backend not loaded)"
  command -v l_probe >/dev/null 2>&1 && _lb="$(l_probe)  (endpoint $(l_endpoint))"
  echo "  local backend: $_lb"
  local ids; ids="$(d_list_ids)"
  if [ -z "$ids" ]; then echo "  no dispatches."; return 0; fi
  local id status wt
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    status="$(d_sc_get "$id" '.status')"
    wt="$(d_sc_get "$id" '.worktree')"
    case "$status" in
      running|verifying|needs_review|failed|noop)
        if [ ! -d "$wt" ]; then
          d_sc_set "$id" '.status="lost"|.updated_at=$u' --arg u "$(d_now)"
          echo "  ⚠ $id: worktree missing → marked 'lost' (orphan reconciled)"
        else
          echo "  ok $id ($status)"
        fi
        ;;
      landed|abandoned|lost) echo "  ok $id ($status)";;
      *) echo "  ? $id (unknown status '$status')";;
    esac
  done <<< "$ids"
  # prune git's worktree admin for any dirs we removed
  git worktree prune >/dev/null 2>&1 || true
}

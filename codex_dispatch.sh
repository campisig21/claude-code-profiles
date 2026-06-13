#!/usr/bin/env bash
# codex_dispatch.sh — the codex dev-process dispatch engine (subsystem C).
# Claude is the policy-maker; this engine is a deterministic mechanism.
# Commands: dispatch | quick | resume | show | land | abandon | list | doctor
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/jsonutil.sh"
source "$HERE/lib/dispatch.sh"
source "$HERE/lib/local.sh"
source "$HERE/lib/paths.sh"

# die / emit_next_actions / emit_result now live in lib/dispatch-lib.sh
# (sourced above via lib/dispatch.sh) — Subsystem E Phase 1a, Task 2.

cmd_dispatch() {
  local verify=both retry=1 slug="" backend=codex ensure_up=0
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify)  verify="$2"; shift 2;;
      --check)   checks+=("$2"); shift 2;;
      --retry)   retry="$2"; shift 2;;
      --slug)    slug="$2"; shift 2;;
      --backend) backend="$2"; shift 2;;
      --ensure-up) ensure_up=1; shift;;
      --)        shift; break;;
      -*)        die "unknown flag: $1";;
      *)         break;;
    esac
  done
  local prompt="${1:-}"
  [ -n "$prompt" ] || die "dispatch requires a prompt"
  case "$verify" in checks|review|both) ;; *) die "invalid --verify: $verify (want checks|review|both)";; esac
  case "$retry" in ''|*[!0-9]*) die "--retry must be a non-negative integer (got: $retry)";; esac
  # checks-bearing modes need at least one check, else the dispatch is un-landable
  # (verification_satisfied requires a passing check). Steer no-checks work to review.
  case "$verify" in
    checks|both) [ "${#checks[@]}" -gt 0 ] || die "--verify $verify needs at least one --check '<cmd>' (use --verify review for a no-checks dispatch)";;
  esac
  d_in_git_repo || die "not in a git repository — cd into the repo you want codex to work on"

  case "$backend" in codex|local|ollama) ;; *) die "invalid --backend: $backend (want codex|local|ollama)";; esac
  local bargs; bargs="$(d_backend_args "$backend")" || die "invalid --backend: $backend (want codex|local|ollama)"
  if [ "$backend" = local ]; then
    if ! l_ready; then
      if [ "$ensure_up" -eq 1 ]; then
        l_up || die "ensure-up failed to make local ready (state: $(l_probe))"
      else
        die "local model not ready (state: $(l_probe)). Load it first:  codex_dispatch.sh local-up  (or pass --ensure-up)"
      fi
    fi
  fi

  local repo base_ref id short branch wt
  repo="$(d_repo_root)"
  base_ref="$(d_head_sha)"
  slug="$(d_slugify "${slug:-$prompt}")"   # always slugify (sanitizes explicit --slug too: no /, spaces, etc.)
  [ -n "$slug" ] || slug="dispatch"
  id="$(d_now)-$slug"
  short="$(d_short "$id")"
  branch="codex/$slug-$short"
  wt="$(d_worktree_root)/$id"

  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" && die "branch already exists: $branch"
  [ -e "$wt" ] && die "worktree path already exists: $wt"

  mkdir -p "$(d_sidecar_dir)" "$(d_worktree_root)"
  d_ensure_worktree_gitignore "$repo"
  git -C "$repo" worktree add -q -b "$branch" "$wt" "$base_ref" \
    || die "failed to create worktree at $wt"

  # init sidecar
  local checks_json='[]'
  if [ "${#checks[@]}" -gt 0 ]; then
    checks_json="$(printf '%s\n' "${checks[@]}" | jq -R . | jq -s '.')"
  fi
  jq -n --arg id "$id" --arg now "$(d_now)" --arg repo "$repo" --arg wt "$wt" \
        --arg branch "$branch" --arg base "$base_ref" --arg verify "$verify" \
        --argjson retry "$retry" --argjson reqchecks "$checks_json" --arg prompt "$prompt" \
        --arg backend "$backend" \
    '{id:$id, created_at:$now, updated_at:$now, repo:$repo, worktree:$wt, branch:$branch,
      base_ref:$base, verify:$verify, retry_budget:$retry, retries_used:0,
      requested_checks:$reqchecks, session_id:null, status:"running",
      checks:[], touches_tests:false, codex_last_message:null, prompt:$prompt,
      backend:$backend}' \
    > "$(d_sidecar_path "$id")"

  # run codex (fresh exec)
  local lastmsg session
  lastmsg="$(mktemp)"
  session="$(d_codex_exec "$id" "$wt" "$lastmsg" "$prompt" $bargs)"
  d_sc_set "$id" '.session_id=(if $s=="" then null else $s end)|.codex_last_message=$m|.updated_at=$u' \
    --arg s "$session" --arg m "$(cat "$lastmsg" 2>/dev/null)" --arg u "$(d_now)"
  rm -f "$lastmsg"

  # commit codex's work onto the dispatch branch
  d_commit_worktree "$wt" "codex: $slug (dispatch $id)" || true

  # NO-OP guard: if the backend produced nothing, don't run/trust checks against
  # an unchanged tree (they'd report on base, masquerading as a real result).
  # Surface a distinct 'noop' status so the caller re-prompts, abandons, or takes over.
  if ! d_has_changes "$wt" "$base_ref"; then
    d_sc_set "$id" '.status="noop"|.updated_at=$u' --arg u "$(d_now)"
    d_emit_result "$id"
    return 0
  fi

  # verify (may auto-retry, adding more commits to the branch)
  finish_verify "$id" "$wt" "$verify"

  # touches-tests signal — computed from the FINAL diff (incl. any retry commits)
  local touches=false
  if d_changed_files "$wt" "$base_ref" | d_touches_tests; then touches=true; fi
  d_sc_set "$id" '.touches_tests=$t' --argjson t "$touches"

  d_emit_result "$id"
}

# finish_verify <id> <wt> <verify> — runs checks with the dispatch's retry budget,
# self-correcting via codex resume on failure. Sets needs_review|failed.
finish_verify() {
  local id="$1" wt="$2" verify="$3"
  if [ "$verify" = review ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
    return 0
  fi
  local -a cmds=()
  while IFS= read -r line; do [ -n "$line" ] && cmds+=("$line"); done \
    < <(d_sc_get "$id" '.requested_checks[]')
  if [ "${#cmds[@]}" -eq 0 ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
    return 0
  fi

  local budget used session slug ok
  budget="$(d_sc_get "$id" '.retry_budget')"
  used="$(d_sc_get "$id" '.retries_used')"
  session="$(d_sc_get "$id" '.session_id')"
  slug="$(d_sc_get "$id" '.id')"
  local backend bargs
  backend="$(d_sc_get "$id" '.backend')"; [ -n "$backend" ] || backend=codex
  bargs="$(d_backend_args "$backend")" || bargs=""
  # defense-in-depth: a corrupt/non-numeric budget must never spin the loop forever
  case "$budget" in ''|*[!0-9]*) budget=0;; esac
  case "$used"   in ''|*[!0-9]*) used=0;; esac

  while :; do
    # NOTE: 'verifying' is transient; if the process dies here the sidecar stays
    # 'verifying' and is reconciled by 'codex_dispatch.sh doctor' (Task 8).
    d_sc_set "$id" '.status="verifying"|.updated_at=$u' --arg u "$(d_now)"
    d_run_checks "$wt" "${cmds[@]}"; ok=$?
    d_sc_set "$id" '.checks=$c|.updated_at=$u' --argjson c "$D_CHECKS_JSON" --arg u "$(d_now)"
    if [ "$ok" -eq 0 ]; then
      d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
      return 0
    fi
    if [ "$used" -ge "$budget" ]; then
      d_sc_set "$id" '.status="failed"|.updated_at=$u' --arg u "$(d_now)"
      return 0
    fi
    # resume codex with the failure output, then re-verify
    local fb; fb="The checks failed. Output:
$(printf '%s' "$D_CHECKS_JSON" | jq -r '.[] | "$ \(.cmd)\n\(.output_tail)"')
Fix the code so all checks pass."
    d_codex_resume "$id" "$wt" "$session" "$fb" $bargs
    # A corrective resume that changes nothing means the model is stuck. Stop
    # immediately — don't spin the remaining retry budget re-running identical
    # failing checks. Mark it failed with a noop_resume flag so the caller knows.
    if ! d_commit_worktree "$wt" "codex: resume fix ($slug)"; then
      d_sc_set "$id" '.status="failed"|.noop_resume=true|.updated_at=$u' --arg u "$(d_now)"
      return 0
    fi
    used=$((used + 1))
    d_sc_set "$id" '.retries_used=$n|.updated_at=$u' --argjson n "$used" --arg u "$(d_now)"
  done
}

# cmd_resume <id> <feedback> — resume a dispatch's codex session with Claude
# feedback, re-commit, re-verify. Counts as one retry use.
cmd_resume() {
  local id="${1:-}" fb="${2:-}"
  [ -n "$id" ] || die "resume requires a dispatch id"
  [ -n "$fb" ] || die "resume requires a feedback prompt"
  d_sidecar_exists "$id" || die "unknown dispatch '$id'. Known: $(d_list_ids | tr '\n' ' ')"
  local status; status="$(d_sc_get "$id" '.status')"
  case "$status" in
    needs_review|failed|noop) ;;
    *) die "cannot resume a dispatch in status '$status'";;
  esac
  local wt session used slug verify
  wt="$(d_sc_get "$id" '.worktree')"
  session="$(d_sc_get "$id" '.session_id')"
  used="$(d_sc_get "$id" '.retries_used')"
  slug="$(d_sc_get "$id" '.id')"
  verify="$(d_sc_get "$id" '.verify')"
  local backend bargs
  backend="$(d_sc_get "$id" '.backend')"; [ -n "$backend" ] || backend=codex
  bargs="$(d_backend_args "$backend")" || bargs=""
  [ -d "$wt" ] || die "worktree missing for '$id' (run: codex_dispatch.sh doctor)"
  local base; base="$(d_sc_get "$id" '.base_ref')"
  # clear any stale stuck-flag from a prior auto-retry before re-running
  d_sc_set "$id" '.noop_resume=false'

  d_codex_resume "$id" "$wt" "$session" "$fb" $bargs
  d_commit_worktree "$wt" "codex: resume ($slug)" || true
  used=$((used + 1))
  d_sc_set "$id" '.retries_used=$n|.updated_at=$u' --argjson n "$used" --arg u "$(d_now)"

  # NO-OP guard: a resume that left the branch identical to base produced nothing.
  if ! d_has_changes "$wt" "$base"; then
    d_sc_set "$id" '.status="noop"|.updated_at=$u' --arg u "$(d_now)"
    d_emit_result "$id"
    return 0
  fi

  finish_verify "$id" "$wt" "$verify"

  # touches-tests signal — computed from the FINAL diff (incl. any retry commits)
  local touches=false
  if d_changed_files "$wt" "$base" | d_touches_tests; then touches=true; fi
  d_sc_set "$id" '.touches_tests=$t' --argjson t "$touches"

  d_emit_result "$id"
}

# cmd_show / verification_satisfied moved to lib/dispatch-lib.sh as
# d_show / d_verification_satisfied — Subsystem E Phase 1a, Task 2.

# cmd_land moved to lib/dispatch-lib.sh as d_land — the inline B.2 curator feed
# is now the overridable d_on_land hook — Subsystem E Phase 1a, Task 3.

# cmd_abandon moved to lib/dispatch-lib.sh as d_abandon — Subsystem E Phase 1a, Task 3.

# quick: run codex in the CURRENT working tree (no worktree/branch/sidecar).
# Refuses a dirty tree unless --snapshot, which records a restore point first.
cmd_quick() {
  local verify=none snapshot=0 backend=codex ensure_up=0
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify)   verify="$2"; shift 2;;
      --check)    checks+=("$2"); shift 2;;
      --snapshot) snapshot=1; shift;;
      --backend)  backend="$2"; shift 2;;
      --ensure-up) ensure_up=1; shift;;
      --) shift; break;;
      -*) die "unknown flag: $1";;
      *) break;;
    esac
  done
  local prompt="${1:-}"
  [ -n "$prompt" ] || die "quick requires a prompt"
  case "$verify" in none|checks|review|both) ;; *) die "invalid --verify: $verify";; esac
  d_in_git_repo || die "not in a git repository"
  local repo; repo="$(d_repo_root)"

  case "$backend" in codex|local|ollama) ;; *) die "invalid --backend: $backend (want codex|local|ollama)";; esac
  local bargs; bargs="$(d_backend_args "$backend")" || die "invalid --backend: $backend (want codex|local|ollama)"
  if [ "$backend" = local ]; then
    if ! l_ready; then
      if [ "$ensure_up" -eq 1 ]; then
        l_up || die "ensure-up failed to make local ready (state: $(l_probe))"
      else
        die "local model not ready (state: $(l_probe)). Load it first:  codex_dispatch.sh local-up  (or pass --ensure-up)"
      fi
    fi
  fi

  if d_tree_dirty; then
    if [ "$snapshot" -eq 0 ]; then
      die "working tree is dirty — commit/stash first, or pass --snapshot to record a restore point"
    fi
    local snap; snap="$(git -C "$repo" stash create "codex-quick snapshot $(d_now)")"
    if [ -n "$snap" ]; then
      git -C "$repo" update-ref "refs/codex-dispatch-snapshots/$(d_now)" "$snap"
      echo "Recorded snapshot $snap — restore with:  git stash apply $snap"
    else
      echo "codex-dispatch: warning: nothing to snapshot (dirty tree is untracked-only; git stash create can't capture it) — proceeding WITHOUT a restore point." >&2
    fi
  fi

  # snapshot the tree so we can tell whether the backend actually changed anything
  local pre_state; pre_state="$(git -C "$repo" status --porcelain 2>/dev/null; git -C "$repo" diff 2>/dev/null)"
  local lastmsg session qid; lastmsg="$(mktemp)"
  qid="quick-$(d_now)"
  session="$(d_codex_exec "$qid" "$repo" "$lastmsg" "$prompt" $bargs)"
  echo "codex: $(cat "$lastmsg" 2>/dev/null)"
  rm -f "$lastmsg"

  if [ "$verify" != none ] && [ "$verify" != review ] && [ "${#checks[@]}" -gt 0 ]; then
    if d_run_checks "$repo" "${checks[@]}"; then
      echo "checks: PASS"
    else
      echo "checks: FAIL"
      printf '%s' "$D_CHECKS_JSON" | jq -r '.[] | "  [\(.exit)] \(.cmd)\n\(.output_tail)"'
    fi
  fi

  echo
  echo "DIFF (in-place, not committed):"
  git -C "$repo" --no-pager diff                       # tracked modifications
  # new (untracked) files codex created — shown WITHOUT mutating the index
  local nf
  while IFS= read -r nf; do
    [ -n "$nf" ] || continue
    git -C "$repo" --no-pager diff --no-index -- /dev/null "$nf" 2>/dev/null || true
  done < <(git -C "$repo" ls-files --others --exclude-standard)
  echo
  local post_state; post_state="$(git -C "$repo" status --porcelain 2>/dev/null; git -C "$repo" diff 2>/dev/null)"
  if [ "$pre_state" = "$post_state" ]; then
    echo "⚠ no changes were made to the working tree (backend produced a NO-OP — re-prompt more explicitly or take over)."
  fi
  echo "Quick edits are in your working tree. Review, then commit or revert yourself."
  echo "Iterate with:  codex exec resume --last${bargs:+ $bargs} -C $repo \"<feedback>\""
}

# cmd_doctor moved to lib/dispatch-lib.sh as d_doctor (the l_probe/l_endpoint
# line is command-v guarded there) — Subsystem E Phase 1a, Task 3.

# cmd_list moved to lib/dispatch-lib.sh as d_list — Subsystem E Phase 1a, Task 2.

main() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    dispatch) cmd_dispatch "$@" ;;
    resume)   cmd_resume "$@" ;;
    show)     d_show "$@" ;;
    list)     d_list "$@" ;;
    land)     d_land "$@" ;;
    abandon)  d_abandon "$@" ;;
    quick)      cmd_quick "$@" ;;
    doctor)     d_doctor "$@" ;;
    local-up)   l_up "$@" ;;
    local-down) l_down "$@" ;;
    *)          die "unknown subcommand: $sub" ;;
  esac
}
main "$@"

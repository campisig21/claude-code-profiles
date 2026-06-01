#!/usr/bin/env bash
# codex_dispatch.sh — the codex dev-process dispatch engine (subsystem C).
# Claude is the policy-maker; this engine is a deterministic mechanism.
# Commands: dispatch | quick | resume | show | land | abandon | list | doctor
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/jsonutil.sh"
source "$HERE/lib/dispatch.sh"

die() { echo "codex-dispatch: $*" >&2; exit 1; }

# Print the ALLOWED NEXT ACTIONS block for a dispatch in a given status.
emit_next_actions() {
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
    landed|abandoned)
      echo "  (none — dispatch $status)"
      ;;
  esac
}

# Print the standard result summary for a dispatch id (diffstat by default).
emit_result() {
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
  echo "  branch:   $branch"
  echo "  worktree: $wt"
  echo "  codex:    $(d_sc_get "$id" '.codex_last_message')"
  [ "$touches" = "true" ] && echo "  ⚠ diff modifies tests — review recommended before landing"
  echo "  checks:"
  d_sc_get "$id" '.checks[] | "    [\(.exit)] \(.cmd)"' 2>/dev/null || true
  echo "  diffstat:"
  if [ -d "$wt" ]; then d_diffstat "$wt" "$base" | sed 's/^/    /'; else echo "    (worktree removed)"; fi
  emit_next_actions "$id" "$status" "$verify"
}

cmd_dispatch() {
  local verify=both retry=1 slug=""
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify) verify="$2"; shift 2;;
      --check)  checks+=("$2"); shift 2;;
      --retry)  retry="$2"; shift 2;;
      --slug)   slug="$2"; shift 2;;
      --)       shift; break;;
      -*)       die "unknown flag: $1";;
      *)        break;;
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
    '{id:$id, created_at:$now, updated_at:$now, repo:$repo, worktree:$wt, branch:$branch,
      base_ref:$base, verify:$verify, retry_budget:$retry, retries_used:0,
      requested_checks:$reqchecks, session_id:null, status:"running",
      checks:[], touches_tests:false, codex_last_message:null, prompt:$prompt}' \
    > "$(d_sidecar_path "$id")"

  # run codex (fresh exec)
  local lastmsg session
  lastmsg="$(mktemp)"
  session="$(d_codex_exec "$wt" "$lastmsg" "$prompt")"
  d_sc_set "$id" '.session_id=(if $s=="" then null else $s end)|.codex_last_message=$m|.updated_at=$u' \
    --arg s "$session" --arg m "$(cat "$lastmsg" 2>/dev/null)" --arg u "$(d_now)"
  rm -f "$lastmsg"

  # commit codex's work onto the dispatch branch
  d_commit_worktree "$wt" "codex: $slug (dispatch $id)" || true

  # verify (may auto-retry, adding more commits to the branch)
  finish_verify "$id" "$wt" "$verify"

  # touches-tests signal — computed from the FINAL diff (incl. any retry commits)
  local touches=false
  if d_changed_files "$wt" "$base_ref" | d_touches_tests; then touches=true; fi
  d_sc_set "$id" '.touches_tests=$t' --argjson t "$touches"

  emit_result "$id"
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
    d_codex_resume "$wt" "$session" "$fb"
    d_commit_worktree "$wt" "codex: resume fix ($slug)" || true
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
    needs_review|failed) ;;
    *) die "cannot resume a dispatch in status '$status'";;
  esac
  local wt session used slug verify
  wt="$(d_sc_get "$id" '.worktree')"
  session="$(d_sc_get "$id" '.session_id')"
  used="$(d_sc_get "$id" '.retries_used')"
  slug="$(d_sc_get "$id" '.id')"
  verify="$(d_sc_get "$id" '.verify')"
  [ -d "$wt" ] || die "worktree missing for '$id' (run: codex_dispatch.sh doctor)"

  d_codex_resume "$wt" "$session" "$fb"
  d_commit_worktree "$wt" "codex: resume ($slug)" || true
  used=$((used + 1))
  d_sc_set "$id" '.retries_used=$n|.updated_at=$u' --argjson n "$used" --arg u "$(d_now)"

  finish_verify "$id" "$wt" "$verify"

  # touches-tests signal — computed from the FINAL diff (incl. any retry commits)
  local base; base="$(d_sc_get "$id" '.base_ref')"
  local touches=false
  if d_changed_files "$wt" "$base" | d_touches_tests; then touches=true; fi
  d_sc_set "$id" '.touches_tests=$t' --argjson t "$touches"

  emit_result "$id"
}

cmd_show() {
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
  emit_result "$id"
  if [ "$want_diff" -eq 1 ]; then
    local wt base; wt="$(d_sc_get "$id" '.worktree')"; base="$(d_sc_get "$id" '.base_ref')"
    echo
    echo "FULL DIFF ($id):"
    if [ -d "$wt" ]; then d_full_diff "$wt" "$base"; else echo "  (worktree gone)"; fi
  fi
}

# verification_satisfied <id> <verify> <reviewed-flag> — 0 if landing is allowed.
verification_satisfied() {
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

cmd_land() {
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
  if ! verification_satisfied "$id" "$verify" "$reviewed"; then
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
  git -C "$repo" merge --ff-only "$branch" >/dev/null 2>&1 \
    || die "merge failed unexpectedly for $branch"
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 \
    || echo "codex-dispatch: warning: merged, but could not remove worktree $wt (remove manually; doctor reconciles)." >&2
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  d_sc_set "$id" '.status="landed"|.updated_at=$u' --arg u "$(d_now)"
  echo "Landed $id onto $(d_cur_branch) (branch $branch merged, worktree removed)."
}

cmd_abandon() {
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

# quick: run codex in the CURRENT working tree (no worktree/branch/sidecar).
# Refuses a dirty tree unless --snapshot, which records a restore point first.
cmd_quick() {
  local verify=none snapshot=0
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify)   verify="$2"; shift 2;;
      --check)    checks+=("$2"); shift 2;;
      --snapshot) snapshot=1; shift;;
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

  local lastmsg session; lastmsg="$(mktemp)"
  session="$(d_codex_exec "$repo" "$lastmsg" "$prompt")"
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
  echo "Quick edits are in your working tree. Review, then commit or revert yourself."
  echo "Iterate with:  codex exec resume --last -C $repo \"<feedback>\""
}

# doctor: reconcile sidecars against reality, prune nothing destructively but mark
# orphans (worktree gone while still 'active'), and report the codex version.
cmd_doctor() {
  d_in_git_repo || die "not in a git repository"
  echo "codex-dispatch doctor"
  local ver; ver="$(${CODEX_DISPATCH_CODEX_BIN:-codex} --version 2>/dev/null || echo 'codex: NOT FOUND')"
  echo "  codex version: $ver"
  local ids; ids="$(d_list_ids)"
  if [ -z "$ids" ]; then echo "  no dispatches."; return 0; fi
  local id status wt
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    status="$(d_sc_get "$id" '.status')"
    wt="$(d_sc_get "$id" '.worktree')"
    case "$status" in
      running|verifying|needs_review|failed)
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

cmd_list() {
  d_in_git_repo || die "not in a git repository"
  local ids; ids="$(d_list_ids)"
  if [ -z "$ids" ]; then echo "No dispatches for this repo."; return 0; fi
  echo "Dispatches (this repo):"
  printf '  %-26s %-13s %-8s %s\n' "ID" "STATUS" "VERIFY" "BRANCH"
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '  %-26s %-13s %-8s %s\n' \
      "$id" "$(d_sc_get "$id" '.status')" "$(d_sc_get "$id" '.verify')" "$(d_sc_get "$id" '.branch')"
  done <<< "$ids"
}

main() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    dispatch) cmd_dispatch "$@" ;;
    resume)   cmd_resume "$@" ;;
    show)     cmd_show "$@" ;;
    list)     cmd_list "$@" ;;
    land)     cmd_land "$@" ;;
    abandon)  cmd_abandon "$@" ;;
    quick)    cmd_quick "$@" ;;
    doctor)   cmd_doctor "$@" ;;
    *)        die "unknown subcommand: $sub" ;;
  esac
}
main "$@"

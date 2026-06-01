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
  d_diffstat "$wt" "$base" | sed 's/^/    /'
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
  d_in_git_repo || die "not in a git repository — cd into the repo you want codex to work on"

  local repo base_ref id short branch wt
  repo="$(d_repo_root)"
  base_ref="$(d_head_sha)"
  [ -n "$slug" ] || slug="$(d_slugify "$prompt")"
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

  # touches-tests signal
  local touches=false
  if d_changed_files "$wt" "$base_ref" | d_touches_tests; then touches=true; fi
  d_sc_set "$id" '.touches_tests=$t' --argjson t "$touches"

  # verify
  finish_verify "$id" "$wt" "$verify" "$retry"
  emit_result "$id"
}

# finish_verify <id> <wt> <verify> <retry_budget> — runs checks (if applicable),
# sets terminal status (needs_review|failed). Retry loop added in Task 4.
finish_verify() {
  local id="$1" wt="$2" verify="$3" retry="$4"
  if [ "$verify" = review ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
    return 0
  fi
  d_sc_set "$id" '.status="verifying"|.updated_at=$u' --arg u "$(d_now)"
  local -a cmds=()
  while IFS= read -r line; do [ -n "$line" ] && cmds+=("$line"); done \
    < <(d_sc_get "$id" '.requested_checks[]')
  if [ "${#cmds[@]}" -eq 0 ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
    return 0
  fi
  d_run_checks "$wt" "${cmds[@]}"; local ok=$?
  d_sc_set "$id" '.checks=$c|.updated_at=$u' --argjson c "$D_CHECKS_JSON" --arg u "$(d_now)"
  if [ "$ok" -eq 0 ]; then
    d_sc_set "$id" '.status="needs_review"|.updated_at=$u' --arg u "$(d_now)"
  else
    d_sc_set "$id" '.status="failed"|.updated_at=$u' --arg u "$(d_now)"
  fi
}

main() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    dispatch) cmd_dispatch "$@" ;;
    quick|resume|show|land|abandon|list|doctor)
              die "subcommand '$sub' not implemented yet" ;;   # Tasks 4-8
    *)        die "unknown subcommand: $sub" ;;
  esac
}
main "$@"

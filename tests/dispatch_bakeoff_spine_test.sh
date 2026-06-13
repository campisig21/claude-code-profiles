#!/usr/bin/env bash
# Bake-off spine (library level): two contestants reach needs_review in distinct
# worktrees; the orchestrator lands EXACTLY ONE and abandons the rest. Proves
# spec §5.6 "lands exactly one via the same land <id>" without the JS orchestrator
# (which is harness-run and not bash-testable — see the plan's test-strategy note).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
FAKE="$(ps_make_fake_codex)"            # honors -C/-o/--json; pass behavior writes IMPL=ok
export CODEX_DISPATCH_CODEX_BIN="$FAKE"
ro="$(ps_make_sandbox_repo ok)"

base_head() { git -C "$ro" rev-parse HEAD; }

# --- Fan out two contestants: SAME slug, DIFFERENT --label (the bake-off shape) ----
A="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T130000Z bash "$DISPATCH" begin race --label gpt-5.5 --verify checks )"
B="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T130001Z bash "$DISPATCH" begin race --label qwen2.5 --verify checks )"
assert_eq "$A" "20260613T130000Z-race-gpt-5-5" "contestant A id embeds the label"
assert_eq "$B" "20260613T130001Z-race-qwen2-5" "contestant B id embeds the label"

# Each contestant: codex-run (fake writes IMPL=ok in ITS OWN worktree) -> verify once -> record.
( cd "$ro" && bash "$DISPATCH" codex-run "$A" --backend codex -m gpt-5.5 "implement A" ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" codex-run "$B" --backend codex -m qwen2.5 "implement B" ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" verify "$A" --check 'bash check.sh' ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" verify "$B" --check 'bash check.sh' ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" record "$A" --status needs_review ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" record "$B" --status needs_review ) >/dev/null 2>&1

# Both reviewable, in distinct worktrees, before any landing.
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$A" '.status')" "needs_review" "A reviewable pre-land"
  assert_eq "$(d_sc_get "$B" '.status')" "needs_review" "B reviewable pre-land"
  wta="$(d_sc_get "$A" '.worktree')"; wtb="$(d_sc_get "$B" '.worktree')"
  assert_file "$wta" "A worktree present pre-land"
  assert_file "$wtb" "B worktree present pre-land"
  case "$wta" in "$wtb") echo "  FAIL: contestants share a worktree"; exit 1;; esac )

# Orchestrator review surface: show --diff is available and non-empty for the winner.
diffout="$( cd "$ro" && bash "$DISPATCH" show "$A" --diff 2>/dev/null )"
assert_contains "$diffout" "IMPL" "show --diff surfaces the winner's change for review"

# --- LAND EXACTLY ONE (A) ----
pre_land_head="$(base_head)"
landout="$( cd "$ro" && bash "$DISPATCH" land "$A" 2>&1 )"
assert_contains "$landout" "Landed $A" "winner A lands"
case "$(base_head)" in "$pre_land_head") echo "  FAIL: land did not advance base HEAD"; exit 1;; esac
assert_eq "ok" "ok" "land advanced the base branch HEAD"
# winner's commit (its codex-run commit message embeds the id) reached the base branch:
assert_contains "$(git -C "$ro" log --oneline -10)" "$A" "winner A's commit merged into base"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$A" '.status')" "landed" "A status=landed"
  wta="$(d_sc_get "$A" '.worktree')"
  [ -d "$wta" ] && { echo "  FAIL: winner worktree not removed after land"; exit 1; }
  assert_eq "ok" "ok" "winner worktree removed after land" )

# --- ABANDON THE REST (B) ----
abandonout="$( cd "$ro" && bash "$DISPATCH" abandon "$B" 2>&1 )"
assert_contains "$abandonout" "Abandoned $B" "loser B is abandoned"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$B" '.status')" "abandoned" "B status=abandoned"
  wtb="$(d_sc_get "$B" '.worktree')"
  [ -d "$wtb" ] && { echo "  FAIL: loser worktree not removed after abandon"; exit 1; }
  assert_eq "ok" "ok" "loser worktree removed after abandon" )
# the loser's commit never reached the base branch:
if git -C "$ro" log --oneline | grep -q "$B"; then echo "  FAIL: loser commit leaked onto base"; exit 1; fi
assert_eq "ok" "ok" "loser's commit never reached the base branch"

ps_teardown_sandbox
ps_report; exit $?

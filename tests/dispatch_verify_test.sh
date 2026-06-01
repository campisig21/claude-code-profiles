#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# FAIL then retry: first exec writes IMPL=bad (check fails); with --retry 1 the
# engine resumes codex (which writes IMPL=ok) -> check passes -> needs_review.
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        FAKE_CODEX_BEHAVIOR=fail bash "$ENGINE" dispatch --verify checks \
        --check 'bash check.sh' --retry 1 --slug retry-me "x" 2>&1 )"
id="20260531T120000Z-retry-me"
( cd "$repo"
  assert_eq "$(d_sc_get "$id" '.status')" "needs_review" "recovered after retry"
  assert_eq "$(d_sc_get "$id" '.retries_used')" "1" "one retry used"
)

# Budget 0: failing check hands back as 'failed', worktree retained.
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260531T130000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        FAKE_CODEX_BEHAVIOR=fail bash "$ENGINE" dispatch --verify checks \
        --check 'bash check.sh' --retry 0 --slug no-retry "x" 2>&1 )"
id2="20260531T130000Z-no-retry"
( cd "$repo"
  assert_eq "$(d_sc_get "$id2" '.status')" "failed" "no-retry -> failed"
  wt="$(d_sc_get "$id2" '.worktree')"; assert_file "$wt/IMPL" "worktree retained on failure"
)
assert_contains "$out" "failed" "reports failed"

# weaken-tests behavior raises the touches_tests warning even in checks-only mode
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260531T140000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        FAKE_CODEX_BEHAVIOR=weaken-tests bash "$ENGINE" dispatch --verify checks \
        --check 'bash check.sh' --slug touchy "x" 2>&1 )"
assert_contains "$out" "modifies tests" "test-touch warning surfaced"

ps_teardown_sandbox
ps_report; exit $?

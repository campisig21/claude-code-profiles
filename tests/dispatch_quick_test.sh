#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# clean tree: quick edits in place, reports diff, creates NO worktree/branch/sidecar
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" quick "small fix" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "quick succeeds on clean tree"
assert_eq "$(cat "$repo/IMPL")" "ok" "quick wrote change in place"
assert_contains "$out" "+ok" "quick reports the diff"
( cd "$repo"
  assert_eq "$(d_list_ids | wc -l | tr -d ' ')" "0" "quick made no sidecar"
  assert_eq "$(git worktree list | wc -l | tr -d ' ')" "1" "quick made no extra worktree"
)

# dirty tree without --snapshot is refused
printf 'dirty\n' >> "$repo/README.md"
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" quick "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "quick refuses dirty tree"
assert_contains "$out" "snapshot" "suggests --snapshot"

# dirty tree WITH --snapshot proceeds and reports a restore point
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" bash "$ENGINE" quick --snapshot "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "quick --snapshot proceeds on dirty tree"
assert_contains "$out" "snapshot" "reports a restore point"

# quick with a failing check reports the failure (no auto-retry, no land step)
git -C "$repo" checkout -- README.md 2>/dev/null || true; rm -f "$repo/IMPL"
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_BEHAVIOR=fail \
        bash "$ENGINE" quick --verify checks --check 'bash check.sh' "x" 2>&1 )"; rc=$?
assert_contains "$out" "FAIL" "quick surfaces failing check"

ps_teardown_sandbox
ps_report; exit $?

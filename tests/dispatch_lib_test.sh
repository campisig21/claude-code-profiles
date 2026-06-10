#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox

fake="$(ps_make_fake_codex)"
assert_file "$fake" "fake codex created"
assert_eq "$("$fake" --version)" "fake-codex 0.0.0" "fake codex --version"

repo="$(ps_make_sandbox_repo)"
assert_file "$repo/check.sh" "sandbox repo has check.sh"
assert_eq "$(git -C "$repo" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; echo $?)" "0" "sandbox repo is a git repo"

# fake exec writes IMPL=ok into -C dir; check passes
"$fake" exec -C "$repo" -o "$PS_SANDBOX/last.txt" --json >/dev/null
assert_eq "$(cat "$repo/IMPL")" "ok" "fake exec wrote IMPL=ok"
assert_eq "$(cd "$repo" && bash check.sh; echo $?)" "0" "check passes on ok"

# fail behavior makes the check fail
FAKE_CODEX_BEHAVIOR=fail "$fake" exec -C "$repo" >/dev/null
assert_eq "$(cd "$repo" && bash check.sh; echo $?)" "1" "check fails on bad"

# --- lib/dispatch.sh helpers ---
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch.sh"

# identity helpers
assert_eq "$(d_slugify 'Fix the Auth Bug!!')" "fix-the-auth-bug" "slugify"
assert_eq "$(CODEX_DISPATCH_NOW=20260531T120000Z d_now)" "20260531T120000Z" "d_now honors override"
assert_eq "$(d_short abc | wc -c | tr -d ' ')" "7" "d_short is 6 chars + newline"

# git context (run inside the sandbox repo)
( cd "$repo"
  assert_eq "$(d_in_git_repo; echo $?)" "0" "in git repo"
  assert_eq "$(d_repo_root)" "$repo" "repo root"
  assert_eq "$(d_worktree_root)" "$repo/.codex-dispatch-worktrees" "worktree root project-local"
  assert_contains "$(d_sidecar_dir)" "/codex-dispatch" "sidecar dir under git dir"
)

# sidecar I/O
( cd "$repo"
  mkdir -p "$(d_sidecar_dir)"
  echo '{"id":"x1","status":"running","retry_budget":2}' > "$(d_sidecar_path x1)"
  assert_eq "$(d_sc_get x1 '.status')" "running" "sc_get status"
  assert_eq "$(d_sc_get x1 '.retry_budget')" "2" "sc_get number"
  d_sc_set x1 '.status=$s|.updated_at=$u' --arg s needs_review --arg u 20260531T130000Z
  assert_eq "$(d_sc_get x1 '.status')" "needs_review" "sc_set status"
  assert_eq "$(d_sc_get x1 '.updated_at')" "20260531T130000Z" "sc_set updated_at"
  assert_eq "$(d_sidecar_exists x1; echo $?)" "0" "sidecar exists"
  assert_eq "$(d_sidecar_exists nope; echo $?)" "1" "missing sidecar"
  assert_eq "$(d_list_ids)" "x1" "list ids"
)

# --- codex wrapper + checks + diff helpers ---
( cd "$repo"
  # session id parsing from a captured stream
  echo '{"type":"session.created","session_id":"fake-sess-0001"}' > "$PS_SANDBOX/stream.json"
  assert_eq "$(d_codex_session_id "$PS_SANDBOX/stream.json")" "fake-sess-0001" "session id parsed"
  assert_eq "$(d_codex_session_id /no/file)" "" "missing stream -> empty"
  # codex 0.135+ renamed the key to thread_id (smoke finding 1)
  echo '{"type":"thread.started","thread_id":"019e-fake-thread"}' > "$PS_SANDBOX/stream.json"
  assert_eq "$(d_codex_session_id "$PS_SANDBOX/stream.json")" "019e-fake-thread" "thread id parsed"

  # run a passing + failing check, capture JSON
  printf 'ok\n' > IMPL
  d_run_checks "$repo" "bash check.sh"; rc=$?
  assert_eq "$rc" "0" "checks pass when IMPL=ok"
  assert_eq "$(printf '%s' "$D_CHECKS_JSON" | jq -r '.[0].exit')" "0" "check exit recorded"
  printf 'bad\n' > IMPL
  d_run_checks "$repo" "bash check.sh"; rc=$?
  assert_eq "$rc" "1" "checks fail when IMPL=bad"

  # test-touch detection
  printf 'src/app.js\nREADME.md\n' | d_touches_tests; assert_eq "$?" "1" "no test files -> 1"
  printf 'src/app.js\ntests/run.sh\n' | d_touches_tests; assert_eq "$?" "0" "tests/ path -> 0"
  printf 'foo_test.go\n' | d_touches_tests; assert_eq "$?" "0" "_test. suffix -> 0"
)

ps_teardown_sandbox
ps_report; exit $?

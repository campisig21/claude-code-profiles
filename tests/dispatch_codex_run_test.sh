#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"
log="$PS_SANDBOX/argv.log"; : > "$log"

# begin, then codex-run the headline (codex, gpt-5.5): -m threads as its own axis,
# the codex bundle for `codex` backend is empty, so argv carries exactly `-m gpt-5.5`.
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T130000Z bash "$DISPATCH" begin add-x --label gpt-5.5 )"
out="$( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
        bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.5 "implement X in the worktree" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "codex-run exits 0"
assert_contains "$(cat "$log")" "-m gpt-5.5" "argv threads -m <model> (the model axis)"
assert_contains "$(cat "$log")" "exec" "still goes through codex exec (single call site)"
# the full diff is NOT auto-dumped (E1 token economy preserved)
case "$out" in *"+ok"*) echo "  FAIL: codex-run leaked the full diff"; exit 1;; esac

( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  wt="$(d_sc_get "$id" '.worktree')"
  assert_eq "$(cat "$wt/IMPL")" "ok" "codex's change landed in the library worktree"
  assert_eq "$(d_sc_get "$id" '.backend')" "codex" "sidecar backend set by codex-run"
  assert_eq "$(d_sc_get "$id" '.model')"   "gpt-5.5" "sidecar model set by codex-run"
  assert_eq "$(d_sc_get "$id" '.session_id')" "fake-sess-0001" "session captured from the --json stream"
  assert_eq "$(d_sc_get "$id" '.prompt')" "implement X in the worktree" "composed prompt recorded (for the curator feed)"
  # codex-run committed the work onto the dispatch branch
  assert_eq "$(d_has_changes "$wt" "$(d_sc_get "$id" '.base_ref')" && echo yes || echo no)" "yes" "worktree diverges from base (work committed)"
  # the verbatim stream is in codexlog; a projection is in the console event log
  assert_file "$(d_sidecar_dir)/$id.codexlog.jsonl" "verbatim codex stream retained"
  ev="$(cat "$(d_events_path "$id")")"
  assert_contains "$ev" '"phase":"codex-run"' "codex-run wrote console events"
  assert_contains "$ev" "session.created" "codex --json progress projected into the event log" )

# ollama backend: -m overrides the bundle's baked-in default (last-wins), transport intact
: > "$log"
id2="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T131000Z bash "$DISPATCH" begin add-y --label qwen2.5 )"
( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
    bash "$DISPATCH" codex-run "$id2" --backend ollama -m qwen2.5 "do y" >/dev/null 2>&1 )
assert_contains "$(cat "$log")" "--oss --local-provider ollama" "ollama transport bundle threaded unchanged"
assert_contains "$(cat "$log")" "-m qwen2.5" "the cell's -m model is present (last-wins over the arm default)"

ps_teardown_sandbox
ps_report; exit $?

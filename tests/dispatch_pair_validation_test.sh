#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T140000Z bash "$DISPATCH" begin pv --label opus )"

# E10: a Claude model must be refused loudly (Claude cells implement directly).
for m in claude opus sonnet haiku fable claude-3-5; do
  out="$( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" \
          bash "$DISPATCH" codex-run "$id" --backend codex -m "$m" "do it" 2>&1 )"; rc=$?
  assert_eq "$rc" "1" "codex-run refuses Claude model '$m'"
  assert_contains "$out" "implement it directly" "refusal names the correct next move for '$m'"
done

# E10: a non-Claude model with NO codex binary available errors cleanly.
out="$( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="/nonexistent/codex-bin" \
        bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.5 "do it" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "codex-run refuses when no codex binary is available"
assert_contains "$out" "no codex binary" "refusal explains the missing binary"

# missing -m is refused (a worker model is mandatory on the codex path)
out="$( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" \
        bash "$DISPATCH" codex-run "$id" --backend codex "do it" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "codex-run requires -m <model>"
assert_contains "$out" "requires -m" "explains the -m requirement"

ps_teardown_sandbox
ps_report; exit $?

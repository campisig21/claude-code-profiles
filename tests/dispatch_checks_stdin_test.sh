#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox

source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch.sh"

repo="$(ps_make_sandbox_repo)"
check_cmd='cat >/dev/null; echo ran'
fifo="$PS_SANDBOX/checks.stdin.fifo"

mkfifo "$fifo"
exec 9<>"$fifo"

(
  d_run_checks "$repo" "$check_cmd"; rc=$?
  assert_eq "$rc" "0" "stdin-reading check returns successfully"
  assert_eq "$(printf '%s' "$D_CHECKS_JSON" | jq -r '.[0].cmd')" "$check_cmd" "check command recorded"
  assert_eq "$(printf '%s' "$D_CHECKS_JSON" | jq -r '.[0].exit')" "0" "check exit recorded"
  assert_contains "$(printf '%s' "$D_CHECKS_JSON" | jq -r '.[0].output_tail')" "ran" "check output tail captured"
) <&9

exec 9>&-
exec 9<&-
rm -f "$fifo"

ps_teardown_sandbox
ps_report; exit $?

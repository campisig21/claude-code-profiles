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

ps_teardown_sandbox
ps_report; exit $?

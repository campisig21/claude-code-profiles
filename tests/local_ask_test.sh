#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ASK="$PS_REPO_ROOT/bin/local-ask"
fake="$(ps_make_fake_codex)"

# usage error with no args
out="$( bash "$ASK" 2>&1 )"; rc=$?
assert_eq "$rc" "2" "no args -> usage exit 2"
assert_contains "$out" "usage" "prints usage"

# ready: threads -p local-headless, --skip-git-repo-check, bypass, preamble, and the prompt
log="$PS_SANDBOX/ask.log"; : > "$log"
out="$( CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$log" \
        bash "$ASK" "what is 2+2?" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "ready -> succeeds"
argv="$(cat "$log")"
assert_contains "$argv" "exec"                  "calls codex exec"
assert_contains "$argv" "-p local-headless"     "uses the headless profile"
assert_contains "$argv" "--skip-git-repo-check" "skips the git-repo check (no repo needed)"
assert_contains "$argv" "--dangerously-bypass-approvals-and-sandbox" "runs autonomously"
assert_contains "$argv" "one-shot"              "injects the headless preamble"
assert_contains "$argv" "what is 2+2?"          "passes the question"

# profile override honored
log2="$PS_SANDBOX/ask2.log"; : > "$log2"
( CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$log2" \
  LOCAL_ASK_PROFILE=ws bash "$ASK" "x" >/dev/null 2>&1 )
assert_contains "$(cat "$log2")" "-p ws" "LOCAL_ASK_PROFILE override honored"

# symlink invocation resolves back to the repo before sourcing lib/local.sh
ln -s "$PS_REPO_ROOT/bin/local-ask" "$PS_SANDBOX/linked-local-ask"
slog="$PS_SANDBOX/symlink.log"; : > "$slog"
out="$( CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$slog" \
        bash "$PS_SANDBOX/linked-local-ask" "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "symlink-invoked local-ask succeeds"
case "$out" in
  *"No such file or directory"*) echo "  FAIL: symlink resolution broken"; exit 1 ;;
esac
assert_contains "$(cat "$slog")" "-p local-headless" "symlink invocation still threads the profile"

ps_teardown_sandbox
ps_report; exit $?

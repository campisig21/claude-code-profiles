#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# --- resolver ---------------------------------------------------------------
assert_eq "$(d_backend_args codex)" ""        "codex backend -> no extra flags"
assert_eq "$(d_backend_args)"      ""         "empty/default backend -> no extra flags"
assert_eq "$(d_backend_args local)" "-p local" "local backend -> -p <profile>"
( CODEX_DISPATCH_LOCAL_PROFILE=ws; assert_eq "$(d_backend_args local)" "-p ws" "profile override honored" )
d_backend_args bogus >/dev/null 2>&1; assert_eq "$?" "1" "unknown backend returns nonzero"

ps_teardown_sandbox
ps_report; exit $?

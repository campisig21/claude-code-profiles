#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
assert_eq "hello" "hello" "harness sanity"
assert_file "$CC_PROFILE_ROOT/settings.json" "sandbox seeded settings"
ps_teardown_sandbox
ps_report; exit $?

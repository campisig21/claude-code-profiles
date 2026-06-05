#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MD="$PS_REPO_ROOT/commands/profile.md"

assert_file "$MD" "command markdown exists"
body="$(cat "$MD")"
assert_contains "$body" "profile_mgmt.sh \$ARGUMENTS" "still runs the mgmt script at expansion"
assert_contains "$body" "PROFILE_INTERVIEW_READY" "handles the create interview cue"
assert_contains "$body" "profile_mgmt.sh provision" "create flow calls provision after approval"
assert_contains "$body" "_profile/memory" "seeds profile-global memory pointers"
assert_contains "$body" "do not re-run" "forbids redundant re-invocation"

ps_report

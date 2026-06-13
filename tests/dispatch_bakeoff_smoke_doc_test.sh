#!/usr/bin/env bash
# Guard: the Phase-2 manual smoke checklist exists and covers the items no fake can
# prove (the spec §7 "Workflow caveat" boundary). Keeps the checklist from bit-rotting.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
DOC="$PS_REPO_ROOT/docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md"

assert_file "$DOC" "bake-off smoke checklist exists"
body="$(cat "$DOC" 2>/dev/null || true)"
assert_contains "$body" "/workflows" "covers /workflows live surfacing"
assert_contains "$body" "worktree" "covers concurrent git worktree add safety"
assert_contains "$body" "concurrent" "explicitly calls out concurrency"
assert_contains "$body" "dispatch land" "covers landing exactly one"
assert_contains "$body" "dispatch abandon" "covers abandoning the rest"
assert_contains "$body" "dispatch attach" "covers live attach"
assert_contains "$body" "claude" "covers the direct-Claude contestant"
assert_contains "$body" "test_integrity_flags" "covers judge test-integrity flagging"

ps_report

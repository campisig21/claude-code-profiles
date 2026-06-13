#!/usr/bin/env bash
# Static lint of the /dispatch-bakeoff command markdown (style mirrors
# dispatch_command_md_test.sh). It must declare the Workflow tool (the opt-in),
# reference the workflow scriptPath, expand $ARGUMENTS, and encode land-one/abandon-rest.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MD="$PS_REPO_ROOT/commands/dispatch-bakeoff.md"

assert_file "$MD" "/dispatch-bakeoff command markdown exists"
body="$(cat "$MD" 2>/dev/null || true)"
assert_contains "$body" "argument-hint:" "frontmatter has an argument-hint"
assert_contains "$body" "allowed-tools:" "frontmatter declares allowed-tools"
assert_contains "$body" "Workflow" "declares/uses the Workflow tool (the opt-in)"
assert_contains "$body" "dispatch-bakeoff.js" "references the workflow script"
assert_contains "$body" "scriptPath" "invokes the workflow via scriptPath"
assert_contains "$body" "\$ARGUMENTS" "expands the user task"
assert_contains "$body" "dispatch land" "orchestrator lands the winner"
assert_contains "$body" "dispatch abandon" "orchestrator abandons the rest"
assert_contains "$body" "Only the orchestrator lands" "encodes the E9 invariant"
assert_contains "$body" "/dispatch" "notes the relationship to single-worker /dispatch"

ps_report

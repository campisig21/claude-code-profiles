#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MD="$PS_REPO_ROOT/commands/dispatch.md"

assert_file "$MD" "/dispatch command markdown exists"
body="$(cat "$MD")"
assert_contains "$body" "argument-hint:" "frontmatter has an argument-hint"
assert_contains "$body" "allowed-tools:" "frontmatter declares allowed-tools"
assert_contains "$body" "dispatch skill" "delegates to the dispatch skill"
assert_contains "$body" "\$ARGUMENTS" "expands the user task"
assert_contains "$body" "codex-implement" "notes the /codex-implement alias relationship"

ps_report

#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MD="$PS_REPO_ROOT/skills/dispatch/SKILL.md"

assert_file "$MD" "dispatch SKILL.md exists"
body="$(cat "$MD")"
# YAML frontmatter
assert_contains "$body" "name: dispatch" "frontmatter names the skill"
assert_contains "$body" "description:" "frontmatter has a description"
# the rigid contract (compose -> delegate -> verify -> report), threading <id>
assert_contains "$body" "begin" "documents begin"
assert_contains "$body" "codex-run" "documents codex-run delegation"
assert_contains "$body" "verify" "documents verify"
assert_contains "$body" "record" "documents record"
assert_contains "$body" "thread" "tells the cell to thread the begin-returned <id>"
# E10 + the never-land rule
assert_contains "$body" "Claude model" "states Claude models are implemented directly (E10)"
assert_contains "$body" "never" "states the cell never lands"

ps_report

#!/usr/bin/env bash
# Hermetic smoke for bin/claude-run (ADR-0004). claude + curl faked via the
# CLAUDE_BIN / CURL_BIN seams; no live station needed. Assertions accrete per
# task: Task 1 — the env contract (incl. the always-omitted SMALL_FAST_MODEL),
# the localhost default, and the derived/overridden station endpoint.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox

CLI="$PS_REPO_ROOT/bin/claude-run"
fake="$(ps_make_fake_claude_p)"
export CLAUDE_BIN="$fake"

# Isolate from the operator's shell: every default-case assertion below assumes
# these are unset (Tasks 2-4 append more such cases). Override cases set them inline.
unset CLAUDE_DISPATCH_URL CLAUDE_DISPATCH_MODEL CLAUDE_DISPATCH_SMALL_FAST_MODEL CODEX_DISPATCH_LOCAL_ENDPOINT

# --- env contract: localhost default (NO personal IP in distributable code),
#     SMALL_FAST defaults to MODEL, API_KEY unset. -----------------------------
out="$("$CLI" --dir "$PS_SANDBOX" "do a thing")"
assert_contains "$out" "ANTHROPIC_BASE_URL=http://localhost:8080"   "default base url (localhost)"
assert_contains "$out" "ANTHROPIC_MODEL=qwen3-coder-30b"            "default model (ADR-0003)"
assert_contains "$out" "ANTHROPIC_SMALL_FAST_MODEL=qwen3-coder-30b" "SMALL_FAST defaults to MODEL"
assert_contains "$out" "ANTHROPIC_AUTH_TOKEN=dummy"                 "auth token dummy"
assert_contains "$out" "ANTHROPIC_API_KEY=<unset>"                  "API key unset (env -u)"
assert_contains "$out" "do a thing"                                 "prompt forwarded to claude -p"

# --- station endpoint derived from CODEX_DISPATCH_LOCAL_ENDPOINT (minus /v1) ---
out="$(CODEX_DISPATCH_LOCAL_ENDPOINT=http://station.example:9100/v1 "$CLI" --dir "$PS_SANDBOX" "x")"
assert_contains "$out" "ANTHROPIC_BASE_URL=http://station.example:9100" "derive base from codex endpoint, strip /v1"

# --- CLAUDE_DISPATCH_URL overrides the derived endpoint ----------------------
out="$(CODEX_DISPATCH_LOCAL_ENDPOINT=http://station.example:9100/v1 CLAUDE_DISPATCH_URL=http://override.example:7000 \
       "$CLI" --dir "$PS_SANDBOX" "x")"
assert_contains "$out" "ANTHROPIC_BASE_URL=http://override.example:7000" "CLAUDE_DISPATCH_URL wins"

# --- --model override + SMALL_FAST follows it --------------------------------
out="$("$CLI" --dir "$PS_SANDBOX" --model glm-z1-32b "x")"
assert_contains "$out" "ANTHROPIC_MODEL=glm-z1-32b"            "--model overrides"
assert_contains "$out" "ANTHROPIC_SMALL_FAST_MODEL=glm-z1-32b" "SMALL_FAST follows --model"

# --- explicit SMALL_FAST override wins ---------------------------------------
out="$(CLAUDE_DISPATCH_SMALL_FAST_MODEL=qwen3-0.6b "$CLI" --dir "$PS_SANDBOX" "x")"
assert_contains "$out" "ANTHROPIC_SMALL_FAST_MODEL=qwen3-0.6b" "explicit SMALL_FAST honored"

# --- --stream adds stream-json; -- passes claude flags verbatim --------------
out="$("$CLI" --dir "$PS_SANDBOX" --stream "x" -- --allowedTools Read)"
assert_contains "$out" "--output-format stream-json" "--stream adds stream-json"
assert_contains "$out" "--allowedTools Read"          "-- passthrough verbatim"

# --- unknown pre-'--' flag is rejected (no silent prompt-eating) -------------
"$CLI" --dir "$PS_SANDBOX" --bogus "x" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "unknown option exits 2"

ps_teardown_sandbox
ps_report; exit $?

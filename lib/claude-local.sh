#!/usr/bin/env bash
# lib/claude-local.sh — the claude-on-station dispatch transport (ADR-0004).
# Single source of truth for the `claude -p` -> station env contract. Sourced by
# bin/claude-run. Lives OUTSIDE the frozen lib/dispatch.sh seam.
# Test seams: ${CLAUDE_BIN:-claude}, ${CURL_BIN:-curl}, ${JQ_BIN:-jq}.

# Resolve config -> CL_URL / CL_MODEL / CL_SMALL.
# CL_URL carries NO personal IP in distributable code (tests/no_personal_values_test.sh).
# Default localhost; derive the real station endpoint from the one place it is
# already configured -- CODEX_DISPATCH_LOCAL_ENDPOINT (same single llama-server
# serves both APIs, ADR-0002), stripping its /v1 suffix since the Anthropic
# client appends /v1/messages itself. CLAUDE_DISPATCH_URL overrides both.
claude_local_resolve() {
  local ep="${CLAUDE_DISPATCH_URL:-${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://localhost:8080/v1}}"
  CL_URL="${ep%/v1}"
  CL_MODEL="${CLAUDE_DISPATCH_MODEL:-qwen3-coder-30b}"   # ADR-0003
  CL_SMALL="${CLAUDE_DISPATCH_SMALL_FAST_MODEL:-$CL_MODEL}"
}

# Build the resolved `env -u … ANTHROPIC_*` argv into the CL_ENV array (shared by
# _exec and _run so the contract lives in exactly one place). Calls _resolve.
claude_local_env_argv() {
  claude_local_resolve
  CL_ENV=(env -u ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL="$CL_URL"
    ANTHROPIC_AUTH_TOKEN=dummy
    ANTHROPIC_MODEL="$CL_MODEL"
    ANTHROPIC_SMALL_FAST_MODEL="$CL_SMALL")
}

# cd <dir>; exec claude -p with the resolved env. Replaces the shell (one-shot path).
# Line-buffers stdout (stdbuf -oL) when CLAUDE_LOCAL_LINEBUF is set; $linebuf is
# intentionally unquoted so an empty value expands to nothing (safe under set -u).
claude_local_exec() {
  local dir="$1"; shift
  claude_local_env_argv
  cd "$dir" || { echo "claude-run: cannot cd to $dir" >&2; return 1; }
  local linebuf=""
  [ -n "${CLAUDE_LOCAL_LINEBUF:-}" ] && command -v stdbuf >/dev/null 2>&1 && linebuf="stdbuf -oL"
  exec "${CL_ENV[@]}" $linebuf "${CLAUDE_BIN:-claude}" -p "$@"
}

# Run claude -p as a SUBPROCESS (NOT exec — control returns for the commit/sidecar
# steps the cell does next). Forces stream-json; the worker's stdout (the NDJSON) is
# redirected to <streamfile>, NOT the caller's stdout (reserved for the digest). The
# cd is localized to a subshell so the caller's cwd is untouched. Returns the worker's
# EXACT exit code (the cell records it). On a nonzero exit with no output captured
# (a failed cd, or a worker that crashed before emitting), warn to stderr — otherwise
# the empty stream looks like a run that did nothing rather than one that never started.
claude_local_run() {
  local dir="$1" stream="$2"; shift 2
  claude_local_env_argv
  local rc=0
  ( cd "$dir" && "${CL_ENV[@]}" "${CLAUDE_BIN:-claude}" -p --output-format stream-json --verbose "$@" ) > "$stream" || rc=$?
  [ "$rc" -ne 0 ] && [ ! -s "$stream" ] \
    && echo "claude-local: no stream captured from worker in '$dir' (cd failed, or it exited before emitting)" >&2
  return "$rc"
}

# Read Claude Code stream-json NDJSON on stdin; emit one concise line per step.
# Schema is confirmed/adjusted by the live spike (Task 5) against real output.
# `arrays` guards a string-valued .message.content: iterating a string would make
# jq abort and silently drop every later line (2>/dev/null hides the error).
claude_local_digest() {
  "${JQ_BIN:-jq}" -rc '
    if .type == "assistant" then
      (.message.content // [] | arrays | .[])
      | if .type == "tool_use" then "tool: \(.name) \(.input | tojson)"
        elif .type == "text" and ((.text // "") | length > 0) then "text: \(.text[0:80])"
        else empty end
    elif .type == "result" then
      "result: \(.subtype // "?")\(if .is_error then " ERROR" else "" end)"
    else empty end
  ' 2>/dev/null
}

# Probe both endpoints; READY only on 200/200. Nonzero exit when not ready.
claude_local_probe() {
  claude_local_resolve
  local oai anth
  oai="$("${CURL_BIN:-curl}" -s -o /dev/null -w '%{http_code}' -m 5 \
    -X POST "$CL_URL/v1/chat/completions" -H 'content-type: application/json' \
    -d '{"model":"'"$CL_MODEL"'","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' 2>/dev/null)"
  anth="$("${CURL_BIN:-curl}" -s -o /dev/null -w '%{http_code}' -m 5 \
    -X POST "$CL_URL/v1/messages" -H 'content-type: application/json' \
    -d '{"model":"'"$CL_MODEL"'","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null)"
  echo "OpenAI /v1/chat/completions=$oai  Anthropic /v1/messages=$anth"
  if [ "$oai" = "200" ] && [ "$anth" = "200" ]; then echo READY; return 0; fi
  echo "NOT READY"; return 1
}

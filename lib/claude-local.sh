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

# cd <dir>; exec claude -p with the resolved Anthropic env. Replaces the shell.
# Line-buffers stdout (stdbuf -oL) when CLAUDE_LOCAL_LINEBUF is set; the streaming
# spike (Task 5) flips that on only if the stream is found to block-buffer.
# $linebuf is intentionally unquoted so an empty value expands to nothing
# (safe under `set -u` on bash 3.2, unlike an empty "${arr[@]}").
claude_local_exec() {
  local dir="$1"; shift
  claude_local_resolve
  cd "$dir" || { echo "claude-run: cannot cd to $dir" >&2; return 1; }
  local linebuf=""
  [ -n "${CLAUDE_LOCAL_LINEBUF:-}" ] && command -v stdbuf >/dev/null 2>&1 && linebuf="stdbuf -oL"
  exec env -u ANTHROPIC_API_KEY \
    ANTHROPIC_BASE_URL="$CL_URL" \
    ANTHROPIC_AUTH_TOKEN=dummy \
    ANTHROPIC_MODEL="$CL_MODEL" \
    ANTHROPIC_SMALL_FAST_MODEL="$CL_SMALL" \
    $linebuf "${CLAUDE_BIN:-claude}" -p "$@"
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

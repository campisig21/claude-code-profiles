#!/usr/bin/env bash
# lib/local.sh — remote model lifecycle for the local dispatch backend (C.1).
# SOURCE this. The workstation runs llama.cpp in ROUTER MODE: /v1/models lists the
# whole fleet with per-model status.value; models auto-load on request and LRU-evict.
# All network/ssh calls go through injectable bins so tests stub them. Defaults target
# the headscale workstation; override via CODEX_DISPATCH_LOCAL_* env.

l_endpoint() { printf '%s' "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://100.64.0.4:8080/v1}"; }
l_model()    { printf '%s' "${CODEX_DISPATCH_LOCAL_MODEL:-qwen36-35b}"; }
l_ssh_tgt()  { printf '%s' "${CODEX_DISPATCH_LOCAL_SSH:-greg-campisi@100.64.0.4}"; }

# l_probe -> echoes exactly one of: unreachable | up-not-loaded | ready
#   CODEX_DISPATCH_FAKE_STATE short-circuits to a literal (test seam).
#   ready iff the target alias is present AND its status.value == "loaded".
l_probe() {
  if [ -n "${CODEX_DISPATCH_FAKE_STATE:-}" ]; then
    printf '%s\n' "$CODEX_DISPATCH_FAKE_STATE"; return 0
  fi
  local curl_bin body
  curl_bin="${CODEX_DISPATCH_CURL_BIN:-curl}"
  body="$("$curl_bin" -sS -m "${CODEX_DISPATCH_LOCAL_HTTP_TIMEOUT:-4}" "$(l_endpoint)/models" 2>/dev/null)" \
    || { printf 'unreachable\n'; return 0; }
  if printf '%s' "$body" | jq -e --arg m "$(l_model)" \
       '.data[]? | select(.id == $m) | .status.value == "loaded"' >/dev/null 2>&1; then
    printf 'ready\n'
  else
    printf 'up-not-loaded\n'
  fi
}

# l_ready -> 0 iff the configured model alias is loaded and serving.
l_ready() { [ "$(l_probe)" = ready ]; }

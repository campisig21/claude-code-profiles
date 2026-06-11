#!/usr/bin/env bash
# lib/local.sh — remote model lifecycle for the local dispatch backend (C.1).
# SOURCE this. The workstation runs llama.cpp in ROUTER MODE: /v1/models lists the
# whole fleet with per-model status.value; models auto-load on request and LRU-evict.
# All network/ssh calls go through injectable bins so tests stub them. Defaults are
# generic; override via CODEX_DISPATCH_LOCAL_* env.

l_endpoint() { printf '%s' "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://localhost:8080/v1}"; }
l_model()    { printf '%s' "${CODEX_DISPATCH_LOCAL_MODEL:-local-model}"; }
l_ssh_tgt()  { printf '%s' "${CODEX_DISPATCH_LOCAL_SSH:-}"; }

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

# Remote lifecycle commands (run over ssh). Empty defaults keep remote control opt-in.
l_up_cmd()   { printf '%s' "${CODEX_DISPATCH_LOCAL_UP_CMD:-}"; }
l_down_cmd() { printf '%s' "${CODEX_DISPATCH_LOCAL_DOWN_CMD:-}"; }

# l_preload -> best-effort 1-token request that triggers the router's on-demand load.
# Short-circuits under FAKE_STATE (tests stay network-free).
l_preload() {
  [ -n "${CODEX_DISPATCH_FAKE_STATE:-}" ] && return 0
  local curl_bin
  curl_bin="${CODEX_DISPATCH_CURL_BIN:-curl}"
  "$curl_bin" -sS -m "${CODEX_DISPATCH_LOCAL_HTTP_TIMEOUT:-10}" \
    "$(l_endpoint)/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$(l_model)\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}],\"max_tokens\":1}" \
    >/dev/null 2>&1 || true
}

# l_up -> run the remote up command (preset switch + start), then poll until the
# alias is loaded. Tolerates the brief restart-window unreachability; nudges one
# HTTP preload if the server is up but the model isn't loaded.
l_up() {
  local ssh_bin interval timeout waited nudged state=unknown
  ssh_bin="${CODEX_DISPATCH_SSH_BIN:-ssh}"
  if [ -n "$(l_ssh_tgt)" ] && [ -n "$(l_up_cmd)" ]; then
    echo "local-up: ensuring '$(l_model)' on $(l_ssh_tgt) (preset switch + load) ..."
    "$ssh_bin" "$(l_ssh_tgt)" "$(l_up_cmd)" || { echo "local-up: remote up command failed" >&2; return 1; }
  else
    echo "local-up: ensuring '$(l_model)' at $(l_endpoint) (no remote start configured) ..."
  fi
  interval="${CODEX_DISPATCH_LOCAL_POLL_INTERVAL:-3}"
  timeout="${CODEX_DISPATCH_LOCAL_POLL_TIMEOUT:-240}"
  waited=0; nudged=0
  while [ "$waited" -lt "$timeout" ]; do
    state="$(l_probe)"
    if [ "$state" = ready ]; then echo "local-up: model ready."; return 0; fi
    if [ "$state" = up-not-loaded ] && [ "$nudged" -eq 0 ]; then l_preload; nudged=1; fi
    sleep "$interval"; waited=$((waited + interval))
  done
  echo "local-up: timed out after ${timeout}s waiting for readiness (last state: $state)" >&2
  return 1
}

# l_down -> stop the model server to free VRAM. Default stops the container.
l_down() {
  local ssh_bin
  ssh_bin="${CODEX_DISPATCH_SSH_BIN:-ssh}"
  if [ -z "$(l_ssh_tgt)" ] || [ -z "$(l_down_cmd)" ]; then
    echo "local-down: no remote stop configured (set CODEX_DISPATCH_LOCAL_SSH + CODEX_DISPATCH_LOCAL_DOWN_CMD); nothing to stop."
    return 0
  fi
  echo "local-down: stopping the model server on $(l_ssh_tgt) ..."
  if "$ssh_bin" "$(l_ssh_tgt)" "$(l_down_cmd)"; then
    echo "local-down: stop command sent (VRAM freed)."
  else
    echo "local-down: remote stop failed" >&2; return 1
  fi
}

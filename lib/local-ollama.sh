#!/usr/bin/env bash
# lib/local-ollama.sh — local Ollama backend for the shared local dispatch
# lifecycle interface. SOURCE this. Ollama exposes a native API: /api/ps reports
# loaded models, /api/chat triggers on-demand loads and returns assistant text.
# All network calls route through an injectable curl binary so tests can stub
# them without touching the real host.

l_endpoint() { printf '%s' "${OLLAMA_HOST:-http://localhost:11434}"; }
l_model()    { printf '%s' "${CODEX_DISPATCH_LOCAL_MODEL:-qwen2.5-coder}"; }

# l_probe -> echoes exactly one of: unreachable | up-not-loaded | ready
#   CODEX_DISPATCH_FAKE_STATE short-circuits to a literal (test seam).
#   ready iff /api/ps is reachable and .models[].name contains the configured model.
l_probe() {
  if [ -n "${CODEX_DISPATCH_FAKE_STATE:-}" ]; then
    printf '%s\n' "$CODEX_DISPATCH_FAKE_STATE"; return 0
  fi
  local curl_bin body
  curl_bin="${CODEX_DISPATCH_CURL_BIN:-curl}"
  body="$("$curl_bin" -sS -m "${CODEX_DISPATCH_LOCAL_HTTP_TIMEOUT:-4}" "$(l_endpoint)/api/ps" 2>/dev/null)" \
    || { printf 'unreachable\n'; return 0; }
  if printf '%s' "$body" | jq -e --arg m "$(l_model)" \
       '.models[]? | select(.name == $m)' >/dev/null 2>&1; then
    printf 'ready\n'
  else
    printf 'up-not-loaded\n'
  fi
}

# l_ready -> 0 iff the configured Ollama model is loaded and serving.
l_ready() { [ "$(l_probe)" = ready ]; }

# l_preload -> best-effort chat request that triggers Ollama's on-demand load.
# Short-circuits under FAKE_STATE (tests stay network-free).
l_preload() {
  [ -n "${CODEX_DISPATCH_FAKE_STATE:-}" ] && return 0
  local curl_bin
  curl_bin="${CODEX_DISPATCH_CURL_BIN:-curl}"
  "$curl_bin" -sS -m "${CODEX_DISPATCH_LOCAL_HTTP_TIMEOUT:-4}" \
    "$(l_endpoint)/api/chat" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$(l_model)\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}],\"stream\":false}" \
    >/dev/null 2>&1 || true
}

# l_up -> poll until the model is loaded. Ollama auto-loads on request, so we
# only nudge it once with a preload request when the daemon is up but the model
# is not yet loaded.
l_up() {
  local interval timeout waited nudged state
  if [ -n "${CODEX_DISPATCH_FAKE_STATE:-}" ]; then
    state="$(l_probe)"
    echo "local-up: ensuring '$(l_model)' on $(l_endpoint) ..."
    if [ "$state" = ready ]; then echo "local-up: model ready."; return 0; fi
    echo "local-up: fake state is $state; not ready." >&2
    return 1
  fi
  echo "local-up: ensuring '$(l_model)' on $(l_endpoint) ..."
  interval="${CODEX_DISPATCH_LOCAL_POLL_INTERVAL:-3}"
  timeout="${CODEX_DISPATCH_LOCAL_POLL_TIMEOUT:-240}"
  waited=0
  nudged=0
  state=unknown
  while [ "$waited" -lt "$timeout" ]; do
    state="$(l_probe)"
    if [ "$state" = ready ]; then echo "local-up: model ready."; return 0; fi
    if [ "$state" = up-not-loaded ] && [ "$nudged" -eq 0 ]; then l_preload; nudged=1; fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  echo "local-up: timed out after ${timeout}s waiting for readiness (last state: $state)" >&2
  return 1
}

# l_down -> ask Ollama to unload the configured model. Missing CLI binaries are
# tolerated so local-down remains informative instead of crashing.
l_down() {
  local ollama_bin
  ollama_bin="${CODEX_DISPATCH_OLLAMA_BIN:-ollama}"
  echo "local-down: unloading '$(l_model)' via $ollama_bin stop ..."
  if ! command -v "$ollama_bin" >/dev/null 2>&1; then
    echo "local-down: $ollama_bin not found; skipping unload."
    return 0
  fi
  if "$ollama_bin" stop "$(l_model)"; then
    echo "local-down: unload command sent."
  else
    echo "local-down: failed to unload $(l_model)." >&2
    return 1
  fi
}

ollama_chat() {
  local model prompt curl_bin schema schema_flag body
  model="${1:?usage: ollama_chat <model> <prompt> [--format <schema-json>]}"
  prompt="${2:?usage: ollama_chat <model> <prompt> [--format <schema-json>]}"
  shift 2
  schema_flag=0
  schema=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --format)
        [ $# -ge 2 ] || { echo "ollama_chat: --format requires schema JSON" >&2; return 2; }
        schema="$2"
        schema_flag=1
        shift 2
        ;;
      *)
        echo "ollama_chat: unknown arg: $1" >&2
        return 2
        ;;
    esac
  done

  curl_bin="${CODEX_DISPATCH_CURL_BIN:-curl}"
  body="$(jq -cn --arg model "$model" --arg prompt "$prompt" --argjson stream false \
    --argjson format "${schema:-null}" '
      {
        model: $model,
        messages: [{role: "user", content: $prompt}],
        stream: $stream
      }
      + (if $format == null then {} else {format: $format} end)
    ' 2>/dev/null)"
  if [ "$schema_flag" -eq 0 ]; then
    body="$(jq -cn --arg model "$model" --arg prompt "$prompt" \
      '{model: $model, messages: [{role: "user", content: $prompt}], stream: false}')"
  fi
  "$curl_bin" -sS -m "${CODEX_DISPATCH_LOCAL_HTTP_TIMEOUT:-4}" \
    "$(l_endpoint)/api/chat" -H 'Content-Type: application/json' -d "$body" \
    | jq -r '.message.content'
}

#!/usr/bin/env bash
# llama-control.sh — manage the single-model llama-jinja stack.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE="${LLAMA_COMPOSE:-docker compose}"
BASE_URL="http://localhost:8080"
CURL="${CURL_BIN:-curl}"

die() { echo "llama-control: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./llama-control.sh <command>
  use <alias>   select model (models/<alias>.env -> .env) and (re)start
  up            start with current .env
  down          stop and remove the container
  restart       force-recreate with current .env
  status        compose ps + live readiness (OpenAI + Anthropic probes)
  logs          follow container logs
  models        list registry aliases (and which is active)
  upgrade       pull :server-cuda, show new digest, re-pin after confirm
USAGE
}

active_alias() {
  [ -f .env ] || { echo ""; return; }
  sed -n 's/^# alias: //p' .env | head -1
}

cmd_models() {
  local act; act="$(active_alias)"
  echo "available models (active: ${act:-none}):"
  for f in models/*.env; do
    [ -e "$f" ] || continue
    local a; a="$(basename "$f" .env)"
    if [ "$a" = "$act" ]; then echo "  * $a"; else echo "    $a"; fi
  done
}

cmd_use() {
  local alias="${1:-}"; [ -n "$alias" ] || die "use requires an <alias> (see: models)"
  local f="models/${alias}.env"; [ -f "$f" ] || die "no such model '$alias' (see: models)"
  cp "$f" .env
  echo "selected $alias"
  $COMPOSE up -d --force-recreate
  echo "up (model: $alias). Cold load can take ~1-2 min; see: status / logs"
}

cmd_up() {
  [ -f .env ] || die "no .env — run: ./llama-control.sh use <alias>"
  $COMPOSE up -d
  echo "up (model: $(active_alias)). Cold load can take ~1-2 min; see: status / logs"
}

cmd_down()    { $COMPOSE down; }
cmd_restart() { [ -f .env ] || die "no .env — run: ./llama-control.sh use <alias>"; $COMPOSE up -d --force-recreate; }
cmd_logs()    { $COMPOSE logs -f; }

probe() { # $1 = oai|anthropic  -> prints HTTP code
  # No `-f`: we want the actual status code (e.g. 503 while loading) as the sole
  # output; `|| echo 000` then only fires on a true transport failure.
  if [ "$1" = oai ]; then
    $CURL -sS -o /dev/null -w '%{http_code}' -m 30 -X POST "$BASE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"messages":[{"role":"user","content":"ping"}],"max_tokens":4}' 2>/dev/null || echo "000"
  else
    $CURL -sS -o /dev/null -w '%{http_code}' -m 30 -X POST "$BASE_URL/v1/messages" \
      -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"x","max_tokens":4,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null || echo "000"
  fi
}

cmd_status() {
  $COMPOSE ps || true
  echo "active model: $(active_alias)"
  local oai ant; oai="$(probe oai)"; ant="$(probe anthropic)"
  echo "readiness: OpenAI /v1/chat/completions=$oai  Anthropic /v1/messages=$ant"
  if [ "$oai" = 200 ] && [ "$ant" = 200 ]; then echo "READY"; else echo "NOT READY (want 200/200; model may still be loading)"; fi
}

cmd_upgrade() {
  local img='ghcr.io/ggml-org/llama.cpp:server-cuda'
  docker pull "$img"
  local newdig; newdig="$(docker image inspect "$img" --format '{{index .RepoDigests 0}}')"
  echo "latest digest: $newdig"
  echo "Verify probes against a test bring-up BEFORE re-pinning."
  read -r -p "Re-pin all models/*.env LLAMA_IMAGE to this digest? [y/N] " ans
  [ "$ans" = y ] || { echo "left unchanged."; return; }
  for f in models/*.env; do sed -i "s#^LLAMA_IMAGE=.*#LLAMA_IMAGE=${newdig}#" "$f"; done
  echo "re-pinned. Apply with: ./llama-control.sh use <alias>"
}

case "${1:-}" in
  use)     shift; cmd_use "${1:-}";;
  up)      cmd_up;;
  down)    cmd_down;;
  restart) cmd_restart;;
  status)  cmd_status;;
  logs)    cmd_logs;;
  models)  cmd_models;;
  upgrade) cmd_upgrade;;
  ""|-h|--help) usage;;
  *) usage; die "unknown command: $1";;
esac

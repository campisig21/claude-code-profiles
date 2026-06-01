#!/usr/bin/env bash
# Source from .bashrc:  source ~/docker/llama/llama-control.sh
#
# Helpers for the llama.cpp router-mode multi-model server.
# Router mode (build b9209+) has no explicit unload endpoint — these
# functions wrap the LRU-eviction dance and other common ops.

LLAMA_HOST=${LLAMA_HOST:-http://localhost:8080}
LLAMA_COMPOSE_DIR=${LLAMA_COMPOSE_DIR:-$HOME/docker/llama}

# --- inspection ---------------------------------------------------------

llama_status() {
  curl -sf "$LLAMA_HOST/v1/models" | python3 -c '
import json, sys
data = json.load(sys.stdin)["data"]
for m in sorted(data, key=lambda x: x["id"]):
    mid = m["id"]
    status = m.get("status", {}).get("value", "?")
    print(f"{mid:20s} {status}")'
}

llama_loaded() {
  curl -sf "$LLAMA_HOST/v1/models" | python3 -c '
import json, sys
for m in json.load(sys.stdin)["data"]:
    if m.get("status",{}).get("value") == "loaded":
        print(m["id"])'
}

llama_vram() {
  nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv
}

llama_logs() {
  docker logs -f --tail "${1:-50}" llama-server
}

# --- per-model ----------------------------------------------------------

# Ping a model. Loads it on-demand if not loaded. Uses max_tokens=400 so
# thinking models (Qwen3.x, Qwopus) have budget for reasoning + content.
llama_ping() {
  local model=$1 prompt=${2:-"In one sentence: what is 2+2?"}
  [[ -z $model ]] && { echo "usage: llama_ping <alias> [prompt]"; return 1; }
  curl -sf "$LLAMA_HOST/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "import json,sys; print(json.dumps({'model':sys.argv[1],'messages':[{'role':'user','content':sys.argv[2]}],'max_tokens':400}))" "$model" "$prompt")" \
    | python3 -m json.tool
}

# Force a model to load (cheap 1-token request).
llama_preload() {
  local model=$1
  [[ -z $model ]] && { echo "usage: llama_preload <alias>"; return 1; }
  echo "loading $model (may take 30-90s for large models)..."
  curl -sf "$LLAMA_HOST/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}],\"max_tokens\":1}" \
    > /dev/null && echo "$model loaded" || echo "FAILED"
}

# Best-effort unload via LRU eviction.
#
# Mechanism: touch every OTHER loaded model (pushes target to LRU position),
# then load an unloaded model to force eviction at the MODELS_MAX cap.
#
# Caveats:
# - Only works when MODELS_MAX is already reached. If fewer than MODELS_MAX
#   models are loaded, loading another one just adds without evicting.
# - "Touching" a loaded model with max_tokens=1 is cheap (~100ms) but not
#   free. Avoid in a tight loop.
# - The only *guaranteed* unload is llama_restart.
llama_unload() {
  local target=$1
  [[ -z $target ]] && { echo "usage: llama_unload <alias>"; return 1; }

  local loaded; loaded=$(llama_loaded)
  if ! grep -qx "$target" <<< "$loaded"; then
    echo "$target is not loaded"
    return 0
  fi

  # Pick an unloaded model to use as the evictor. Prefer the smallest.
  local evictor; evictor=$(curl -sf "$LLAMA_HOST/v1/models" | python3 -c '
import json, sys
for m in json.load(sys.stdin)["data"]:
    if m.get("status",{}).get("value") != "loaded" and m["id"] != "DEFAULT":
        print(m["id"]); break')
  if [[ -z $evictor ]]; then
    echo "no unloaded model available as evictor — try llama_restart instead"
    return 1
  fi

  # Push target to LRU position by touching every other loaded model.
  while IFS= read -r m; do
    [[ -z $m || $m == "$target" ]] && continue
    curl -sf "$LLAMA_HOST/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}],\"max_tokens\":1}" \
      > /dev/null
  done <<< "$loaded"

  echo "loading evictor '$evictor' to push '$target' out..."
  curl -sf "$LLAMA_HOST/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$evictor\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}],\"max_tokens\":1}" \
    > /dev/null

  if llama_loaded | grep -qx "$target"; then
    echo "warning: $target still loaded — MODELS_MAX likely not reached"
    return 1
  fi
  echo "$target unloaded"
}

# --- lifecycle ----------------------------------------------------------

llama_restart() {
  (cd "$LLAMA_COMPOSE_DIR" && docker compose restart llama-server)
}

llama_stop() {
  (cd "$LLAMA_COMPOSE_DIR" && docker compose stop llama-server)
}

llama_up() {
  (cd "$LLAMA_COMPOSE_DIR" && docker compose up -d llama-server)
}

# Pull latest :server-cuda image and restart.
llama_pull() {
  (cd "$LLAMA_COMPOSE_DIR" && docker compose pull llama-server && docker compose up -d llama-server)
}

# Switch preset. Triggers restart. Accepts any preset file in presets/.
llama_preset() {
  local mode=$1
  if [[ -z $mode ]]; then
    echo "usage: llama_preset <name>"
    echo "available presets:"
    ls "$LLAMA_COMPOSE_DIR/presets/" | sed 's/\.ini$//' | sed 's/^/  /'
    return 1
  fi
  if [[ ! -f "$LLAMA_COMPOSE_DIR/presets/$mode.ini" ]]; then
    echo "preset '$mode' not found at presets/$mode.ini"; return 1
  fi
  sed -i "s/^MODE=.*/MODE=$mode/" "$LLAMA_COMPOSE_DIR/.env"
  (cd "$LLAMA_COMPOSE_DIR" && docker compose up -d llama-server)
}

# Change MODELS_MAX (LRU cap). Triggers restart (env vars only re-read at start).
llama_models_max() {
  local n=$1
  [[ ! $n =~ ^[0-9]+$ ]] && { echo "usage: llama_models_max <N>"; return 1; }
  sed -i "s/^MODELS_MAX=.*/MODELS_MAX=$n/" "$LLAMA_COMPOSE_DIR/.env"
  echo "MODELS_MAX=$n; restarting container..."
  (cd "$LLAMA_COMPOSE_DIR" && docker compose up -d llama-server)
}

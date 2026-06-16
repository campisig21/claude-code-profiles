# llama-jinja Station Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a separate `~/docker/llama-jinja/` stack on the station that serves qwen36-35b from one plain `llama-server` exposing both OpenAI `/v1/chat/completions` and native Anthropic `/v1/messages` on :8080 — no LiteLLM proxy, current `~/docker/llama/` untouched.

**Architecture:** Source files are authored + version-controlled in this repo under `station/llama-jinja/`, then deployed to the station via `rsync` (the `.env` is generated on the station by `llama-control.sh use`, never committed). One `llama-server` container parameterized by a single `LLAMA_ARGS` env var sourced from a per-model registry file; `llama-control.sh` swaps models by `cp models/<alias>.env .env` + force-recreate.

**Tech Stack:** docker compose v2, llama.cpp `server-cuda` image (pinned digest b9209), bash, curl. Spec: `docs/superpowers/specs/2026-06-15-llama-jinja-station-design.md`.

**Note — this is infra, not a unit-tested library.** "Verification" means config validation (`bash -n`, `docker compose config`) and live endpoint probes (curl, `claude -p`), not unit tests. Repo file-creation tasks commit; station actions (deploy/up/probe) do not.

**Concrete values (captured + verified 2026-06-15 — use verbatim):**
- Image (pin by digest, no tag): `ghcr.io/ggml-org/llama.cpp@sha256:c4d2aaf10abd9130d77d117be10dee86699fd5daa4550e9385733ba173ccc334`
- Models dir mounted `/models/gguf:/models:ro`. Files present: `Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf` (31G), `Qwopus3.5-27B-v3-Q8_0.gguf` (27G), `Qwen3.5-9B.Q8_0.gguf` (8.9G).
- Station SSH: `greg-campisi@100.64.0.4` (key + agent already set up this session).
- Env-file rule: `LLAMA_ARGS` is **one physical line, unquoted** (docker dotenv has no line-continuation and we avoid quote-stripping ambiguity). Compose `command` uses `$$LLAMA_ARGS` so the **container** shell expands it at runtime.

---

### Task 1: Confirm prerequisites on the station (read-only)

**Files:** none (verification only).

- [ ] **Step 1: Confirm the image digest is still the pinned one**

Run:
```bash
ssh greg-campisi@100.64.0.4 "docker image inspect ghcr.io/ggml-org/llama.cpp:server-cuda --format '{{index .RepoDigests 0}}'"
```
Expected: `ghcr.io/ggml-org/llama.cpp@sha256:c4d2aaf10abd9130d77d117be10dee86699fd5daa4550e9385733ba173ccc334`
(If different, the upstream tag moved; use the value returned and note it — but the b9209 digest above is what was verified to serve `/v1/messages`.)

- [ ] **Step 2: Confirm the three model GGUFs exist**

Run:
```bash
ssh greg-campisi@100.64.0.4 'for f in /models/gguf/Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf /models/gguf/Qwopus3.5-27B-v3-Q8_0.gguf /models/gguf/Qwen3.5-9B.Q8_0.gguf; do [ -e "$f" ] && echo "OK $f" || echo "MISS $f"; done'
```
Expected: three `OK` lines. If any `MISS`, drop that model from the registry (Task 2) and note it.

---

### Task 2: Create the model registry files

**Files:**
- Create: `station/llama-jinja/.gitignore`
- Create: `station/llama-jinja/models/qwen36-35b.env`
- Create: `station/llama-jinja/models/qwopus-27b.env`
- Create: `station/llama-jinja/models/qwen-9b.env`

- [ ] **Step 1: Create `.gitignore` (the generated active env must never be committed)**

`station/llama-jinja/.gitignore`:
```gitignore
# Active selection is generated on the station by `llama-control.sh use`.
.env
```

- [ ] **Step 2: Create `models/qwen36-35b.env` (daily driver — tuned flags + MTP)**

`station/llama-jinja/models/qwen36-35b.env` (LLAMA_ARGS is ONE line):
```dotenv
# alias: qwen36-35b
LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp@sha256:c4d2aaf10abd9130d77d117be10dee86699fd5daa4550e9385733ba173ccc334
LLAMA_ARGS=--model /models/Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf --alias qwen36-35b -ngl -1 --ctx-size 262144 --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on --split-mode row --tensor-split 1,1 --spec-type draft-mtp --spec-draft-n-max 2 --slots
```

- [ ] **Step 3: Create `models/qwopus-27b.env`**

`station/llama-jinja/models/qwopus-27b.env`:
```dotenv
# alias: qwopus-27b
LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp@sha256:c4d2aaf10abd9130d77d117be10dee86699fd5daa4550e9385733ba173ccc334
LLAMA_ARGS=--model /models/Qwopus3.5-27B-v3-Q8_0.gguf --alias qwopus-27b -ngl -1 --ctx-size 32768 --flash-attn on --split-mode row --tensor-split 1,1 --slots
```

- [ ] **Step 4: Create `models/qwen-9b.env`**

`station/llama-jinja/models/qwen-9b.env`:
```dotenv
# alias: qwen-9b
LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp@sha256:c4d2aaf10abd9130d77d117be10dee86699fd5daa4550e9385733ba173ccc334
LLAMA_ARGS=--model /models/Qwen3.5-9B.Q8_0.gguf --alias qwen-9b -ngl -1 --ctx-size 32768 --flash-attn on --split-mode row --tensor-split 1,1 --slots
```

- [ ] **Step 5: Verify each registry file has a single LLAMA_ARGS line and a digest**

Run:
```bash
for f in station/llama-jinja/models/*.env; do
  echo "== $f =="; grep -c '^LLAMA_ARGS=' "$f"; grep -c '^LLAMA_IMAGE=' "$f"; grep -c '^# alias: ' "$f"
done
```
Expected: each file prints `1`, `1`, `1` (exactly one of each).

- [ ] **Step 6: Commit**

```bash
git add station/llama-jinja/.gitignore station/llama-jinja/models/
git commit -m "feat(station): llama-jinja model registry (qwen36-35b/qwopus-27b/qwen-9b)"
```

---

### Task 3: Create the docker-compose file

**Files:**
- Create: `station/llama-jinja/docker-compose.yaml`

- [ ] **Step 1: Write the compose file**

`station/llama-jinja/docker-compose.yaml`:
```yaml
services:
  llama-jinja:
    image: ${LLAMA_IMAGE}
    container_name: llama-jinja
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /models/gguf:/models:ro
    env_file: .env
    entrypoint: ["/bin/sh", "-c"]
    command: ['exec /app/llama-server --host 0.0.0.0 --port 8080 $$LLAMA_ARGS']
    healthcheck:
      test: ["CMD", "sh", "-c", "curl -fsS http://localhost:8080/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 180s
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

- [ ] **Step 2: Verify the `$$` escape is present (so the container, not compose, expands LLAMA_ARGS)**

Run:
```bash
grep -F '$$LLAMA_ARGS' station/llama-jinja/docker-compose.yaml
```
Expected: the `command:` line prints. (A single `$LLAMA_ARGS` here would be wrong — compose would interpolate it at parse time.)

- [ ] **Step 3: Commit**

```bash
git add station/llama-jinja/docker-compose.yaml
git commit -m "feat(station): llama-jinja compose (single jinja server, dual API)"
```

---

### Task 4: Create the control script

**Files:**
- Create: `station/llama-jinja/llama-control.sh`

- [ ] **Step 1: Write the script**

`station/llama-jinja/llama-control.sh`:
```bash
#!/usr/bin/env bash
# llama-control.sh — manage the single-model llama-jinja stack.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE="docker compose"
BASE_URL="http://localhost:8080"

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
  if [ "$1" = oai ]; then
    curl -fsS -o /dev/null -w '%{http_code}' -m 30 -X POST "$BASE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"messages":[{"role":"user","content":"ping"}],"max_tokens":4}' 2>/dev/null || echo "000"
  else
    curl -fsS -o /dev/null -w '%{http_code}' -m 30 -X POST "$BASE_URL/v1/messages" \
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
```

- [ ] **Step 2: Make it executable and syntax-check it**

Run:
```bash
chmod +x station/llama-jinja/llama-control.sh
bash -n station/llama-jinja/llama-control.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK` (no parse errors).

- [ ] **Step 3: Commit**

```bash
git add station/llama-jinja/llama-control.sh
git commit -m "feat(station): llama-control.sh (use/up/down/status/models/upgrade)"
```

---

### Task 5: Create the README

**Files:**
- Create: `station/llama-jinja/README.md`

- [ ] **Step 1: Write the README**

`station/llama-jinja/README.md`:
````markdown
# llama-jinja

One `llama-server` (jinja default-on) serving **both** OpenAI `/v1/chat/completions`
and native Anthropic `/v1/messages` on `:8080`. Single model at a time; qwen36-35b
is the daily driver. Replaces the LiteLLM proxy and router mode for daily use.

Lives alongside the original `~/docker/llama/` (router) stack — **only one may run
at a time** (they share port 8080 and the GPUs).

## Switch from the old stack to this one
```bash
cd ~/docker/llama && docker compose down        # stop the router stack
cd ~/docker/llama-jinja && ./llama-control.sh use qwen36-35b
./llama-control.sh status                        # wait for READY (200/200)
```

## Rollback to the old stack
```bash
cd ~/docker/llama-jinja && ./llama-control.sh down
cd ~/docker/llama && docker compose up -d
```

## Swap models
```bash
./llama-control.sh models           # list registry aliases
./llama-control.sh use qwopus-27b   # cp models/qwopus-27b.env .env + force-recreate
./llama-control.sh status
```

## Clients
- **codex / OpenAI:** `http://100.64.0.4:8080/v1` (unchanged).
- **Claude Code / `claude -p`:** no proxy —
  `ANTHROPIC_BASE_URL=http://100.64.0.4:8080`, `ANTHROPIC_MODEL=<alias>`,
  `ANTHROPIC_AUTH_TOKEN=dummy`.

## Add a model
Create `models/<alias>.env` with `# alias: <alias>`, `LLAMA_IMAGE=...`, and a
single-line `LLAMA_ARGS=...` (must include `--model /models/<file>.gguf` and
`--alias <alias>`). Then `./llama-control.sh use <alias>`.

## Upgrade the image (deliberate)
```bash
./llama-control.sh upgrade   # pulls :server-cuda, shows digest, re-pins after you confirm
```
Pinned to a digest so upstream tag bumps never change behavior silently.
````

- [ ] **Step 2: Commit**

```bash
git add station/llama-jinja/README.md
git commit -m "docs(station): llama-jinja README (switch/rollback/swap/clients)"
```

---

### Task 6: Deploy to the station and validate compose

**Files:** none in repo (deploys to `~/docker/llama-jinja/` on the station).

- [ ] **Step 1: Rsync the stack to the station (exclude the generated .env)**

Run:
```bash
rsync -av --exclude='.env' station/llama-jinja/ greg-campisi@100.64.0.4:~/docker/llama-jinja/
ssh greg-campisi@100.64.0.4 'chmod +x ~/docker/llama-jinja/llama-control.sh'
```
Expected: transfer lists `docker-compose.yaml`, `llama-control.sh`, `README.md`, `.gitignore`, `models/*.env`.

- [ ] **Step 2: Select the model and validate compose interpolation (no bring-up yet)**

Run:
```bash
ssh greg-campisi@100.64.0.4 'cd ~/docker/llama-jinja && cp models/qwen36-35b.env .env && docker compose config' | grep -E 'image:|command:'
```
Expected: `image: ghcr.io/ggml-org/llama.cpp@sha256:c4d2aaf10abd…` resolved, and a `command:` line still containing literal `$LLAMA_ARGS` (proves compose did NOT expand it — the container will). If `image:` shows empty or `command` shows the args already expanded, fix Task 2/3 and re-deploy.

---

### Task 7: Cut over — old stack down, new stack up

**Files:** none.

- [ ] **Step 1: Stop the old router stack (frees :8080 + VRAM)**

Run:
```bash
ssh greg-campisi@100.64.0.4 'cd ~/docker/llama && docker compose down'
```
Expected: `llama-server` (and `open-webui`) removed.

- [ ] **Step 2: Bring up llama-jinja with qwen36-35b**

Run:
```bash
ssh greg-campisi@100.64.0.4 'cd ~/docker/llama-jinja && ./llama-control.sh use qwen36-35b'
```
Expected: `selected qwen36-35b` then compose creates `llama-jinja`.

- [ ] **Step 3: Wait for readiness (cold load of 31G)**

Run (poll up to ~2 min):
```bash
ssh greg-campisi@100.64.0.4 'cd ~/docker/llama-jinja && for i in $(seq 1 40); do ./llama-control.sh status | grep -q "^READY" && { ./llama-control.sh status; break; }; sleep 5; done'
```
Expected: ends with `readiness: OpenAI ...=200  Anthropic ...=200` and `READY`.

- [ ] **Step 4: Confirm a single model copy is resident in VRAM**

Run:
```bash
ssh greg-campisi@100.64.0.4 'nvidia-smi --query-gpu=index,memory.used --format=csv,noheader'
```
Expected: ~18–19 GB used per GPU (one 35B copy split across both), not ~36 GB (which would mean two copies — the old wedge).

---

### Task 8: Acceptance — proxy-free dual-API + claude -p smoke

**Files:** none (live probes).

- [ ] **Step 1: OpenAI endpoint returns content (codex path)**

Run:
```bash
curl -s -m 60 http://100.64.0.4:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen36-35b","messages":[{"role":"user","content":"Reply with exactly: PONG"}],"max_tokens":512}' \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("OAI-OK:",repr(d["choices"][0]["message"]["content"][-40:]))'
```
Expected: `OAI-OK: '...PONG...'`.

- [ ] **Step 2: Anthropic endpoint returns content (Claude path)**

Run:
```bash
curl -s -m 60 http://100.64.0.4:8080/v1/messages -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"qwen36-35b","max_tokens":512,"messages":[{"role":"user","content":"Reply with exactly: PONG"}]}' \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("ANT-OK:",d.get("type"),repr("".join(b.get("text","") for b in d.get("content",[]) if b.get("type")=="text")[-40:]))'
```
Expected: `ANT-OK: message '...PONG...'`.

- [ ] **Step 2.5: Ensure NO LiteLLM proxy is running (prove the server is the only thing answering)**

Run:
```bash
pkill -f 'litellm --config /tmp/litellm.yaml' 2>/dev/null; pgrep -fl litellm || echo "no litellm running"
```
Expected: `no litellm running`.

- [ ] **Step 3: `claude -p` drives qwen directly (no proxy) in a scratch dir**

Run:
```bash
d=$(mktemp -d); cd "$d"
env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL=http://100.64.0.4:8080 ANTHROPIC_AUTH_TOKEN=dummy \
  ANTHROPIC_MODEL=qwen36-35b DISABLE_PROMPT_CACHING=1 \
  claude -p "Write a file hello.txt containing exactly the word: hi. Then run 'cat hello.txt' to confirm." \
  --model qwen36-35b --dangerously-skip-permissions --allowedTools "Read,Write,Bash" 2>&1 | tail -5
echo "exit=$? ; file:"; cat "$d/hello.txt" 2>/dev/null
```
Expected: claude exits 0 and `hello.txt` contains `hi`.

---

### Task 9: Swap-path test, then return to qwen36-35b

**Files:** none.

- [ ] **Step 1: Swap to qwen-9b and confirm it serves**

Run:
```bash
ssh greg-campisi@100.64.0.4 'cd ~/docker/llama-jinja && ./llama-control.sh use qwen-9b && for i in $(seq 1 24); do ./llama-control.sh status | grep -q "^READY" && break; sleep 5; done; ./llama-control.sh status'
```
Expected: ends `READY` with `200/200`, active model `qwen-9b`.

- [ ] **Step 2: Swap back to the daily driver**

Run:
```bash
ssh greg-campisi@100.64.0.4 'cd ~/docker/llama-jinja && ./llama-control.sh use qwen36-35b && for i in $(seq 1 40); do ./llama-control.sh status | grep -q "^READY" && break; sleep 5; done; ./llama-control.sh status'
```
Expected: `READY`, active model `qwen36-35b`.

---

### Task 10: Finalize

**Files:** none in repo (memory + resting state).

- [ ] **Step 1: Leave the station on qwen36-35b, old stack down**

Run:
```bash
ssh greg-campisi@100.64.0.4 'cd ~/docker/llama-jinja && ./llama-control.sh status'
```
Expected: `READY`, qwen36-35b. (Resting state for daily use.)

- [ ] **Step 2: Update memory to reflect native dual-API (proxy retired)**

Edit `claude-harness-local-model.md` and `station-local-bakeoff.md`: the LiteLLM proxy is now optional/retired — Claude Code points `ANTHROPIC_BASE_URL` directly at `http://100.64.0.4:8080`; record the `llama-jinja` stack + `llama-control.sh` as the canonical local serving path. Update `MEMORY.md` index lines if descriptions change.

- [ ] **Step 3: Final verification summary**

Confirm and report: OpenAI 200, Anthropic 200, `claude -p` smoke passed, swap works, single VRAM copy, old stack untouched (`ls ~/docker/llama` unchanged). State plainly which checks passed.

---

## Self-Review

**1. Spec coverage:**
- Separate dir, current untouched → Tasks 2–6 (`station/llama-jinja/`, rsync), Task 7 (old `down` first), Task 10 (old untouched).
- Single jinja server, dual API → Task 3 (compose), Task 8 (both probes).
- `sh -c $$LLAMA_ARGS` + `.env` double-duty + single-line args + full digest → Task 2 (registry), Task 3 + Step 2 (escape check), Task 6 Step 2 (interpolation check).
- Registry + control script (use/up/down/restart/status/logs/models/upgrade) → Task 4.
- qwen36-35b tuned args (ctx 262144, q8_0 KV, flash-attn, row split, MTP) → Task 2 Step 2.
- Pinned digest + deliberate upgrade → Task 2, Task 4 `cmd_upgrade`.
- Consumers (codex unchanged, Claude native, no proxy) → Task 5 (README), Task 8 (Steps 1/2.5/3).
- Healthcheck on correct port → Task 3.
- 5-step acceptance → Tasks 8–9.
- One-at-a-time enforcement / rollback → Task 5, Task 7.
No gaps found.

**2. Placeholder scan:** Digest, model paths, and all commands are concrete; no TBD/TODO. The `…` in expected `image:`/`PONG` outputs are match-substrings, not placeholders.

**3. Consistency:** Alias names (`qwen36-35b`/`qwopus-27b`/`qwen-9b`) match across registry files, `use` calls, and probes. `# alias:` comment format matches `active_alias()`'s `sed`. `$$LLAMA_ARGS` (compose) ↔ `$LLAMA_ARGS` (container runtime) is intentional and checked. `LLAMA_IMAGE` set in registry, consumed by `image: ${LLAMA_IMAGE}`.

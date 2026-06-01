# Codex Dispatch — Local-Model Backend (C.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second dispatch backend — codex's agentic harness pointed at a quantized coding model on the user's Docker/llama.cpp workstation (reached over a headscale tailnet) — selectable per-dispatch via `--backend codex|local`, alongside (and for quick tasks instead of) the default codex-cloud backend.

**Architecture:** Subsystem C already isolated codex behind three functions in `lib/dispatch.sh`. C.1 is purely additive: a one-line `d_backend_args` resolver maps `--backend local` to a codex profile flag (`-p local`); that flag is threaded through the existing `d_codex_exec`/`d_codex_resume` calls; a new `lib/local.sh` manages the remote model lifecycle over SSH+HTTP; and a readiness preflight refuses local dispatch when the model isn't loaded. The workstation runs llama.cpp in **router mode** (models auto-load on request and LRU-evict), so readiness is the target alias's `status=="loaded"`, and `local-up` switches to the model's dedicated preset over SSH. No C land/verify/abandon/sidecar logic is rewritten. The repo never leaves the Mac — only inference HTTP crosses the tailnet.

**Tech Stack:** Pure bash (no bats), `jq`, the C dependency-free test harness (`tests/lib.sh` + `tests/run.sh`), codex 0.135 profiles (`-p`/`$CODEX_HOME/<name>.config.toml`), llama.cpp router-mode OpenAI-compatible `/v1` endpoint.

**Spec:** `docs/specs/2026-05-31-codex-dispatch-local-backend-design.md` (decisions L1–L7 + §10 workstation addendum).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `lib/dispatch.sh` | Backend resolver `d_backend_args`; thread extra args through `d_codex_exec`/`d_codex_resume`. | Modify |
| `lib/local.sh` | Remote model lifecycle: getters, `l_probe`, `l_ready`, `l_preload`, `l_up`, `l_down`. **New, focused file.** | Create |
| `codex_dispatch.sh` | `--backend` flag on `dispatch`/`quick`; sidecar `backend` field; local-readiness preflight; `local-up`/`local-down` subcommands; `doctor` local-state line; backend surfaced in `show`/`list`. | Modify |
| `install.sh` | Idempotently write `$CODEX_HOME/local.config.toml` (the llama.cpp codex profile). | Modify |
| `skills/codex-implement/SKILL.md` | Backend routing guidance (decision table column + one red-flag + checklist note). | Modify |
| `tests/lib.sh` | Test doubles: argv-logging fake codex; `ps_make_fake_ssh`. | Modify |
| `tests/dispatch_backend_test.sh` | Resolver + arg threading + `--backend` flag + sidecar field + bogus backend + resume-with-backend. | Create |
| `tests/local_lifecycle_test.sh` | `l_probe` (status parse) + `l_ready`/`l_up`/`l_down` via `CODEX_DISPATCH_FAKE_STATE` + fake ssh/curl. | Create |
| `tests/dispatch_local_preflight_test.sh` | `dispatch`/`quick --backend local` refuse when not ready, proceed when ready. | Create |
| `tests/dispatch_doctor_test.sh` | Assert the new local-state line. | Modify |
| `tests/install_test.sh` | Sandbox `CODEX_HOME`; assert profile written + idempotent. | Modify |
| `docs/2026-06-01-c1-local-backend-smoke.md` | Manual real-workstation smoke checklist. | Create |

**Test-injection seams (all `CODEX_DISPATCH_*`, matching C's `CODEX_DISPATCH_CODEX_BIN`/`_NOW` convention):**
- `CODEX_DISPATCH_FAKE_STATE` — short-circuits `l_probe`/`l_preload` to a literal state (`unreachable|up-not-loaded|ready`); avoids real network.
- `CODEX_DISPATCH_SSH_BIN` / `CODEX_DISPATCH_CURL_BIN` — override `ssh`/`curl` bins.
- `FAKE_CODEX_ARGV_LOG` (fake codex) — append each invocation's argv to a file.
- `FAKE_SSH_LOG` / `FAKE_SSH_RC` (fake ssh) — record remote command / force exit code.
- `FAKE_QWEN_STATUS` / `FAKE_CURL_RC` (fake curl, in `local_lifecycle_test`) — drive the `/v1/models` JSON body / curl failure.
- `CODEX_DISPATCH_LOCAL_POLL_INTERVAL` / `_TIMEOUT` — keep `l_up` polling fast in tests.

**Knob defaults (informed by `docs/local-docs/`, all overridable):** endpoint `http://100.64.0.4:8080/v1`; model alias `qwen36-35b` *(verify at `/v1/models`)*; ssh `greg-campisi@100.64.0.4`; up = switch to `qwen36-only` preset + `docker compose up -d`; down = `docker compose stop`.

---

## Task 1: Backend resolver + test doubles

**Files:**
- Modify: `lib/dispatch.sh` (add `d_backend_args` after `d_codex_session_id`, ~line 79)
- Modify: `tests/lib.sh` (extend `ps_make_fake_codex`; add `ps_make_fake_ssh`)
- Create: `tests/dispatch_backend_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/dispatch_backend_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# --- resolver ---------------------------------------------------------------
assert_eq "$(d_backend_args codex)" ""        "codex backend -> no extra flags"
assert_eq "$(d_backend_args)"      ""         "empty/default backend -> no extra flags"
assert_eq "$(d_backend_args local)" "-p local" "local backend -> -p <profile>"
( CODEX_DISPATCH_LOCAL_PROFILE=ws; assert_eq "$(d_backend_args local)" "-p ws" "profile override honored" )
d_backend_args bogus >/dev/null 2>&1; assert_eq "$?" "1" "unknown backend returns nonzero"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/dispatch_backend_test.sh`
Expected: FAIL — `d_backend_args: command not found` / mismatches (function undefined).

- [ ] **Step 3: Add the resolver to `lib/dispatch.sh`**

Insert immediately after the `d_codex_session_id` function (after line 79, before the `# --- checks ---` banner):

```bash
# --- backend selection (C.1) ------------------------------------------------
# d_backend_args <backend> -> echo extra codex flags for that backend.
#   codex (default) -> (nothing)        local -> -p <profile>
# Returns nonzero on an unknown backend so the caller can die loudly.
d_backend_args() {
  case "${1:-codex}" in
    codex) : ;;
    local) printf '%s %s' '-p' "${CODEX_DISPATCH_LOCAL_PROFILE:-local}" ;;
    *)     return 1 ;;
  esac
}
```

- [ ] **Step 4: Add test doubles to `tests/lib.sh`**

In `ps_make_fake_codex`, add argv logging as the FIRST line after `set -uo pipefail` inside the heredoc (so every invocation, including `--version`, is logged). Change:

```bash
#!/usr/bin/env bash
set -uo pipefail
# --version short-circuit
```
to:
```bash
#!/usr/bin/env bash
set -uo pipefail
[ -n "${FAKE_CODEX_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CODEX_ARGV_LOG"
# --version short-circuit
```

Then append a new fake-ssh helper after `ps_make_sandbox_repo` (end of file):

```bash
# A fake `ssh` for lifecycle tests. Records "<target> :: <remote cmd>" to
# FAKE_SSH_LOG; exits FAKE_SSH_RC (default 0). Echoes path to the fake.
ps_make_fake_ssh() {
  local p="$PS_SANDBOX/fake-ssh"
  cat > "$p" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_SSH_LOG:-}" ] && printf '%s :: %s\n' "$1" "${*:2}" >> "$FAKE_SSH_LOG"
exit "${FAKE_SSH_RC:-0}"
SH
  chmod +x "$p"
  printf '%s\n' "$p"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/dispatch_backend_test.sh`
Expected: PASS — `(5 checks, 0 failed)`.

- [ ] **Step 6: Confirm no regressions**

Run: `bash tests/run.sh`
Expected: all existing test files still pass (the fake-codex change is inert unless `FAKE_CODEX_ARGV_LOG` is set).

- [ ] **Step 7: Commit**

```bash
git add lib/dispatch.sh tests/lib.sh tests/dispatch_backend_test.sh
git commit -m "feat(dispatch): d_backend_args resolver + argv/ssh test doubles (C.1)"
```

---

## Task 2: Thread backend args through the codex invocation

**Files:**
- Modify: `lib/dispatch.sh:48-71` (`d_codex_exec`, `d_codex_resume`)
- Modify: `tests/dispatch_backend_test.sh` (append threading assertions)

- [ ] **Step 1: Write the failing test**

Append to `tests/dispatch_backend_test.sh`, before `ps_teardown_sandbox`:

```bash
# --- arg threading into the codex invocation --------------------------------
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
log="$PS_SANDBOX/argv.log"; : > "$log"

# exec with local backend args splices "-p local" into the codex argv
( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
    bash -c 'source "'"$PS_REPO_ROOT"'/lib/jsonutil.sh"; source "'"$PS_REPO_ROOT"'/lib/dispatch.sh";
             tmp="$(mktemp)"; d_codex_exec "'"$repo"'" "$tmp" "do it" -p local >/dev/null; rm -f "$tmp"' )
assert_contains "$(cat "$log")" "-p local" "exec splices backend args"
assert_contains "$(cat "$log")" "exec"     "exec still calls codex exec"

# exec with NO backend args is unchanged (no stray -p)
: > "$log"
( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
    bash -c 'source "'"$PS_REPO_ROOT"'/lib/jsonutil.sh"; source "'"$PS_REPO_ROOT"'/lib/dispatch.sh";
             tmp="$(mktemp)"; d_codex_exec "'"$repo"'" "$tmp" "do it" >/dev/null; rm -f "$tmp"' )
case "$(cat "$log")" in *"-p "*) echo "  FAIL: default exec leaked a -p flag"; exit 1;; esac
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/dispatch_backend_test.sh`
Expected: FAIL — `exec splices backend args: output missing [-p local]` (extra args currently ignored).

- [ ] **Step 3: Modify `d_codex_exec` and `d_codex_resume`**

Replace the body of `d_codex_exec` (lib/dispatch.sh:48-56) with:

```bash
d_codex_exec() {
  local wt="$1" lastmsg="$2" prompt="$3"; shift 3   # remaining args = backend flags
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}" stream
  stream="$(mktemp)"
  "$bin" exec "$@" --dangerously-bypass-approvals-and-sandbox --json \
         -C "$wt" -o "$lastmsg" "$prompt" > "$stream" 2>&1 || true
  d_codex_session_id "$stream"
  rm -f "$stream"
}
```

Replace the body of `d_codex_resume` (lib/dispatch.sh:61-71) with:

```bash
d_codex_resume() {
  local wt="$1" session="$2" prompt="$3"; shift 3   # remaining args = backend flags
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}"
  if [ -n "$session" ]; then
    "$bin" exec resume "$session" "$@" --dangerously-bypass-approvals-and-sandbox \
           -C "$wt" "$prompt" >/dev/null 2>&1 || true
  else
    "$bin" exec resume --last "$@" --dangerously-bypass-approvals-and-sandbox \
           -C "$wt" "$prompt" >/dev/null 2>&1 || true
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/dispatch_backend_test.sh`
Expected: PASS.

- [ ] **Step 5: Confirm no regressions**

Run: `bash tests/run.sh`
Expected: all pass — existing callers pass exactly 3 args, so `shift 3; "$@"` expands empty (byte-identical codex call).

- [ ] **Step 6: Commit**

```bash
git add lib/dispatch.sh tests/dispatch_backend_test.sh
git commit -m "feat(dispatch): thread backend flags into d_codex_exec/resume (C.1)"
```

---

## Task 3: Remote model probe — `lib/local.sh` (`l_probe`/`l_ready`, router-mode aware)

**Files:**
- Create: `lib/local.sh`
- Create: `tests/local_lifecycle_test.sh`

Router mode lists the whole fleet at `/v1/models` with a per-model `status.value`; readiness = the target alias is `loaded` (not merely present).

- [ ] **Step 1: Write the failing test**

Create `tests/local_lifecycle_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/local.sh"

# --- l_probe via the FAKE_STATE override (no network) -----------------------
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=ready          l_probe)" "ready"         "probe: ready"
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=up-not-loaded  l_probe)" "up-not-loaded" "probe: up-not-loaded"
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=unreachable    l_probe)" "unreachable"   "probe: unreachable"
( CODEX_DISPATCH_FAKE_STATE=ready         l_ready ); assert_eq "$?" "0" "ready -> l_ready 0"
( CODEX_DISPATCH_FAKE_STATE=up-not-loaded l_ready ); assert_eq "$?" "1" "not-loaded -> l_ready 1"

# --- l_probe REAL parse via a fake curl emitting router-mode JSON -----------
fcurl="$PS_SANDBOX/fake-curl"
cat > "$fcurl" <<'SH'
#!/usr/bin/env bash
# Emits a router-mode /v1/models body; FAKE_CURL_RC!=0 simulates connection failure.
[ "${FAKE_CURL_RC:-0}" != "0" ] && exit "$FAKE_CURL_RC"
printf '{"data":[{"id":"qwen36-35b","status":{"value":"%s"}},{"id":"other","status":{"value":"loaded"}}]}\n' "${FAKE_QWEN_STATUS:-loaded}"
SH
chmod +x "$fcurl"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_QWEN_STATUS=loaded   l_probe)" "ready"         "parse: alias loaded -> ready"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_QWEN_STATUS=unloaded l_probe)" "up-not-loaded" "parse: alias not loaded -> up-not-loaded"
assert_eq "$(CODEX_DISPATCH_CURL_BIN="$fcurl" FAKE_CURL_RC=7           l_probe)" "unreachable"   "parse: curl failure -> unreachable"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/local_lifecycle_test.sh`
Expected: FAIL — `lib/local.sh` does not exist (source error).

- [ ] **Step 3: Create `lib/local.sh` with getters + probe**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/local_lifecycle_test.sh`
Expected: PASS — `(8 checks, 0 failed)`.

- [ ] **Step 5: Commit**

```bash
git add lib/local.sh tests/local_lifecycle_test.sh
git commit -m "feat(local): router-mode l_probe/l_ready (status==loaded) (C.1)"
```

---

## Task 4: Remote load/unload — `l_preload`, `l_up` (preset switch), `l_down` (stop)

**Files:**
- Modify: `lib/local.sh` (append getters `l_up_cmd`/`l_down_cmd`, plus `l_preload`, `l_up`, `l_down`)
- Modify: `tests/local_lifecycle_test.sh` (append lifecycle assertions)

`local-up` runs the SSH preset-switch (qwen36 needs its dedicated preset), then polls to `loaded`, nudging an HTTP preload once if the server is up-but-not-loaded. `local-down` stops the container (full VRAM free).

- [ ] **Step 1: Write the failing test**

Append to `tests/local_lifecycle_test.sh`, before `ps_teardown_sandbox`:

```bash
# --- l_up / l_down via fake ssh (FAKE_STATE drives readiness; preload no-ops) ---
fssh="$(ps_make_fake_ssh)"
sshlog="$PS_SANDBOX/ssh.log"; : > "$sshlog"

# defaults reflect the workstation workflow
assert_contains "$(l_up_cmd)"   "qwen36-only"          "default up cmd switches to qwen36-only preset"
assert_contains "$(l_down_cmd)" "docker compose stop"  "default down cmd stops the container"

# l_up: runs the remote up command, then polls to readiness (fake=ready -> instant)
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" \
        CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' CODEX_DISPATCH_FAKE_STATE=ready \
        l_up 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_up succeeds when model becomes ready"
assert_contains "$out" "ready" "l_up reports readiness"
assert_contains "$(cat "$sshlog")" "UPMARK" "l_up ran the remote up command"

# l_up: stays not-loaded -> times out (fast via tiny interval/timeout)
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' \
        CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        CODEX_DISPATCH_LOCAL_POLL_INTERVAL=1 CODEX_DISPATCH_LOCAL_POLL_TIMEOUT=1 l_up 2>&1 )"; rc=$?
assert_eq "$rc" "1" "l_up times out when never ready"
assert_contains "$out" "timed out" "l_up explains the timeout"

# l_up: a failing remote up command is surfaced
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_RC=255 CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' \
        CODEX_DISPATCH_FAKE_STATE=up-not-loaded l_up 2>&1 )"; rc=$?
assert_eq "$rc" "1" "l_up fails when remote up command fails"

# l_down: stops the container (default), via ssh
: > "$sshlog"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" l_down 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_down succeeds"
assert_contains "$(cat "$sshlog")" "docker compose stop" "l_down stops the container by default"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/local_lifecycle_test.sh`
Expected: FAIL — `l_up_cmd: command not found`.

- [ ] **Step 3: Append getters, `l_preload`, `l_up`, `l_down` to `lib/local.sh`**

```bash
# Remote lifecycle commands (run over ssh). Defaults mirror docs/local-docs/llama-control.sh:
#   up   = switch to the dedicated qwen36-only preset (full 48 GB) and (re)start the container
#   down = stop the container (guaranteed full VRAM free; stops the whole fleet)
l_up_cmd()   { printf '%s' "${CODEX_DISPATCH_LOCAL_UP_CMD:-cd ~/docker/llama && sed -i 's/^MODE=.*/MODE=qwen36-only/' .env && docker compose up -d llama-server}"; }
l_down_cmd() { printf '%s' "${CODEX_DISPATCH_LOCAL_DOWN_CMD:-cd ~/docker/llama && docker compose stop llama-server}"; }

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
  local ssh_bin interval timeout waited nudged state
  ssh_bin="${CODEX_DISPATCH_SSH_BIN:-ssh}"
  echo "local-up: ensuring '$(l_model)' on $(l_ssh_tgt) (preset switch + load) ..."
  "$ssh_bin" "$(l_ssh_tgt)" "$(l_up_cmd)" || { echo "local-up: remote up command failed" >&2; return 1; }
  interval="${CODEX_DISPATCH_LOCAL_POLL_INTERVAL:-3}"
  timeout="${CODEX_DISPATCH_LOCAL_POLL_TIMEOUT:-240}"
  waited=0; nudged=0
  while [ "$waited" -lt "$timeout" ]; do
    state="$(l_probe)"
    if [ "$state" = ready ]; then echo "local-up: model ready."; return 0; fi
    if [ "$state" = up-not-loaded ] && [ "$nudged" -eq 0 ]; then l_preload; nudged=1; fi
    sleep "$interval"; waited=$((waited + interval))
  done
  echo "local-up: timed out after ${timeout}s waiting for readiness (state: $(l_probe))" >&2
  return 1
}

# l_down -> stop the model server to free VRAM. Default stops the container.
l_down() {
  local ssh_bin
  ssh_bin="${CODEX_DISPATCH_SSH_BIN:-ssh}"
  echo "local-down: stopping the model server on $(l_ssh_tgt) ..."
  if "$ssh_bin" "$(l_ssh_tgt)" "$(l_down_cmd)"; then
    echo "local-down: stop command sent (VRAM freed)."
  else
    echo "local-down: remote stop failed" >&2; return 1
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/local_lifecycle_test.sh`
Expected: PASS (the timeout case takes ~1s).

- [ ] **Step 5: Commit**

```bash
git add lib/local.sh tests/local_lifecycle_test.sh
git commit -m "feat(local): l_up (qwen36-only preset + preload) / l_down (stop) (C.1)"
```

---

## Task 5: `dispatch --backend` — flag, sidecar field, preflight

**Files:**
- Modify: `codex_dispatch.sh` (source `lib/local.sh`; `cmd_dispatch` flag/validation/preflight/sidecar/exec call)
- Create: `tests/dispatch_local_preflight_test.sh`
- Modify: `tests/dispatch_backend_test.sh` (append flag + sidecar assertions)

- [ ] **Step 1: Write the failing tests**

Create `tests/dispatch_local_preflight_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"

# --backend local is REFUSED when the model is not ready, with the local-up hint
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        bash "$ENGINE" dispatch --backend local --verify checks --check 'bash check.sh' "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "local dispatch refused when not ready"
assert_contains "$out" "local-up" "refusal names the fix"
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_list_ids | wc -l | tr -d ' ')" "0" "no sidecar/worktree created on refusal" )

# --backend local PROCEEDS when ready
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260601T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        CODEX_DISPATCH_FAKE_STATE=ready \
        bash "$ENGINE" dispatch --backend local --verify checks --check 'bash check.sh' --slug loc "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "local dispatch proceeds when ready"
assert_contains "$out" "needs_review" "reaches needs_review"

# bogus backend is refused up front
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" \
        bash "$ENGINE" dispatch --backend nope --check true "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "bogus backend refused"
assert_contains "$out" "codex|local" "lists valid backends"

ps_teardown_sandbox
ps_report; exit $?
```

Append to `tests/dispatch_backend_test.sh` (before `ps_teardown_sandbox`):

```bash
# --- --backend records the sidecar field ------------------------------------
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
( cd "$repo" && CODEX_DISPATCH_NOW=20260601T100000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$log" \
    bash "$ENGINE" dispatch --backend local --verify checks --check 'bash check.sh' --slug be "x" >/dev/null 2>&1 )
( cd "$repo"
  assert_eq "$(d_sc_get 20260601T100000Z-be '.backend')" "local" "sidecar records backend=local" )
( cd "$repo" && CODEX_DISPATCH_NOW=20260601T100100Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug df "x" >/dev/null 2>&1 )
( cd "$repo"
  assert_eq "$(d_sc_get 20260601T100100Z-df '.backend')" "codex" "default backend recorded as codex" )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/dispatch_local_preflight_test.sh && bash tests/dispatch_backend_test.sh`
Expected: FAIL — `unknown flag: --backend`.

- [ ] **Step 3: Source `lib/local.sh` in the engine**

In `codex_dispatch.sh`, after line 9 (`source "$HERE/lib/dispatch.sh"`) add:

```bash
source "$HERE/lib/local.sh"
```

- [ ] **Step 4: Add `--backend` to `cmd_dispatch`**

In `cmd_dispatch`, add the default and flag case (lines 61-73):

```bash
cmd_dispatch() {
  local verify=both retry=1 slug="" backend=codex
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify)  verify="$2"; shift 2;;
      --check)   checks+=("$2"); shift 2;;
      --retry)   retry="$2"; shift 2;;
      --slug)    slug="$2"; shift 2;;
      --backend) backend="$2"; shift 2;;
      --)        shift; break;;
      -*)        die "unknown flag: $1";;
      *)         break;;
    esac
  done
```

After the `--retry` integer guard (line 77) and `d_in_git_repo` check (line 78), add backend validation, the resolver, and the preflight:

```bash
  case "$backend" in codex|local) ;; *) die "invalid --backend: $backend (want codex|local)";; esac
  local bargs; bargs="$(d_backend_args "$backend")" || die "invalid --backend: $backend (want codex|local)"
  if [ "$backend" = local ]; then
    l_ready || die "local model not ready (state: $(l_probe)). Load it first:  codex_dispatch.sh local-up"
  fi
```

- [ ] **Step 5: Record `backend` in the sidecar and pass `bargs` to codex**

In the `jq -n` sidecar init (lines 102-109), add the arg and field:

```bash
  jq -n --arg id "$id" --arg now "$(d_now)" --arg repo "$repo" --arg wt "$wt" \
        --arg branch "$branch" --arg base "$base_ref" --arg verify "$verify" \
        --argjson retry "$retry" --argjson reqchecks "$checks_json" --arg prompt "$prompt" \
        --arg backend "$backend" \
    '{id:$id, created_at:$now, updated_at:$now, repo:$repo, worktree:$wt, branch:$branch,
      base_ref:$base, verify:$verify, retry_budget:$retry, retries_used:0,
      requested_checks:$reqchecks, session_id:null, status:"running",
      checks:[], touches_tests:false, codex_last_message:null, prompt:$prompt, backend:$backend}' \
    > "$(d_sidecar_path "$id")"
```

Change the exec call (line 114) to splice the backend args (unquoted `$bargs` so `-p local` word-splits; empty for codex):

```bash
  session="$(d_codex_exec "$wt" "$lastmsg" "$prompt" $bargs)"
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/dispatch_local_preflight_test.sh && bash tests/dispatch_backend_test.sh`
Expected: PASS both.

- [ ] **Step 7: Confirm no regressions**

Run: `bash tests/run.sh`
Expected: all pass (default `backend=codex`, empty `bargs` → unchanged behavior).

- [ ] **Step 8: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_local_preflight_test.sh tests/dispatch_backend_test.sh
git commit -m "feat(dispatch): --backend flag, sidecar field, local-readiness preflight (C.1)"
```

---

## Task 6: Carry the backend through retries and `resume`

**Files:**
- Modify: `codex_dispatch.sh` (`finish_verify` retry resume; `cmd_resume`)
- Modify: `tests/dispatch_backend_test.sh` (append resume-with-backend assertion)

- [ ] **Step 1: Write the failing test**

Append to `tests/dispatch_backend_test.sh` (before `ps_teardown_sandbox`):

```bash
# --- retries keep the backend flag (resume must also carry -p local) --------
: > "$log"
( cd "$repo" && CODEX_DISPATCH_NOW=20260601T110000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$log" FAKE_CODEX_BEHAVIOR=fail \
    bash "$ENGINE" dispatch --backend local --verify checks --check 'bash check.sh' --retry 1 --slug rty "x" >/dev/null 2>&1 )
# the retry path calls `codex exec resume ... -p local`; assert a resume line carries the flag
assert_contains "$(grep resume "$log" || true)" "-p local" "retry resume carries backend flag"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/dispatch_backend_test.sh`
Expected: FAIL — the resume line lacks `-p local` (retry resume passes no backend args yet).

- [ ] **Step 3: Resolve backend inside `finish_verify`**

In `finish_verify` (lines 135-181), after the locals are read (after line 153 `slug="$(d_sc_get "$id" '.id')"`), add backend resolution:

```bash
  local backend bargs
  backend="$(d_sc_get "$id" '.backend')"; [ -n "$backend" ] || backend=codex
  bargs="$(d_backend_args "$backend")" || bargs=""
```

Change the resume call inside the retry loop (line 176) to pass `$bargs`:

```bash
    d_codex_resume "$wt" "$session" "$fb" $bargs
```

- [ ] **Step 4: Carry the backend through `cmd_resume` too**

In `cmd_resume` (lines 185-217), after the locals (after line 200 `verify="$(d_sc_get "$id" '.verify')"`), add:

```bash
  local backend bargs
  backend="$(d_sc_get "$id" '.backend')"; [ -n "$backend" ] || backend=codex
  bargs="$(d_backend_args "$backend")" || bargs=""
```

Change the resume call (line 203) to:

```bash
  d_codex_resume "$wt" "$session" "$fb" $bargs
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/dispatch_backend_test.sh`
Expected: PASS.

- [ ] **Step 6: Confirm no regressions**

Run: `bash tests/run.sh`
Expected: all pass (codex backend → empty `bargs`; existing resume/verify tests unaffected).

- [ ] **Step 7: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_backend_test.sh
git commit -m "feat(dispatch): carry backend flag through retry + resume (C.1)"
```

---

## Task 7: `quick --backend` — flag + preflight

**Files:**
- Modify: `codex_dispatch.sh` (`cmd_quick`)
- Modify: `tests/dispatch_local_preflight_test.sh` (append quick assertions)

- [ ] **Step 1: Write the failing test**

Append to `tests/dispatch_local_preflight_test.sh` (before `ps_teardown_sandbox`):

```bash
# --- quick --backend local: preflight + in-place edit -----------------------
repo2="$(ps_make_sandbox_repo repo2)"
# refused when not ready
out="$( cd "$repo2" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=unreachable \
        bash "$ENGINE" quick --backend local "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "quick local refused when not ready"
assert_contains "$out" "local-up" "quick refusal names the fix"
# proceeds when ready, edits in place, splices -p local
qlog="$PS_SANDBOX/qargv.log"; : > "$qlog"
out="$( cd "$repo2" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=ready \
        FAKE_CODEX_ARGV_LOG="$qlog" bash "$ENGINE" quick --backend local "small fix" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "quick local proceeds when ready"
assert_eq "$(cat "$repo2/IMPL")" "ok" "quick local wrote change in place"
assert_contains "$(cat "$qlog")" "-p local" "quick local splices backend flag"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/dispatch_local_preflight_test.sh`
Expected: FAIL — `unknown flag: --backend` (in `cmd_quick`).

- [ ] **Step 3: Add `--backend` + preflight to `cmd_quick`**

In `cmd_quick` (lines 341-399), add the default and flag case:

```bash
cmd_quick() {
  local verify=none snapshot=0 backend=codex
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify)   verify="$2"; shift 2;;
      --check)    checks+=("$2"); shift 2;;
      --snapshot) snapshot=1; shift;;
      --backend)  backend="$2"; shift 2;;
      --) shift; break;;
      -*) die "unknown flag: $1";;
      *) break;;
    esac
  done
```

After the `verify` validation and `d_in_git_repo` check (after line 357), add backend handling:

```bash
  case "$backend" in codex|local) ;; *) die "invalid --backend: $backend (want codex|local)";; esac
  local bargs; bargs="$(d_backend_args "$backend")" || die "invalid --backend: $backend (want codex|local)"
  if [ "$backend" = local ]; then
    l_ready || die "local model not ready (state: $(l_probe)). Load it first:  codex_dispatch.sh local-up"
  fi
```

Change the exec call (line 374) to splice `bargs`:

```bash
  session="$(d_codex_exec "$repo" "$lastmsg" "$prompt" $bargs)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/dispatch_local_preflight_test.sh`
Expected: PASS.

- [ ] **Step 5: Confirm no regressions**

Run: `bash tests/run.sh`
Expected: all pass (existing quick test uses default backend).

- [ ] **Step 6: Commit**

```bash
git add codex_dispatch.sh tests/dispatch_local_preflight_test.sh
git commit -m "feat(quick): --backend flag + local-readiness preflight (C.1)"
```

---

## Task 8: `local-up`/`local-down` subcommands, `doctor` line, backend in `show`/`list`

**Files:**
- Modify: `codex_dispatch.sh` (`main` routing; `cmd_doctor`; `emit_result`; `cmd_list`)
- Modify: `tests/dispatch_doctor_test.sh` (assert local-state line)
- Modify: `tests/local_lifecycle_test.sh` (assert subcommands route)

- [ ] **Step 1: Write the failing tests**

Append to `tests/local_lifecycle_test.sh` (before `ps_teardown_sandbox`):

```bash
# --- engine subcommands route to the helpers --------------------------------
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fssh2="$(ps_make_fake_ssh)"; slog2="$PS_SANDBOX/ssh2.log"; : > "$slog2"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh2" FAKE_SSH_LOG="$slog2" \
        CODEX_DISPATCH_LOCAL_UP_CMD='UPMARK' CODEX_DISPATCH_FAKE_STATE=ready \
        bash "$ENGINE" local-up 2>&1 )"; rc=$?
assert_eq "$rc" "0" "local-up subcommand exits 0"
assert_contains "$(cat "$slog2")" "UPMARK" "local-up subcommand runs up cmd"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh2" FAKE_SSH_LOG="$slog2" \
        bash "$ENGINE" local-down 2>&1 )"; rc=$?
assert_eq "$rc" "0" "local-down subcommand exits 0"
assert_contains "$(cat "$slog2")" "docker compose stop" "local-down subcommand stops container"
```

In `tests/dispatch_doctor_test.sh`, change the doctor invocation (line 23) to pin a fake state:

```bash
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        bash "$ENGINE" doctor 2>&1 )"; rc=$?
```
and add after line 26:
```bash
assert_contains "$out" "local backend: up-not-loaded" "doctor reports local model state"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/local_lifecycle_test.sh && bash tests/dispatch_doctor_test.sh`
Expected: FAIL — `unknown subcommand: local-up`; doctor missing the local-state line.

- [ ] **Step 3: Route the new subcommands in `main`**

In `main` (lines 446-459), add two cases before `*)`:

```bash
    quick)      cmd_quick "$@" ;;
    doctor)     cmd_doctor "$@" ;;
    local-up)   l_up "$@" ;;
    local-down) l_down "$@" ;;
    *)          die "unknown subcommand: $sub" ;;
```

- [ ] **Step 4: Add the local-state line to `cmd_doctor`**

In `cmd_doctor`, after the codex-version line (line 407 `echo "  codex version: $ver"`), add:

```bash
  echo "  local backend: $(l_probe)  (endpoint $(l_endpoint))"
```

- [ ] **Step 5: Surface backend in `emit_result` and `cmd_list`**

In `emit_result`, after the `verify:` line (line 48), add a backend line:

```bash
  local be; be="$(d_sc_get "$id" '.backend')"; [ -n "$be" ] || be="codex"
  echo "  backend:  $be"
```

In `cmd_list`, add a BACKEND column. Change the header (line 437) and row (lines 441-442):

```bash
  printf '  %-26s %-13s %-8s %-7s %s\n' "ID" "STATUS" "VERIFY" "BACKEND" "BRANCH"
  local id be
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    be="$(d_sc_get "$id" '.backend')"; [ -n "$be" ] || be="codex"
    printf '  %-26s %-13s %-8s %-7s %s\n' \
      "$id" "$(d_sc_get "$id" '.status')" "$(d_sc_get "$id" '.verify')" "$be" "$(d_sc_get "$id" '.branch')"
  done <<< "$ids"
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/local_lifecycle_test.sh && bash tests/dispatch_doctor_test.sh && bash tests/dispatch_show_list_test.sh`
Expected: PASS all three (the list test only asserts id/status substrings).

- [ ] **Step 7: Confirm no regressions**

Run: `bash tests/run.sh`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add codex_dispatch.sh tests/local_lifecycle_test.sh tests/dispatch_doctor_test.sh
git commit -m "feat(dispatch): local-up/down subcommands, doctor state, backend in show/list (C.1)"
```

---

## Task 9: `install.sh` writes the codex profile

**Files:**
- Modify: `install.sh` (new idempotent step 6)
- Modify: `tests/install_test.sh` (sandbox `CODEX_HOME`; assert profile)

- [ ] **Step 1: Write the failing test**

In `tests/install_test.sh`, immediately after `ps_setup_sandbox` (line 4), pin a sandbox `CODEX_HOME` so no real `~/.codex` is touched:

```bash
export CODEX_HOME="$CC_PROFILE_ROOT/dot-codex"
```

Add assertions after the first install succeeds (after line 15):

```bash
# C.1: local-backend codex profile written, with provider + model + endpoint
PROF="$CODEX_HOME/local.config.toml"
assert_file "$PROF" "local codex profile written"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'model_provider = "llamacpp"' "profile declares llamacpp provider"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'wire_api = "chat"' "profile uses chat wire_api"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'qwen36-35b' "profile defaults to the qwen36-35b alias"
# idempotent + non-clobbering: user edit survives a re-run
printf '\n# user edit\n' >> "$PROF"
CCP_SKIP_PATH=1 CODEX_HOME="$CODEX_HOME" CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
assert_contains "$(cat "$PROF")" "# user edit" "existing profile left untouched on re-run"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/install_test.sh`
Expected: FAIL — `local codex profile written: missing [.../local.config.toml]`.

- [ ] **Step 3: Add step 6 to `install.sh`**

After the ccp PATH block (after line 49, before the final `echo "Done...."`), add:

```bash
# 6. Codex profile for the local-model dispatch backend (C.1) — idempotent,
#    non-clobbering. Lives under $CODEX_HOME so `codex -p local` picks it up.
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
LOCAL_PROFILE="$CODEX_HOME_DIR/${CODEX_DISPATCH_LOCAL_PROFILE:-local}.config.toml"
if [ -e "$LOCAL_PROFILE" ]; then
  echo "  local-backend codex profile exists: $LOCAL_PROFILE (left untouched)"
else
  mkdir -p "$CODEX_HOME_DIR"
  cat > "$LOCAL_PROFILE" <<TOML
# Codex profile for the C.1 local dispatch backend (llama.cpp router on the workstation).
# Selected by:  codex -p ${CODEX_DISPATCH_LOCAL_PROFILE:-local}   (via --backend local).
# 'model' must match the alias your router advertises at /v1/models (verify it).
model          = "${CODEX_DISPATCH_LOCAL_MODEL:-qwen36-35b}"
model_provider = "llamacpp"

[model_providers.llamacpp]
name     = "llama.cpp (workstation)"
base_url = "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://100.64.0.4:8080/v1}"
wire_api = "chat"
env_key  = "LLAMACPP_API_KEY"
TOML
  echo "  wrote local-backend codex profile: $LOCAL_PROFILE"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/install_test.sh`
Expected: PASS.

- [ ] **Step 5: Confirm no regressions**

Run: `bash tests/run.sh`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/install_test.sh
git commit -m "feat(install): write local-backend codex profile idempotently (C.1)"
```

---

## Task 10: Skill routing guidance

**Files:**
- Modify: `skills/codex-implement/SKILL.md`

No automated test (prose). Verified by reading; the engine enforces the actual guardrails.

- [ ] **Step 1: Add a backend table to `## 1. Decide the shape`**

After the first table (the `| Situation | Command |` block ending at the `quick` row, line 22), add:

```markdown

| Backend (`--backend`) | When |
|---|---|
| `codex` (default) | Impactful work, large diffs, anything beyond the local model's context budget. |
| `local` | Quick / low-stakes / mechanical edits, or working without the cloud. Run `local-up` first; prefer `--retry 0`. Pair with `quick` (in-place) or `dispatch` (isolated). |
```

- [ ] **Step 2: Add the local lifecycle note after the dispatch section**

After `## 2. Dispatch` (after line 40), add:

```markdown
**Local backend:** before `--backend local`, load the model — `codex_dispatch.sh local-up`
(switches to the qwen36-only preset over SSH, then waits for `ready`) / `local-down` (stops the
container, freeing VRAM). The engine **refuses** local dispatch when the model isn't loaded and
prints the `local-up` command. `doctor` shows the live state (`unreachable | up-not-loaded | ready`).
```

- [ ] **Step 3: Add one red-flag row (table stays ≤7)**

In `## Red flags`, add a fourth row:

```markdown
| "I'll route this big/impactful change to `--backend local`" | Local is for quick/low-stakes work within its context budget. Impactful or large-context → default `codex`. |
```

- [ ] **Step 4: Add a checklist item**

In `## Checklist`, add as the new first item:

```markdown
- [ ] Pick backend (`codex` default; `local` for quick/low-stakes — run `local-up` first)
```

- [ ] **Step 5: Verify the table cap and read the result**

Run: `grep -n '^|' skills/codex-implement/SKILL.md` and re-read the Red flags section to confirm it has ≤7 data rows (now 4).

- [ ] **Step 6: Commit**

```bash
git add skills/codex-implement/SKILL.md
git commit -m "docs(skill): backend routing guidance + local lifecycle note (C.1)"
```

---

## Task 11: Full-suite green + manual smoke checklist

**Files:**
- Create: `docs/2026-06-01-c1-local-backend-smoke.md`

- [ ] **Step 1: Run the entire suite**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===` with N = 23 (20 prior + 3 new: `dispatch_backend`, `local_lifecycle`, `dispatch_local_preflight`). Zero failures.

- [ ] **Step 2: Write the manual smoke checklist**

Create `docs/2026-06-01-c1-local-backend-smoke.md`:

```markdown
# C.1 Local-Model Backend — Manual Smoke Checklist

The pure-bash tests prove orchestration with a fake codex/ssh/curl; they do NOT exercise real
inference. Run this once on the real workstation path. Prereqs: headscale up
(`ssh greg-campisi@100.64.0.4` works); llama.cpp router container present; the `qwen36-only`
preset exists (`~/docker/llama/presets/qwen36-only.ini`).

First verify the alias and (if different) export overrides:
```
ssh greg-campisi@100.64.0.4 'curl -s localhost:8080/v1/models' | jq -r '.data[].id'   # confirm "qwen36-35b"
# only if different from the defaults baked into install.sh / lib/local.sh:
export CODEX_DISPATCH_LOCAL_MODEL="<alias>"
export CODEX_DISPATCH_LOCAL_UP_CMD="<remote preset-switch cmd>"
export CODEX_DISPATCH_LOCAL_DOWN_CMD="<remote stop cmd>"
```

- [ ] `install.sh` wrote `~/.codex/local.config.toml`; its `model` matches the `/v1/models` alias.
- [ ] `codex_dispatch.sh doctor` reports `local backend: up-not-loaded` (or `unreachable`) before loading.
- [ ] `codex_dispatch.sh local-up` runs the preset switch and reaches `model ready.` (allow 30–90s).
- [ ] `doctor` now reports `local backend: ready`.
- [ ] **Tool-call fidelity (R8 — thinking model):** in a scratch git repo,
      `codex_dispatch.sh dispatch --backend local --verify both --check '<cmd>' "<small task>"`
      creates a worktree and the Qwen model produces a REAL diff (codex's tool calls weren't broken
      by `<think>` output). If the diff is empty / codex stalls, see R8 in the spec.
- [ ] `show <id> --diff` shows the diff; `resume <id> "<fb>"` continues the SAME session (context retained).
- [ ] `land <id>` merges and removes the worktree.
- [ ] `codex_dispatch.sh quick --backend local "<trivial in-place edit>"` edits the working tree directly.
- [ ] With the model not loaded, `dispatch --backend local …` REFUSES with the `local-up` hint.
- [ ] `local-down` stops the container; `nvidia-smi` (or `llama_vram`) confirms VRAM freed.
```

- [ ] **Step 3: Commit**

```bash
git add docs/2026-06-01-c1-local-backend-smoke.md
git commit -m "docs: C.1 local-backend manual smoke checklist"
```

---

## Self-Review

**Spec coverage (L1–L7, §5, §10 addendum, acceptance criteria):**
- L1 resolver + seam → Tasks 1, 2. L3 default codex unchanged → regression run in every task + Task 5/6 default-backend assertions. L4 codex runs locally → inherent. L5 direct tailnet URL → profile in Task 9. L6 lifecycle helper → Tasks 3, 4, 8. L7 routing in skill → Task 10.
- §10 addendum: router-mode status-parse probe → Task 3 (fake-curl JSON test); qwen36-only preset `l_up` + HTTP preload → Task 4; `qwen36-35b` alias → Tasks 3, 4, 9; stop-container `l_down` → Task 4; R8 thinking-model → Task 11 smoke.
- Acceptance criteria 1–9 each map to a test: (1) Task 5 argv+sidecar; (2) Task 5/6 default; (3) Task 7 quick; (4) Task 5/7 preflight; (5) Tasks 4/8 lifecycle; (6) Task 8 doctor; (7) Task 5 bogus backend; (8) Task 9 install; (9) Task 11 full suite.

**Placeholder scan:** none — every step carries complete code/commands and expected output. The only intentionally user-supplied value is the model alias, baked as the informed default `qwen36-35b` and verified in Task 11's smoke checklist (matching the spec's "pending verification").

**Type/name consistency:** `d_backend_args`, `l_endpoint`/`l_model`/`l_ssh_tgt`/`l_up_cmd`/`l_down_cmd`, `l_probe`/`l_ready`/`l_preload`/`l_up`/`l_down`, sidecar field `backend`, env `CODEX_DISPATCH_FAKE_STATE`/`_SSH_BIN`/`_CURL_BIN`/`_LOCAL_*`/`_POLL_*`, and fake-double vars `FAKE_CODEX_ARGV_LOG`/`FAKE_SSH_LOG`/`FAKE_SSH_RC`/`FAKE_QWEN_STATUS`/`FAKE_CURL_RC` are used identically across all tasks. `$bargs` is always expanded unquoted to word-split `-p local`.

**Note on test count:** Task 11 expects 23 files (3 new). If `tests/` already differs, trust the `run.sh` summary over the literal number.

# Codex Dispatch — Local-Model Backend (C.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second dispatch backend — codex's agentic harness pointed at a quantized coding model on the user's Docker/llama.cpp workstation (reached over a headscale tailnet) — selectable per-dispatch via `--backend codex|local`, alongside (and for quick tasks instead of) the default codex-cloud backend.

**Architecture:** Subsystem C already isolated codex behind three functions in `lib/dispatch.sh`. C.1 is purely additive: a one-line `d_backend_args` resolver maps `--backend local` to a codex profile flag (`-p local`); that flag is threaded through the existing `d_codex_exec`/`d_codex_resume` calls; a new `lib/local.sh` manages the remote model lifecycle (probe / up / down) over SSH; and a readiness preflight refuses local dispatch when the model isn't loaded. No C land/verify/abandon/sidecar logic is rewritten. The repo never leaves the Mac — only inference HTTP crosses the tailnet.

**Tech Stack:** Pure bash (no bats), `jq`, the C dependency-free test harness (`tests/lib.sh` + `tests/run.sh`), codex 0.135 profiles (`-p`/`$CODEX_HOME/<name>.config.toml`), llama.cpp OpenAI-compatible `/v1` endpoint.

**Spec:** `docs/specs/2026-05-31-codex-dispatch-local-backend-design.md` (decisions L1–L7).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `lib/dispatch.sh` | Backend resolver `d_backend_args`; thread extra args through `d_codex_exec`/`d_codex_resume`. | Modify |
| `lib/local.sh` | Remote model lifecycle: `l_probe`, `l_ready`, `l_up`, `l_down`. **New, focused file.** | Create |
| `codex_dispatch.sh` | `--backend` flag on `dispatch`/`quick`; sidecar `backend` field; local-readiness preflight; `local-up`/`local-down` subcommands; `doctor` local-state line; backend surfaced in `show`/`list`. | Modify |
| `install.sh` | Idempotently write `$CODEX_HOME/local.config.toml` (the llama.cpp codex profile). | Modify |
| `skills/codex-implement/SKILL.md` | Backend routing guidance (decision table column + one red-flag + checklist note). | Modify |
| `tests/lib.sh` | Test doubles: argv-logging fake codex; `ps_make_fake_ssh`. | Modify |
| `tests/dispatch_backend_test.sh` | Resolver + arg threading + `--backend` flag + sidecar field + bogus backend + resume-with-backend. | Create |
| `tests/local_lifecycle_test.sh` | `l_probe`/`l_ready`/`l_up`/`l_down` via `CODEX_DISPATCH_FAKE_STATE` + fake ssh. | Create |
| `tests/dispatch_local_preflight_test.sh` | `dispatch`/`quick --backend local` refuse when not ready, proceed when ready. | Create |
| `tests/dispatch_doctor_test.sh` | Assert the new local-state line. | Modify |
| `tests/install_test.sh` | Sandbox `CODEX_HOME`; assert profile written + idempotent. | Modify |
| `docs/2026-06-01-c1-local-backend-smoke.md` | Manual real-workstation smoke checklist. | Create |

**Test-injection seams (all `CODEX_DISPATCH_*`, matching C's `CODEX_DISPATCH_CODEX_BIN`/`_NOW` convention):**
- `CODEX_DISPATCH_FAKE_STATE` — short-circuits `l_probe` to a literal state (`unreachable|up-not-loaded|ready`); avoids real network.
- `CODEX_DISPATCH_SSH_BIN` / `CODEX_DISPATCH_CURL_BIN` — override `ssh`/`curl` bins.
- `FAKE_CODEX_ARGV_LOG` (on the fake codex) — append each invocation's argv to a file.
- `FAKE_SSH_LOG` / `FAKE_SSH_RC` (on the fake ssh) — record remote command / force exit code.
- `CODEX_DISPATCH_LOCAL_POLL_INTERVAL` / `_TIMEOUT` — keep `l_up` polling fast in tests.

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

## Task 3: Remote model probe — `lib/local.sh` (`l_probe`/`l_ready`)

**Files:**
- Create: `lib/local.sh`
- Create: `tests/local_lifecycle_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/local_lifecycle_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/local.sh"

# l_probe honors the test override (no real network)
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=ready          l_probe)" "ready"         "probe: ready"
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=up-not-loaded  l_probe)" "up-not-loaded" "probe: up-not-loaded"
assert_eq "$(CODEX_DISPATCH_FAKE_STATE=unreachable    l_probe)" "unreachable"   "probe: unreachable"

# l_ready is 0 iff probe==ready
( CODEX_DISPATCH_FAKE_STATE=ready         l_ready ); assert_eq "$?" "0" "ready -> l_ready 0"
( CODEX_DISPATCH_FAKE_STATE=up-not-loaded l_ready ); assert_eq "$?" "1" "not-loaded -> l_ready 1"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/local_lifecycle_test.sh`
Expected: FAIL — `lib/local.sh` does not exist (source error).

- [ ] **Step 3: Create `lib/local.sh` with the probe**

```bash
#!/usr/bin/env bash
# lib/local.sh — remote model lifecycle for the local dispatch backend (C.1).
# SOURCE this. All network/ssh calls go through injectable bins so tests stub them.
# Defaults target the headscale workstation; override via CODEX_DISPATCH_LOCAL_* env.

l_endpoint() { printf '%s' "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://100.64.0.4:8080/v1}"; }
l_model()    { printf '%s' "${CODEX_DISPATCH_LOCAL_MODEL:-qwen3-35b-a3b-ud-q6_k_xl}"; }
l_ssh_tgt()  { printf '%s' "${CODEX_DISPATCH_LOCAL_SSH:-greg-campisi@100.64.0.4}"; }

# l_probe -> echoes exactly one of: unreachable | up-not-loaded | ready
#   CODEX_DISPATCH_FAKE_STATE short-circuits to a literal (test seam).
l_probe() {
  if [ -n "${CODEX_DISPATCH_FAKE_STATE:-}" ]; then
    printf '%s\n' "$CODEX_DISPATCH_FAKE_STATE"; return 0
  fi
  local curl_bin body
  curl_bin="${CODEX_DISPATCH_CURL_BIN:-curl}"
  # NOTE: no -f — a 503 (server up, model not loaded) must NOT read as unreachable.
  body="$("$curl_bin" -sS -m "${CODEX_DISPATCH_LOCAL_HTTP_TIMEOUT:-4}" "$(l_endpoint)/models" 2>/dev/null)" \
    || { printf 'unreachable\n'; return 0; }
  case "$body" in
    *"\"$(l_model)\""*) printf 'ready\n' ;;
    *)                  printf 'up-not-loaded\n' ;;
  esac
}

# l_ready -> 0 iff the configured model is loaded and serving.
l_ready() { [ "$(l_probe)" = ready ]; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/local_lifecycle_test.sh`
Expected: PASS — `(5 checks, 0 failed)`.

- [ ] **Step 5: Commit**

```bash
git add lib/local.sh tests/local_lifecycle_test.sh
git commit -m "feat(local): l_probe/l_ready three-state readiness check (C.1)"
```

---

## Task 4: Remote load/unload — `l_up`/`l_down`

**Files:**
- Modify: `lib/local.sh` (append `l_up`, `l_down`)
- Modify: `tests/local_lifecycle_test.sh` (append lifecycle assertions)

- [ ] **Step 1: Write the failing test**

Append to `tests/local_lifecycle_test.sh`, before `ps_teardown_sandbox`:

```bash
# --- l_up / l_down via fake ssh --------------------------------------------
fssh="$(ps_make_fake_ssh)"
sshlog="$PS_SANDBOX/ssh.log"; : > "$sshlog"

# l_up: runs the remote load command, then polls to readiness (fake=ready -> instant)
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" \
        CODEX_DISPATCH_LOCAL_UP_CMD='docker start llama' CODEX_DISPATCH_FAKE_STATE=ready \
        l_up 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_up succeeds when model becomes ready"
assert_contains "$out" "ready" "l_up reports readiness"
assert_contains "$(cat "$sshlog")" "docker start llama" "l_up ran the remote load command"

# l_up: missing UP_CMD is an error, no ssh call
: > "$sshlog"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" l_up 2>&1 )"; rc=$?
assert_eq "$rc" "1" "l_up errors without UP_CMD"
assert_eq "$(cat "$sshlog")" "" "l_up made no ssh call without UP_CMD"

# l_up: stays not-loaded -> times out (fast via tiny interval/timeout)
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" CODEX_DISPATCH_LOCAL_UP_CMD='docker start llama' \
        CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        CODEX_DISPATCH_LOCAL_POLL_INTERVAL=1 CODEX_DISPATCH_LOCAL_POLL_TIMEOUT=1 l_up 2>&1 )"; rc=$?
assert_eq "$rc" "1" "l_up times out when never ready"
assert_contains "$out" "timed out" "l_up explains the timeout"

# l_down: runs the unload command
: > "$sshlog"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" \
        CODEX_DISPATCH_LOCAL_DOWN_CMD='docker stop llama' l_down 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_down succeeds"
assert_contains "$(cat "$sshlog")" "docker stop llama" "l_down ran the remote unload command"

# l_down: unset DOWN_CMD is a no-op success, no ssh call
: > "$sshlog"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh" FAKE_SSH_LOG="$sshlog" l_down 2>&1 )"; rc=$?
assert_eq "$rc" "0" "l_down no-ops without DOWN_CMD"
assert_eq "$(cat "$sshlog")" "" "l_down made no ssh call without DOWN_CMD"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/local_lifecycle_test.sh`
Expected: FAIL — `l_up: command not found`.

- [ ] **Step 3: Append `l_up`/`l_down` to `lib/local.sh`**

```bash
# l_up -> run the remote model-load command, then poll until ready (or timeout).
# The load command MUST be idempotent (e.g. `docker start` on a running container
# is a no-op) since l_up always runs it.
l_up() {
  local up_cmd ssh_bin interval timeout waited
  up_cmd="${CODEX_DISPATCH_LOCAL_UP_CMD:-}"
  if [ -z "$up_cmd" ]; then
    echo "local-up: set CODEX_DISPATCH_LOCAL_UP_CMD to your remote model-load command (Docker-based on this station)" >&2
    return 1
  fi
  ssh_bin="${CODEX_DISPATCH_SSH_BIN:-ssh}"
  echo "local-up: loading '$(l_model)' on $(l_ssh_tgt) ..."
  "$ssh_bin" "$(l_ssh_tgt)" "$up_cmd" || { echo "local-up: remote load command failed" >&2; return 1; }
  interval="${CODEX_DISPATCH_LOCAL_POLL_INTERVAL:-3}"
  timeout="${CODEX_DISPATCH_LOCAL_POLL_TIMEOUT:-180}"
  waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if l_ready; then echo "local-up: model ready."; return 0; fi
    sleep "$interval"; waited=$((waited + interval))
  done
  echo "local-up: timed out after ${timeout}s waiting for readiness (state: $(l_probe))" >&2
  return 1
}

# l_down -> run the remote unload command to free VRAM. Best-effort; unset = no-op.
l_down() {
  local down_cmd ssh_bin
  down_cmd="${CODEX_DISPATCH_LOCAL_DOWN_CMD:-}"
  if [ -z "$down_cmd" ]; then
    echo "local-down: CODEX_DISPATCH_LOCAL_DOWN_CMD unset — nothing to do." >&2
    return 0
  fi
  ssh_bin="${CODEX_DISPATCH_SSH_BIN:-ssh}"
  if "$ssh_bin" "$(l_ssh_tgt)" "$down_cmd"; then
    echo "local-down: unload command sent."
  else
    echo "local-down: remote unload failed" >&2; return 1
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/local_lifecycle_test.sh`
Expected: PASS (the timeout case takes ~1s).

- [ ] **Step 5: Commit**

```bash
git add lib/local.sh tests/local_lifecycle_test.sh
git commit -m "feat(local): l_up/l_down remote model lifecycle over ssh (C.1)"
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

In `cmd_dispatch`, add the default and flag case. Change the flag block top (lines 61-73) so the locals and `case` include backend:

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

After the existing `--retry` integer guard (line 77) and `d_in_git_repo` check (line 78), add backend validation, the resolver, and the preflight:

```bash
  case "$backend" in codex|local) ;; *) die "invalid --backend: $backend (want codex|local)";; esac
  local bargs; bargs="$(d_backend_args "$backend")" || die "invalid --backend: $backend (want codex|local)"
  if [ "$backend" = local ]; then
    l_ready || die "local model not ready (state: $(l_probe)). Load it first:  codex_dispatch.sh local-up"
  fi
```

- [ ] **Step 5: Record `backend` in the sidecar and pass `bargs` to codex**

In the `jq -n` sidecar init (lines 102-109), add the arg and field. Change the `--arg prompt "$prompt" \` line and the object body to include backend:

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

Change the exec call (line 114) to splice the backend args (note: unquoted `$bargs` so `-p local` word-splits; empty for codex):

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
        CODEX_DISPATCH_LOCAL_UP_CMD='docker start llama' CODEX_DISPATCH_FAKE_STATE=ready \
        bash "$ENGINE" local-up 2>&1 )"; rc=$?
assert_eq "$rc" "0" "local-up subcommand exits 0"
assert_contains "$(cat "$slog2")" "docker start llama" "local-up subcommand runs load cmd"
out="$( CODEX_DISPATCH_SSH_BIN="$fssh2" FAKE_SSH_LOG="$slog2" \
        CODEX_DISPATCH_LOCAL_DOWN_CMD='docker stop llama' bash "$ENGINE" local-down 2>&1 )"; rc=$?
assert_eq "$rc" "0" "local-down subcommand exits 0"
```

In `tests/dispatch_doctor_test.sh`, change the doctor invocation (line 23) to pin a fake state, and add an assertion after line 26:

```bash
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        bash "$ENGINE" doctor 2>&1 )"; rc=$?
```
add:
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
# C.1: local-backend codex profile written, with model + endpoint
PROF="$CODEX_HOME/local.config.toml"
assert_file "$PROF" "local codex profile written"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'model_provider = "llamacpp"' "profile declares llamacpp provider"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'wire_api = "chat"' "profile uses chat wire_api"
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
# Codex profile for the C.1 local dispatch backend (llama.cpp on the workstation).
# Selected by:  codex -p ${CODEX_DISPATCH_LOCAL_PROFILE:-local}   (via --backend local).
# Verify 'model' matches the id your llama-server advertises at /v1/models.
model          = "${CODEX_DISPATCH_LOCAL_MODEL:-qwen3-35b-a3b-ud-q6_k_xl}"
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

- [ ] **Step 1: Add a backend row to the command decision table**

In `## 1. Decide the shape`, after the first table (the `| Situation | Command |` block ending at the `quick` row, line 22), add a backend table:

```markdown

| Backend (`--backend`) | When |
|---|---|
| `codex` (default) | Impactful work, large diffs, anything beyond the local model's context budget. |
| `local` | Quick / low-stakes / mechanical edits, or working without the cloud. Run `local-up` first; prefer `--retry 0`. Pair with `quick` (in-place) or `dispatch` (isolated). |
```

- [ ] **Step 2: Add the local lifecycle note after the dispatch section**

After `## 2. Dispatch` (after line 40), add:

```markdown
**Local backend:** before `--backend local`, ensure the model is loaded — `codex_dispatch.sh local-up`
(load) / `local-down` (free VRAM). The engine **refuses** local dispatch when the model isn't ready
and prints the `local-up` command. `doctor` shows the live state (`unreachable | up-not-loaded | ready`).
```

- [ ] **Step 3: Add one red-flag row (table stays ≤7)**

In `## Red flags`, add a fourth row (current count 3 → 4, within the cap):

```markdown
| "I'll route this big/impactful change to `--backend local`" | Local is for quick/low-stakes work within its context budget. Impactful or large-context → default `codex`. |
```

- [ ] **Step 4: Add a checklist item**

In `## Checklist`, add as the new first item:

```markdown
- [ ] Pick backend (`codex` default; `local` for quick/low-stakes — run `local-up` first)
```

- [ ] **Step 5: Verify the table cap and read the result**

Run: `grep -c '^|' skills/codex-implement/SKILL.md` and re-read the Red flags section to confirm it has ≤7 data rows.
Expected: the Red flags table has 4 data rows (+1 header +1 separator).

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

The pure-bash tests prove orchestration with a fake codex/ssh; they do NOT exercise real
inference. Run this once on the real workstation path. Prereqs: headscale up
(`ssh greg-campisi@100.64.0.4` works), llama.cpp Docker container available.

Set your real knobs first (the Docker load/unload commands are pending verification):
```
export CODEX_DISPATCH_LOCAL_MODEL="<id from GET 100.64.0.4:8080/v1/models>"
export CODEX_DISPATCH_LOCAL_UP_CMD="<docker start ...>"
export CODEX_DISPATCH_LOCAL_DOWN_CMD="<docker stop ...>"
```

- [ ] `install.sh` wrote `~/.codex/local.config.toml`; its `model` matches the `/v1/models` id.
- [ ] `codex_dispatch.sh doctor` reports `local backend: up-not-loaded` before loading.
- [ ] `codex_dispatch.sh local-up` runs the Docker load command and reaches `model ready.`
- [ ] `doctor` now reports `local backend: ready`.
- [ ] In a scratch git repo: `codex_dispatch.sh dispatch --backend local --verify both --check '<cmd>' "<small task>"`
      creates a worktree, the Qwen model produces a real diff, and it stops at `needs_review`.
- [ ] `show <id> --diff` shows the diff; `resume <id> "<fb>"` continues the SAME session (context retained).
- [ ] `land <id>` merges and removes the worktree.
- [ ] `codex_dispatch.sh quick --backend local "<trivial in-place edit>"` edits the working tree directly.
- [ ] With the model unloaded, `dispatch --backend local …` REFUSES with the `local-up` hint.
- [ ] `local-down` frees VRAM (confirm on the workstation).
```

- [ ] **Step 3: Commit**

```bash
git add docs/2026-06-01-c1-local-backend-smoke.md
git commit -m "docs: C.1 local-backend manual smoke checklist"
```

---

## Self-Review

**Spec coverage (L1–L7, §5, acceptance criteria):**
- L1 resolver + seam → Tasks 1, 2. L3 default codex unchanged → regression steps in every task + Task 5/6 default-backend assertions. L4 codex runs locally → inherent (worktree path untouched). L5 direct tailnet URL → profile in Task 9. L6 lifecycle helper → Tasks 3, 4, 8. L7 routing in skill → Task 10.
- §5.4 `--backend`/sidecar/emit/list/preflight/subcommands/doctor → Tasks 5, 7, 8. §5.5 `l_probe/l_ready/l_up/l_down` → Tasks 3, 4. §5.2 profile artifact → Task 9.
- Acceptance criteria 1–9 each map to a test: (1) Task 5 argv+sidecar; (2) Task 5/6 default; (3) Task 7 quick; (4) Task 5/7 preflight; (5) Tasks 4/8 lifecycle; (6) Task 8 doctor; (7) Task 5 bogus backend; (8) Task 9 install; (9) Task 11 full suite.

**Placeholder scan:** none — every step carries complete code/commands and expected output. The only intentionally user-supplied values are the Docker `UP_CMD`/`DOWN_CMD` and the verified model id, which are env knobs surfaced in Task 11's smoke checklist (matching the spec's "pending verification").

**Type/name consistency:** `d_backend_args`, `l_probe`, `l_ready`, `l_up`, `l_down`, `l_endpoint`, `l_model`, `l_ssh_tgt`, sidecar field `backend`, env `CODEX_DISPATCH_FAKE_STATE`/`_SSH_BIN`/`_CURL_BIN`/`_LOCAL_*`/`_POLL_*`, and fake-double vars `FAKE_CODEX_ARGV_LOG`/`FAKE_SSH_LOG`/`FAKE_SSH_RC` are used identically across all tasks. `$bargs` is always expanded unquoted to word-split `-p local`.

**Note on test count:** Task 11 expects 23 files (3 new). If `tests/` already differs, trust the `run.sh` summary over the literal number.

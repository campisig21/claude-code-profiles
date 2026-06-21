# claude-on-station transport (`claude-run`) — Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codify "drive `claude -p` against the local station" into a tested `bin/claude-run` primitive that owns the env contract (incl. the always-omitted `ANTHROPIC_SMALL_FAST_MODEL`), exposes a reachability `doctor` and a stream-json `digest`, and is gated by a live streaming spike before any surfacing contract is frozen.

**Architecture:** A sourced library `lib/claude-local.sh` (resolve / exec / probe / digest) + a thin CLI `bin/claude-run` (mirrors `bin/dispatch`), both **outside** the frozen `lib/dispatch.sh` seam. Deterministic house tests fake `claude` and `curl` via `${CLAUDE_BIN}` / `${CURL_BIN}` seams. Live spike + smoke run against the real station last.

**Tech Stack:** Bash, `jq` (digest), the repo's `tests/lib.sh` harness (`ps_setup_sandbox`, `assert_*`, fakes). Governing decision: [ADR-0004](../../decisions/0004-claude-local-dispatch-transport.md). Spec: [2026-06-21-claude-local-transport-design](../specs/2026-06-21-claude-local-transport-design.md).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `lib/claude-local.sh` | Transport: `claude_local_resolve` / `_exec` / `_probe` / `_digest`. Single source of truth for the env contract. | Create |
| `bin/claude-run` | CLI: default exec path + `doctor` / `env` / `digest` subcommands. | Create |
| `tests/lib.sh` | Add `ps_make_fake_claude_p` (env+ARGS dumper). Existing `ps_make_fake_claude` is untouched (ccp tests depend on it). | Modify |
| `tests/claude_run_test.sh` | Hermetic smoke for all of the above. | Create |
| `station/llama-jinja/README.md` | De-dup: replace the inlined `claude -p` recipe with a pointer. | Modify |
| `skills/dispatch/SKILL.md` | Add the `claude-local` delegate + surfacing bullet. | Modify |
| `docs/decisions/0004-*.md`, `docs/decisions/README.md` | Flip ADR-0004 Proposed → Accepted. | Modify |

**Not touched:** `lib/dispatch.sh` (frozen seam), `bin/dispatch`, `install.sh` (no PATH symlink in Phase A — callers use the repo path `bin/claude-run`).

---

## Task 1: Library skeleton + the env contract (resolve + exec)

**Files:**
- Modify: `tests/lib.sh` (add `ps_make_fake_claude_p`)
- Create: `lib/claude-local.sh`
- Create: `bin/claude-run`
- Create: `tests/claude_run_test.sh`

- [ ] **Step 1: Add the fake `claude -p` to the harness**

In `tests/lib.sh`, add after the existing `ps_make_fake_claude` function:

```bash
# Fake `claude -p` for claude-run transport tests. Dumps the ANTHROPIC_* env it
# received + its args. Distinct from ps_make_fake_claude (ccp profile tests).
ps_make_fake_claude_p() {
  local p="$PS_SANDBOX/fake-claude-p"
  cat > "$p" <<'SH'
#!/usr/bin/env bash
echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-<unset>}"
echo "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-<unset>}"
echo "ANTHROPIC_SMALL_FAST_MODEL=${ANTHROPIC_SMALL_FAST_MODEL:-<unset>}"
echo "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-<unset>}"
echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-<unset>}"
echo "ARGS=$*"
exit 0
SH
  chmod +x "$p"
  printf '%s\n' "$p"
}
```

- [ ] **Step 2: Write the failing test (env contract)**

Create `tests/claude_run_test.sh`:

```bash
#!/usr/bin/env bash
# Hermetic smoke for bin/claude-run (ADR-0004): the env contract (incl. the
# always-omitted SMALL_FAST_MODEL), --model/--stream/-- passthrough, doctor
# readiness, and the stream-json digest. claude + curl faked via CLAUDE_BIN /
# CURL_BIN seams; no live station needed.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox

CLI="$PS_REPO_ROOT/bin/claude-run"
fake="$(ps_make_fake_claude_p)"
export CLAUDE_BIN="$fake"

# --- env contract: localhost default (NO personal IP in distributable code),
#     SMALL_FAST defaults to MODEL, API_KEY unset. Unset the override vars so the
#     default is deterministic regardless of the operator's shell. -------------
out="$(env -u CLAUDE_DISPATCH_URL -u CODEX_DISPATCH_LOCAL_ENDPOINT "$CLI" --dir "$PS_SANDBOX" "do a thing")"
assert_contains "$out" "ANTHROPIC_BASE_URL=http://localhost:8080"   "default base url (localhost)"
assert_contains "$out" "ANTHROPIC_MODEL=qwen3-coder-30b"            "default model (ADR-0003)"
assert_contains "$out" "ANTHROPIC_SMALL_FAST_MODEL=qwen3-coder-30b" "SMALL_FAST defaults to MODEL"
assert_contains "$out" "ANTHROPIC_AUTH_TOKEN=dummy"                 "auth token dummy"
assert_contains "$out" "ANTHROPIC_API_KEY=<unset>"                  "API key unset (env -u)"
assert_contains "$out" "do a thing"                                 "prompt forwarded to claude -p"

# --- station endpoint derived from CODEX_DISPATCH_LOCAL_ENDPOINT (minus /v1) ---
out="$(env -u CLAUDE_DISPATCH_URL CODEX_DISPATCH_LOCAL_ENDPOINT=http://station.example:9100/v1 \
       "$CLI" --dir "$PS_SANDBOX" "x")"
assert_contains "$out" "ANTHROPIC_BASE_URL=http://station.example:9100" "derive base from codex endpoint, strip /v1"

# --- CLAUDE_DISPATCH_URL overrides the derived endpoint ----------------------
out="$(CODEX_DISPATCH_LOCAL_ENDPOINT=http://station.example:9100/v1 CLAUDE_DISPATCH_URL=http://override.example:7000 \
       "$CLI" --dir "$PS_SANDBOX" "x")"
assert_contains "$out" "ANTHROPIC_BASE_URL=http://override.example:7000" "CLAUDE_DISPATCH_URL wins"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 3: Run it; verify it fails**

Run: `bash tests/claude_run_test.sh`
Expected: FAIL — `bin/claude-run` does not exist (`No such file or directory`).

- [ ] **Step 4: Create `lib/claude-local.sh`**

```bash
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
```

- [ ] **Step 5: Create `bin/claude-run`**

```bash
#!/usr/bin/env bash
# bin/claude-run — drive `claude -p` against the local station (ADR-0004).
# Single source of truth for the env contract. The dispatch cell / orchestrator
# shells to this; it initiates nothing on its own.
#   claude-run [--dir P] [--model M] [--stream] "<prompt>" [-- <claude flags>]
#   claude-run doctor | env | digest
set -uo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$DIR/$SOURCE";; esac
done
HERE="$(cd -P "$(dirname "$SOURCE")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/lib/claude-local.sh"

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; }

run_exec() {
  local dir="." model="" stream=0 prompt=""
  local -a extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)    dir="$2"; shift 2;;
      --model)  model="$2"; shift 2;;
      --stream) stream=1; shift;;
      --)       shift; extra=("$@"); break;;
      -*)       echo "claude-run: unknown option $1 (use -- to pass claude flags)" >&2; exit 2;;
      *)        if [ -z "$prompt" ]; then prompt="$1"; else extra+=("$1"); fi; shift;;
    esac
  done
  [ -z "$prompt" ] && { echo "claude-run: missing prompt" >&2; exit 2; }
  [ -n "$model" ] && export CLAUDE_DISPATCH_MODEL="$model"
  local -a cargs=("$prompt")
  [ "$stream" = "1" ] && cargs+=(--output-format stream-json --verbose)
  [ "${#extra[@]}" -gt 0 ] && cargs+=("${extra[@]}")
  claude_local_exec "$dir" "${cargs[@]}"
}

main() {
  case "${1:-}" in
    doctor) claude_local_probe ;;
    env)    claude_local_resolve
            printf 'ANTHROPIC_BASE_URL=%s\nANTHROPIC_MODEL=%s\nANTHROPIC_SMALL_FAST_MODEL=%s\n' \
                   "$CL_URL" "$CL_MODEL" "$CL_SMALL" ;;
    digest) claude_local_digest ;;
    -h|--help) usage ;;
    "")     usage; exit 2 ;;
    *)      run_exec "$@" ;;
  esac
}
main "$@"
```

Then make it executable:

Run: `chmod +x bin/claude-run`

> Note: `claude_local_probe` and `claude_local_digest` are referenced by `main` but added in Tasks 3–4. Until then, only the default exec path and `env` are exercised — that is what Task 1's test covers.

- [ ] **Step 6: Run the test; verify it passes**

Run: `bash tests/claude_run_test.sh`
Expected: PASS — all checks pass, `0 failed` (≈8 checks at this point).

- [ ] **Step 7: Commit**

```bash
git add tests/lib.sh lib/claude-local.sh bin/claude-run tests/claude_run_test.sh
git commit -m "feat(claude-run): env contract primitive (resolve + exec)"
```

---

## Task 2: `--model` override, `--stream`, and `--` passthrough

**Files:**
- Modify: `tests/claude_run_test.sh`
- Modify: `bin/claude-run` (already has `run_exec` from Task 1 — these tests pin its behavior)

- [ ] **Step 1: Add failing tests**

In `tests/claude_run_test.sh`, before `ps_teardown_sandbox`, add:

```bash
# --- --model override + SMALL_FAST follows it --------------------------------
out="$("$CLI" --dir "$PS_SANDBOX" --model glm-z1-32b "x")"
assert_contains "$out" "ANTHROPIC_MODEL=glm-z1-32b"            "--model overrides"
assert_contains "$out" "ANTHROPIC_SMALL_FAST_MODEL=glm-z1-32b" "SMALL_FAST follows --model"

# --- explicit SMALL_FAST override wins ---------------------------------------
out="$(CLAUDE_DISPATCH_SMALL_FAST_MODEL=qwen3-0.6b "$CLI" --dir "$PS_SANDBOX" "x")"
assert_contains "$out" "ANTHROPIC_SMALL_FAST_MODEL=qwen3-0.6b" "explicit SMALL_FAST honored"

# --- --stream adds stream-json; -- passes claude flags verbatim --------------
out="$("$CLI" --dir "$PS_SANDBOX" --stream "x" -- --allowedTools Read)"
assert_contains "$out" "--output-format stream-json" "--stream adds stream-json"
assert_contains "$out" "--allowedTools Read"          "-- passthrough verbatim"

# --- unknown pre-'--' flag is rejected (no silent prompt-eating) -------------
"$CLI" --dir "$PS_SANDBOX" --bogus "x" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "unknown option exits 2"
```

- [ ] **Step 2: Run; verify pass (the impl already exists from Task 1)**

Run: `bash tests/claude_run_test.sh`
Expected: PASS — all checks pass, `0 failed` (≈14 checks). (If any fail, fix `run_exec` in `bin/claude-run` to match.)

- [ ] **Step 3: Commit**

```bash
git add tests/claude_run_test.sh
git commit -m "test(claude-run): pin --model/--stream/-- passthrough + bad-flag reject"
```

---

## Task 3: `doctor` reachability probe

**Files:**
- Modify: `lib/claude-local.sh` (add `claude_local_probe`)
- Modify: `tests/claude_run_test.sh`

- [ ] **Step 1: Add failing tests (fake curl)**

In `tests/claude_run_test.sh`, before `ps_teardown_sandbox`, add:

```bash
# --- doctor: 200/200 READY, non-200 NOT READY (fake curl) --------------------
fc_ok="$PS_SANDBOX/fake-curl-ok"
printf '#!/usr/bin/env bash\nprintf 200\n' > "$fc_ok"; chmod +x "$fc_ok"
out="$(CURL_BIN="$fc_ok" "$CLI" doctor)"
printf '%s\n' "$out" | grep -qx 'READY' && r=yes || r=no
assert_eq "$r" "yes" "doctor READY on 200/200"
assert_contains "$out" "Anthropic /v1/messages=200" "doctor reports the anthropic code"

fc_busy="$PS_SANDBOX/fake-curl-busy"
printf '#!/usr/bin/env bash\nprintf 503\n' > "$fc_busy"; chmod +x "$fc_busy"
out="$(CURL_BIN="$fc_busy" "$CLI" doctor)"
printf '%s\n' "$out" | grep -q '^NOT READY' && r=yes || r=no
assert_eq "$r" "yes" "doctor NOT READY when a probe != 200"
```

- [ ] **Step 2: Run; verify it fails**

Run: `bash tests/claude_run_test.sh`
Expected: FAIL — `doctor` prints nothing useful (`claude_local_probe` undefined → empty output, READY check fails).

- [ ] **Step 3: Implement `claude_local_probe`**

In `lib/claude-local.sh`, add after `claude_local_exec`:

```bash
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
```

- [ ] **Step 4: Run; verify it passes**

Run: `bash tests/claude_run_test.sh`
Expected: PASS — all checks pass, `0 failed` (≈17 checks).

- [ ] **Step 5: Commit**

```bash
git add lib/claude-local.sh tests/claude_run_test.sh
git commit -m "feat(claude-run): doctor reachability probe (200/200 READY)"
```

---

## Task 4: `digest` (stream-json → per-step trace) + `env`

**Files:**
- Modify: `lib/claude-local.sh` (add `claude_local_digest`)
- Modify: `tests/claude_run_test.sh`

- [ ] **Step 1: Add failing tests**

In `tests/claude_run_test.sh`, before `ps_teardown_sandbox`, add:

```bash
# --- env subcommand prints the live contract ---------------------------------
out="$("$CLI" env)"
assert_contains "$out" "ANTHROPIC_MODEL=qwen3-coder-30b" "env subcommand prints model"

# --- digest: stream-json NDJSON -> concise per-step trace --------------------
ndjson="$PS_SANDBOX/stream.ndjson"
cat > "$ndjson" <<'JSON'
{"type":"assistant","message":{"content":[{"type":"text","text":"I'll read it."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"hello.txt"}}]}}
{"type":"result","subtype":"success","is_error":false,"result":"done"}
JSON
out="$("$CLI" digest < "$ndjson")"
assert_contains "$out" "tool: Read"      "digest surfaces tool_use"
assert_contains "$out" "result: success" "digest surfaces result"
```

- [ ] **Step 2: Run; verify it fails**

Run: `bash tests/claude_run_test.sh`
Expected: FAIL — `digest` is undefined (`claude_local_digest` not found → empty digest output).

- [ ] **Step 3: Implement `claude_local_digest`**

In `lib/claude-local.sh`, add after `claude_local_probe`:

```bash
# Read Claude Code stream-json NDJSON on stdin; emit one concise line per step.
# Schema is confirmed/adjusted by the live spike (Task 6) against real output.
claude_local_digest() {
  "${JQ_BIN:-jq}" -rc '
    if .type == "assistant" then
      (.message.content // [])[]
      | if .type == "tool_use" then "tool: \(.name) \(.input | tojson)"
        elif .type == "text" and ((.text // "") | length > 0) then "text: \(.text[0:80])"
        else empty end
    elif .type == "result" then
      "result: \(.subtype // "?")\(if .is_error then " ERROR" else "" end)"
    else empty end
  ' 2>/dev/null
}
```

- [ ] **Step 4: Run; verify it passes**

Run: `bash tests/claude_run_test.sh`
Expected: PASS — all checks pass, `0 failed` (≈20 checks).

- [ ] **Step 5: Run the FULL suite (the new fake must not break ccp/e2e)**

Run: `for t in tests/*_test.sh; do echo "== $t"; bash "$t" || echo "FAILED: $t"; done`
Expected: every test prints `(N checks, 0 failed)`; no `FAILED:` lines. In particular `tests/ccp_test.sh` and `tests/e2e_test.sh` (which use the untouched `ps_make_fake_claude`) still pass.

- [ ] **Step 6: Commit**

```bash
git add lib/claude-local.sh tests/claude_run_test.sh
git commit -m "feat(claude-run): stream-json digest + env subcommand"
```

---

## Task 5: Streaming spike — THE GATE (live; do before freezing surfacing)

**Goal:** prove the stream-json digest surfaces *incrementally* on the real substrate before the surfacing contract (Task 7) is frozen. **Prereqs:** `claude` CLI installed locally; station reachable; `qwen3-coder-30b` loaded (`bin/claude-run doctor` → READY).

- [ ] **Step 1: Confirm reachability**

Run: `bin/claude-run doctor`
Expected: `OpenAI …=200  Anthropic …=200` then `READY`. If `NOT READY`, load the model on the station (`llama-control.sh use qwen3-coder-30b`) and retry.

- [ ] **Step 2: Launch a streaming run as a background task, capture to a file**

In a sandbox dir with a `hello.txt`, run `bin/claude-run` via the **harness background facility** (NOT manual `nohup`), writing stream-json to a file:

```bash
mkdir -p /tmp/cl-spike && echo "secret: ORYX-42" > /tmp/cl-spike/hello.txt
bin/claude-run --dir /tmp/cl-spike --stream \
  "Read hello.txt and report the secret." -- --allowedTools Read --max-turns 3 \
  > /tmp/cl-spike/stream.ndjson
```

(When driven by an agent: launch with `run_in_background: true`; the harness writes stdout to its task output file — that file is the equivalent of `stream.ndjson`.)

- [ ] **Step 3: While it runs, confirm incremental growth (the buffering check)**

In a second shell, poll: `wc -l /tmp/cl-spike/stream.ndjson` a few times during the run.
Expected (PASS): line count **grows over time** before the process exits.
If it jumps from 0 to final only at exit → block-buffered (see Step 5).

- [ ] **Step 4: Confirm the digest renders the live stream**

Run: `bin/claude-run digest < /tmp/cl-spike/stream.ndjson`
Expected: readable per-step trace incl. a `tool: Read …` line and a final `result: …`. If field names differ from Task 4's fixture, update the `jq` filter in `claude_local_digest` AND the Task 4 fixture to match the real schema, re-run `bash tests/claude_run_test.sh`, and commit `fix(claude-run): align digest with real stream-json schema`.

- [ ] **Step 5: If (and only if) Step 3 showed buffering — turn on line-buffering**

The exec hook already lives in `claude_local_exec` (Task 1): when `CLAUDE_LOCAL_LINEBUF` is set and `stdbuf` is available it prefixes `stdbuf -oL` (absent `stdbuf` — e.g. stock macOS — it's a safe no-op). So the only change is to flip that var on the streaming path. In `bin/claude-run` `run_exec`, replace the bare stream line

```bash
  [ "$stream" = "1" ] && cargs+=(--output-format stream-json --verbose)
```

with:

```bash
  if [ "$stream" = "1" ]; then
    cargs+=(--output-format stream-json --verbose)
    export CLAUDE_LOCAL_LINEBUF=1
  fi
```

No env block is duplicated and no endpoint literal appears here — `claude_local_exec` owns the contract.

Re-run Steps 2–3 to confirm incremental output. Then `bash tests/claude_run_test.sh` (must still pass) and commit `fix(claude-run): line-buffer stream-json output`.

- [ ] **Step 6: Record the outcome in the spec revision log**

Append to `docs/superpowers/specs/2026-06-21-claude-local-transport-design.md` §13:
`- 2026-06-21 — spike: stream-json surfaces incrementally [with stdbuf | natively]; digest schema [matched fixture | adjusted].`
Commit `docs(spec): record streaming spike outcome`.

---

## Task 6: Live end-to-end smoke (orchestrator-direct surfacing)

**Goal:** prove the full UX — dispatch → digest narration → result — without the Phase B cell. Run by the orchestrator/human.

- [ ] **Step 1: Run a real qwen dispatch and narrate the digest**

```bash
echo "the secret word is QUOKKA-7731" > /tmp/cl-spike/hello.txt
bin/claude-run --dir /tmp/cl-spike --stream \
  "Read hello.txt and tell me the secret word." -- --allowedTools Read --max-turns 3 \
  | tee /tmp/cl-spike/run.ndjson | bin/claude-run digest
```

Expected: a live per-step trace (`tool: Read …` → `result: success`), and the final stream contains `QUOKKA-7731`. The unguessable token proves the tool loop executed.

- [ ] **Step 2: Confirm the verdict shape**

Run: `tail -1 /tmp/cl-spike/run.ndjson | jq '{type, subtype, is_error}'`
Expected: `{"type":"result","subtype":"success","is_error":false}`.

(No commit — this is a verification gate. If it fails, return to Task 5.)

---

## Task 7: Freeze the surfacing contract — `dispatch` skill bullet

**Files:**
- Modify: `skills/dispatch/SKILL.md`

- [ ] **Step 1: Add the `claude-local` delegate bullet**

In `skills/dispatch/SKILL.md`, find the line ending the Non-Claude delegate bullet:

```
     `--backend` picks the transport flag-bundle; `-m` picks the model. The codex
     `--json` progress streams to the event log (watch it with `dispatch attach "$id"`).
```

Add immediately after it:

```
   - **Local qwen via the Claude harness** (`claude-local`): delegate with
     `bin/claude-run [--model <alias>] --stream "<your composed prompt>" -- --allowedTools <…> --max-turns <n>`
     (default model `qwen3-coder-30b`, ADR-0004). Launch it via the harness
     background facility and surface progress by piping its stream-json through
     `bin/claude-run digest` — NEVER nest `claude -p` in a manual `nohup`/detached
     shell (it resets the parent shell and kills the orchestrator). Reasoning
     models need a real `--max-turns`/token budget or they return empty output.
```

- [ ] **Step 2: Sanity-check the skill still reads coherently**

Run: `sed -n '/Delegate by/,/Verify ONCE/p' skills/dispatch/SKILL.md`
Expected: three delegate bullets (Claude-direct, Non-Claude/codex, Local-qwen/claude-local) in order.

- [ ] **Step 3: Commit**

```bash
git add skills/dispatch/SKILL.md
git commit -m "docs(dispatch): add claude-local delegate + stream-json surfacing"
```

---

## Task 8: De-dup the prose copies → links

**Files:**
- Modify: `station/llama-jinja/README.md`

- [ ] **Step 1: Replace the inlined recipe with a pointer**

In `station/llama-jinja/README.md`, find:

```
- **Claude Code / `claude -p`:** no proxy —
  `ANTHROPIC_BASE_URL=http://100.64.0.4:8080`, `ANTHROPIC_MODEL=<alias>`,
  `ANTHROPIC_AUTH_TOKEN=dummy`.
```

Replace with:

```
- **Claude Code / `claude -p`:** drive via `bin/claude-run` — it owns the full
  env contract (incl. `ANTHROPIC_SMALL_FAST_MODEL`, which a hand-typed recipe
  omits). See [ADR-0004](../../docs/decisions/0004-claude-local-dispatch-transport.md).
```

- [ ] **Step 2: Confirm no other live copy remains in the repo**

Run: `grep -rn "ANTHROPIC_BASE_URL=http://100.64.0.4:8080" --include='*.md' station/ skills/ README.md`
Expected: no matches (dated `docs/specs` & `docs/plans` snapshots are intentionally left and not searched here).

- [ ] **Step 3: Commit**

```bash
git add station/llama-jinja/README.md
git commit -m "docs(station): point claude -p clients at bin/claude-run (de-dup, ADR-0004)"
```

> Memory de-dup (non-repo, do separately): trim the recipe in the `claude-harness-local-model`, `llama-jinja-station`, and `ergonomic-wrapper-next` auto-memories to a pointer at `bin/claude-run`; keep the LiteLLM *fallback* recipe in `claude-harness-local-model`.

---

## Task 9: Flip ADR-0004 → Accepted

**Files:**
- Modify: `docs/decisions/0004-claude-local-dispatch-transport.md`
- Modify: `docs/decisions/README.md`

- [ ] **Step 1: Update the ADR status + canonical source**

In `docs/decisions/0004-claude-local-dispatch-transport.md`:
- Change `- **Status:** Proposed` → `- **Status:** Accepted`.
- Change `**Canonical source (forthcoming):**` → `**Canonical source:**` and drop "(forthcoming)" from the `bin/claude-run` line.
- In Consequences, change `This ADR moves to `Accepted` when the spec is approved.` →
  `Accepted 2026-06-21: Phase A implemented and the live spike passed.`

- [ ] **Step 2: Update the index row**

In `docs/decisions/README.md`, change the ADR-0004 row:
`| [0004](…) | claude-on-station as a first-class dispatch transport | Proposed | \`bin/claude-run\` (forthcoming) |`
→
`| [0004](…) | claude-on-station as a first-class dispatch transport | Accepted | \`bin/claude-run\` |`

- [ ] **Step 3: Commit**

```bash
git add docs/decisions/0004-claude-local-dispatch-transport.md docs/decisions/README.md
git commit -m "docs(decisions): ADR-0004 Accepted — claude-run shipped (Phase A)"
```

---

## Phase B (deferred — its own spec/plan)

Wrap `claude_local_exec` in the dispatch cell lifecycle: resolve worktree → exec → **scoped** commit (NOT `git add -A`; do not author a `.gitignore` — both break `land --ff-only`) → sidecar. Add the `claude-local` bake-off contestant. See spec §11 and the `ergonomic-wrapper-next` memory.

---

## Self-Review

**Spec coverage:** §3 components → Tasks 1,3,4; env contract incl. SMALL_FAST_MODEL → Task 1; §5 spike (gate) → Task 5 (before §6 surfacing freeze in Task 7); §6 surfacing → Tasks 5–7; §7 de-dup → Task 8; §9 tests (fake claude + fake curl + fixture) → Tasks 1–4; §10 skill bullet + ADR flip → Tasks 7,9. All covered.

**Placeholder scan:** no TBD/TODO; every code step shows full code; commands have expected output.

**Type/name consistency:** `claude_local_resolve` / `_exec` / `_probe` / `_digest` and `CL_URL`/`CL_MODEL`/`CL_SMALL` used identically across lib, CLI, and tests; subcommands `doctor`/`env`/`digest` consistent between `bin/claude-run` `main` and the tests.

# claude-local dispatch cell + bake-off contestant (Phase B) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-local` a first-class dispatch cell — `bin/claude-run cell <id>` runs a qwen worker inside a `dispatch begin` worktree, surfaces a digest, commits, and updates the sidecar — and wire it in as a bake-off contestant.

**Architecture:** A non-`exec` run path (`claude_local_run`) is added to `lib/claude-local.sh`; `bin/claude-run` gains a `cell` subcommand that reuses the **independent** library `lib/dispatch-lib.sh` (`d_sc_get` / `d_commit_worktree` / `d_sc_set`) — the **frozen** codex adapter `lib/dispatch.sh` is never touched (ADR-0006). The bake-off Workflow gets a `claude-local` contestant.

**Tech Stack:** Bash, `jq`, the repo's `tests/lib.sh` harness (`ps_setup_sandbox`, `ps_make_sandbox_repo`, `assert_*`), the `dispatch` CLI + `lib/dispatch-lib.sh`. Governing decisions: [ADR-0006](../../decisions/0006-claude-local-cell-integration.md), [ADR-0004](../../decisions/0004-claude-local-dispatch-transport.md). Spec: [2026-06-22-claude-local-cell-design](../specs/2026-06-22-claude-local-cell-design.md).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `lib/claude-local.sh` | Transport. Add `claude_local_env_argv` (shared env builder) + `claude_local_run` (non-exec run → NDJSON to a file). `claude_local_exec` refactored onto the shared builder; behavior unchanged. | Modify |
| `bin/claude-run` | CLI. Add the `cell <id> "<prompt>" [-- flags]` subcommand (resolve worktree → run → digest → commit → sidecar). | Modify |
| `workflows/dispatch-bakeoff.js` | Add the `claude-local` contestant + its delegate branch in `cellPrompt`. | Modify |
| `tests/claude_local_run_test.sh` | Unit test for `claude_local_run` (non-exec, stream capture, exit-code, cwd isolation). | Create |
| `tests/claude_run_cell_test.sh` | Cell lifecycle against a real `d_begin` worktree (commit + sidecar + digest + error paths). | Create |
| `tests/dispatch_bakeoff_workflow_test.sh` | Extend the static lint for the new contestant. | Modify |
| `docs/decisions/0006-*.md`, `docs/decisions/README.md` | Flip ADR-0006 Proposed → Accepted. | Modify |

**Not touched:** `lib/dispatch.sh` (frozen codex adapter), `lib/dispatch-lib.sh` (frozen library — we *call* it, never edit it), `bin/dispatch`.

---

## Task 1: Non-exec run path in the transport library

**Files:**
- Modify: `lib/claude-local.sh`
- Create: `tests/claude_local_run_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/claude_local_run_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for claude_local_run (the non-exec cell worker path): it runs claude -p
# as a SUBPROCESS (control returns), captures stream-json NDJSON to a file, runs the
# worker inside <dir>, isolates the caller's cwd, and propagates the worker's exit code.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/claude-local.sh"

# A fake `claude -p`: writes a file into its cwd, emits canned NDJSON on stdout, exits 7.
fake="$PS_SANDBOX/fake-claude-lib"
cat > "$fake" <<'SH'
#!/usr/bin/env bash
echo "ran in $(pwd)" > RAN_HERE
cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"RAN_HERE"}}]}}
{"type":"result","subtype":"success","is_error":false}
JSON
exit 7
SH
chmod +x "$fake"
export CLAUDE_BIN="$fake"

wd="$PS_SANDBOX/wt"; mkdir -p "$wd"
stream="$PS_SANDBOX/run.ndjson"
before_pwd="$(pwd)"

out="$(claude_local_run "$wd" "$stream" "do the thing")"; rc=$?
assert_eq "$rc" "7"                "claude_local_run returns the worker's exit code (non-exec: control returned)"
assert_eq "$(pwd)" "$before_pwd"   "claude_local_run does not change the caller's cwd (subshell)"
assert_eq "$out" ""                "claude_local_run emits nothing on stdout (stream goes to the file)"
assert_file "$wd/RAN_HERE"         "worker ran inside the target dir (cwd was the worktree)"
assert_contains "$(cat "$stream")" '"type":"result"' "stream-json NDJSON captured to the stream file"
assert_contains "$(cat "$stream")" '"tool_use"'      "stream carries the tool_use event"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bash tests/claude_local_run_test.sh </dev/null`
Expected: FAIL — `claude_local_run: command not found` (function not defined yet).

- [ ] **Step 3: Refactor the env block + add `claude_local_run`**

In `lib/claude-local.sh`, replace the `claude_local_exec` function (the whole function, from its leading comment through its closing `}`) with this shared-env-builder version **plus** the new `claude_local_run`:

```bash
# Build the resolved `env -u … ANTHROPIC_*` argv into the CL_ENV array (shared by
# _exec and _run so the contract lives in exactly one place). Calls _resolve.
claude_local_env_argv() {
  claude_local_resolve
  CL_ENV=(env -u ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL="$CL_URL"
    ANTHROPIC_AUTH_TOKEN=dummy
    ANTHROPIC_MODEL="$CL_MODEL"
    ANTHROPIC_SMALL_FAST_MODEL="$CL_SMALL")
}

# cd <dir>; exec claude -p with the resolved env. Replaces the shell (one-shot path).
# Line-buffers stdout (stdbuf -oL) when CLAUDE_LOCAL_LINEBUF is set; $linebuf is
# intentionally unquoted so an empty value expands to nothing (safe under set -u).
claude_local_exec() {
  local dir="$1"; shift
  claude_local_env_argv
  cd "$dir" || { echo "claude-run: cannot cd to $dir" >&2; return 1; }
  local linebuf=""
  [ -n "${CLAUDE_LOCAL_LINEBUF:-}" ] && command -v stdbuf >/dev/null 2>&1 && linebuf="stdbuf -oL"
  exec "${CL_ENV[@]}" $linebuf "${CLAUDE_BIN:-claude}" -p "$@"
}

# Run claude -p as a SUBPROCESS (NOT exec — control returns for the commit/sidecar
# steps the cell does next). Forces stream-json; the worker's stdout (the NDJSON) is
# redirected to <streamfile>, NOT the caller's stdout (reserved for the digest). The
# cd is localized to a subshell so the caller's cwd is untouched. Returns the worker's
# exit code.
claude_local_run() {
  local dir="$1" stream="$2"; shift 2
  claude_local_env_argv
  ( cd "$dir" && "${CL_ENV[@]}" "${CLAUDE_BIN:-claude}" -p --output-format stream-json --verbose "$@" ) > "$stream"
}
```

- [ ] **Step 4: Run the new test; verify it passes**

Run: `bash tests/claude_local_run_test.sh </dev/null`
Expected: PASS — all checks pass, `0 failed`.

- [ ] **Step 5: Re-run the Phase-A test (the env refactor must not change the contract)**

Run: `bash tests/claude_run_test.sh </dev/null`
Expected: PASS — `0 failed` (the env-contract / `--model` / `--stream` / doctor / digest tests still pass; `claude_local_exec` produces the identical env via `CL_ENV`).

- [ ] **Step 6: Commit**

```bash
git add lib/claude-local.sh tests/claude_local_run_test.sh
git commit -m "feat(claude-run): non-exec claude_local_run + shared env builder"
```

---

## Task 2: The `cell` subcommand

**Files:**
- Modify: `bin/claude-run`
- Create: `tests/claude_run_cell_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/claude_run_cell_test.sh`:

```bash
#!/usr/bin/env bash
# claude-run `cell <id>`: run a qwen worker inside a `dispatch begin` worktree, print
# the digest, commit the change via d_commit_worktree, and stamp the sidecar. Hermetic:
# real d_begin worktree + a fake `claude` (CLAUDE_BIN seam); no live station.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
CLI="$PS_REPO_ROOT/bin/claude-run"
ro="$(ps_make_sandbox_repo ok)"

# fake `claude -p`: writes a file into the worktree (cwd) + emits canned NDJSON.
fakecell="$PS_SANDBOX/fake-claude-cell"
cat > "$fakecell" <<'SH'
#!/usr/bin/env bash
echo "claude-local was here" > CELL_IMPL
cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"CELL_IMPL"}}]}}
{"type":"result","subtype":"success","is_error":false}
JSON
exit 0
SH
chmod +x "$fakecell"

# happy path: begin -> cell -> digest printed, file committed, sidecar stamped
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260622T120000Z bash "$DISPATCH" begin add-cell --label qwen-local )"
out="$( cd "$ro" && CLAUDE_BIN="$fakecell" bash "$CLI" cell "$id" "implement the thing" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "claude-run cell exits 0 on a successful worker"
assert_contains "$out" "tool: Write"     "cell prints the digest (tool_use surfaced)"
assert_contains "$out" "result: success" "cell prints the digest (result surfaced)"

( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  wt="$(d_sc_get "$id" '.worktree')"
  assert_eq "$(cat "$wt/CELL_IMPL")" "claude-local was here" "worker's file landed in the worktree"
  assert_eq "$(d_has_changes "$wt" "$(d_sc_get "$id" '.base_ref')" && echo yes || echo no)" "yes" "cell committed the work (worktree diverges from base)"
  assert_eq "$(d_sc_get "$id" '.backend')" "claude-local"     "sidecar backend = claude-local"
  assert_eq "$(d_sc_get "$id" '.model')"   "qwen3-coder-30b"  "sidecar model recorded (default per ADR-0003)" )

# failed-worker path: nonzero worker exit propagates (so the cell can record failed)
fakefail="$PS_SANDBOX/fake-claude-fail"
printf '#!/usr/bin/env bash\necho "{}"; exit 3\n' > "$fakefail"; chmod +x "$fakefail"
id2="$( cd "$ro" && CODEX_DISPATCH_NOW=20260622T121000Z bash "$DISPATCH" begin add-cell2 --label qwen-local )"
( cd "$ro" && CLAUDE_BIN="$fakefail" bash "$CLI" cell "$id2" "do y" >/dev/null 2>&1 ); rc2=$?
assert_eq "$rc2" "3" "claude-run cell propagates the worker's nonzero exit"

# missing-worktree path: clear error, exit 1
( cd "$ro" && CLAUDE_BIN="$fakecell" bash "$CLI" cell "nope-no-such-id" "x" >/dev/null 2>&1 ); rc3=$?
assert_eq "$rc3" "1" "claude-run cell exits 1 when the worktree/sidecar is missing"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bash tests/claude_run_cell_test.sh </dev/null`
Expected: FAIL — `cell` is not a known subcommand, so `claude-run` treats `cell` as a prompt and execs the fake against `nope-no-such-id`… the assertions on `backend=claude-local` / exit codes fail.

- [ ] **Step 3: Add the `cell` subcommand to `bin/claude-run`**

In `bin/claude-run`, extend the header usage comment — change:

```bash
#   claude-run doctor | env | digest
set -uo pipefail
```

to:

```bash
#   claude-run doctor | env | digest
#   claude-run cell <id> "<prompt>" [-- <claude flags>]   # dispatch-cell mode (ADR-0006)
set -uo pipefail
```

and bump the usage extractor — change `usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; }` to `usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; }`.

Then add this function (place it after `run_exec`, before `main`):

```bash
# Dispatch-cell mode (ADR-0006): run the qwen worker inside a `dispatch begin`
# worktree, surface a digest, commit, and stamp the sidecar. Reuses the independent
# library lib/dispatch-lib.sh — never the frozen codex adapter lib/dispatch.sh.
run_cell() {
  local id="${1:-}" prompt="${2:-}"
  { [ -n "$id" ] && [ -n "$prompt" ]; } || {
    echo "claude-run cell: usage: claude-run cell <id> \"<prompt>\" [-- claude flags]" >&2; exit 2; }
  shift 2
  local -a extra=()
  if [ "${1:-}" = "--" ]; then shift; extra=("$@"); fi
  source "$ROOT/lib/jsonutil.sh"
  source "$ROOT/lib/dispatch-lib.sh"
  local wt; wt="$(d_sc_get "$id" '.worktree')"
  { [ -n "$wt" ] && [ -d "$wt" ]; } || {
    echo "claude-run cell: no worktree for id '$id' (run 'dispatch begin' first)" >&2; exit 1; }
  claude_local_resolve
  local stream; stream="$(d_sidecar_dir)/$id.stream.ndjson"
  local -a cargs=("$prompt")
  [ "${#extra[@]}" -gt 0 ] && cargs+=("${extra[@]}")
  local rc=0
  claude_local_run "$wt" "$stream" "${cargs[@]}" || rc=$?
  claude_local_digest < "$stream"
  d_commit_worktree "$wt" "claude-local: $id ($CL_MODEL)" || true
  d_sc_set "$id" '.backend="claude-local" | .model=$m | .updated_at=$u' --arg m "$CL_MODEL" --arg u "$(d_now)"
  return "$rc"
}
```

Then add a `cell)` branch to `main`'s `case` (immediately before the `*)` line):

```bash
    cell)   shift; run_cell "$@" ;;
```

- [ ] **Step 4: Run the cell test; verify it passes**

Run: `bash tests/claude_run_cell_test.sh </dev/null`
Expected: PASS — all checks pass, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-run tests/claude_run_cell_test.sh
git commit -m "feat(claude-run): cell mode — run qwen in a dispatch worktree, commit, stamp sidecar"
```

---

## Task 3: The `claude-local` bake-off contestant

**Files:**
- Modify: `workflows/dispatch-bakeoff.js`
- Modify: `tests/dispatch_bakeoff_workflow_test.sh`

- [ ] **Step 1: Add failing lint assertions**

In `tests/dispatch_bakeoff_workflow_test.sh`, after the existing default-contestant block (the line `assert_contains "$body" "claude"  "default contestant claude (direct cell)"`), add:

```bash
# --- claude-local contestant (Phase B): claude-on-qwen via bin/claude-run cell ---
assert_contains "$body" "claude-local"      "default contestant claude-local"
assert_contains "$body" "qwen3-coder-30b"   "claude-local contestant uses qwen3-coder-30b (ADR-0003)"
assert_contains "$body" "bin/claude-run cell" "cell prompt drives the claude-run cell delegate"
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bash tests/dispatch_bakeoff_workflow_test.sh </dev/null`
Expected: FAIL — the three new strings are not in the workflow yet.

- [ ] **Step 3: Add the contestant to the default set**

In `workflows/dispatch-bakeoff.js`, change the default contestants array:

```javascript
  : [
      { backend: '—',      model: 'claude'  }, // em-dash backend: a direct Claude cell (no codex)
      { backend: 'codex',  model: 'gpt-5.5' },
      { backend: 'ollama', model: 'qwen2.5' },
    ]
```

to:

```javascript
  : [
      { backend: '—',            model: 'claude'          }, // em-dash backend: a direct Claude cell (no codex)
      { backend: 'codex',        model: 'gpt-5.5'         },
      { backend: 'ollama',       model: 'qwen2.5'         },
      { backend: 'claude-local', model: 'qwen3-coder-30b' }, // claude -p on the local station via bin/claude-run cell
    ]
```

- [ ] **Step 4: Add the delegate branch in `cellPrompt`**

In `workflows/dispatch-bakeoff.js`, in `cellPrompt(c)`, replace the DELEGATE block:

```javascript
    `3. DELEGATE by model:`,
    `   - Claude model (claude/opus/sonnet/haiku/fable): implement DIRECTLY — edit the files`,
    `     in the begin-returned worktree (find its path WT via \`dispatch show "$id"\`). Do NOT`,
    `     codex-run a Claude model; the library refuses it (E10). THEN COMMIT inside the worktree`,
    `     so land has something to merge:  (cd "$WT" && git add -A && git commit -m "bakeoff: $id")`,
    `     — codex-run auto-commits; a direct edit MUST commit itself or land merges nothing.`,
    `   - Otherwise: dispatch codex-run "$id" --backend ${c.backend} -m ${c.model} "<your composed prompt>"`,
```

with (adds a third, claude-local branch keyed by backend):

```javascript
    `3. DELEGATE (pick the line matching YOUR backend=${c.backend}):`,
    `   - Claude model (claude/opus/sonnet/haiku/fable): implement DIRECTLY — edit the files`,
    `     in the begin-returned worktree (find its path WT via \`dispatch show "$id"\`). Do NOT`,
    `     codex-run a Claude model; the library refuses it (E10). THEN COMMIT inside the worktree`,
    `     so land has something to merge:  (cd "$WT" && git add -A && git commit -m "bakeoff: $id")`,
    `     — codex-run auto-commits; a direct edit MUST commit itself or land merges nothing.`,
    `   - claude-local (local qwen via the Claude harness): run`,
    `       bin/claude-run cell "$id" "<your composed prompt>" -- --allowedTools Read,Edit,Write,Bash --max-turns 12`,
    `     It runs claude -p on the station model, prints a per-step digest, COMMITS the worktree,`,
    `     and stamps the sidecar — no separate commit needed. Never wrap it in manual nohup.`,
    `   - codex / ollama (any other backend): dispatch codex-run "$id" --backend ${c.backend} -m ${c.model} "<your composed prompt>"`,
```

- [ ] **Step 5: Run the lint; verify it passes (and the JS is still well-formed)**

Run: `bash tests/dispatch_bakeoff_workflow_test.sh </dev/null`
Expected: PASS — all checks pass, `0 failed` (incl. the no-TypeScript / no-`Date.now` guards still green).

Also confirm the script still parses as JavaScript:
Run: `node --check workflows/dispatch-bakeoff.js && echo "JS OK"`
Expected: `JS OK`.

- [ ] **Step 6: Commit**

```bash
git add workflows/dispatch-bakeoff.js tests/dispatch_bakeoff_workflow_test.sh
git commit -m "feat(bakeoff): add claude-local contestant (claude-on-qwen via claude-run cell)"
```

---

## Task 4: Flip ADR-0006 → Accepted + full-suite gate

**Files:**
- Modify: `docs/decisions/0006-claude-local-cell-integration.md`
- Modify: `docs/decisions/README.md`

- [ ] **Step 1: Run the FULL suite (the gate — nothing regressed)**

Run: `for t in tests/*_test.sh; do bash "$t" </dev/null >/tmp/t.out 2>&1 || { echo "FAIL: $t"; tail -3 /tmp/t.out; }; done; echo done`
Expected: no `FAIL:` lines. (Run with `</dev/null` — `tests/curator_loop_test.sh`'s fake `flock` blocks on a non-EOF stdin otherwise. This is a known pre-existing test fragility, not part of this work.)

- [ ] **Step 2: Update the ADR status + canonical source**

In `docs/decisions/0006-claude-local-cell-integration.md`:
- Change `- **Status:** Proposed` → `- **Status:** Accepted`.
- Change `- **Canonical source (forthcoming):**` → `- **Canonical source:**` and drop `(forthcoming)`.
- In Consequences, change the last bullet `- Flips to \`Accepted\` when Phase B is implemented and its tests pass.` → `- Accepted 2026-06-23: Phase B implemented (claude-run \`cell\` mode + claude-local bake-off contestant), hermetic tests green, frozen seam untouched.`

- [ ] **Step 3: Update the index row**

In `docs/decisions/README.md`, change the ADR-0006 row:
`| [0006](0006-claude-local-cell-integration.md) | Non-codex delegates integrate via their own wrapper, not the frozen seam | Proposed | \`bin/claude-run\` \`cell\` mode (forthcoming) |`
→
`| [0006](0006-claude-local-cell-integration.md) | Non-codex delegates integrate via their own wrapper, not the frozen seam | Accepted | \`bin/claude-run\` \`cell\` mode |`

- [ ] **Step 4: Commit**

```bash
git add docs/decisions/0006-claude-local-cell-integration.md docs/decisions/README.md
git commit -m "docs(decisions): ADR-0006 Accepted — claude-local cell shipped (Phase B)"
```

---

## Self-Review

**Spec coverage:** §3 `claude_local_run` (non-exec) → Task 1; `claude_local_env` shared builder → Task 1 (`claude_local_env_argv`); `bin/claude-run cell` (resolve→run→digest→commit→sidecar) → Task 2; bake-off contestant + cell-prompt branch → Task 3; tests (cell lifecycle + contestant lint) → Tasks 2,3 (+ the `claude_local_run` unit in Task 1); error handling (missing worktree → exit 1, worker nonzero → propagate, no-change commit tolerated) → Task 2 test; ADR-0006 → Accepted → Task 4; frozen seam untouched → enforced by sourcing `dispatch-lib.sh` (not `dispatch.sh`) + the existing `dispatch_lib_extraction_test.sh` (run in Task 4's full suite). The §6 "full suite stays green" → Task 1 Step 5 + Task 4 Step 1. All covered.

**Placeholder scan:** no TBD/TODO; every code step shows full code; commands carry expected output. The §8 `d_now` open question is resolved (it exists: `lib/dispatch-lib.sh:13`).

**Type/name consistency:** `claude_local_env_argv` sets `CL_ENV`; `claude_local_exec`/`claude_local_run` both consume it; `CL_MODEL`/`CL_URL`/`CL_SMALL` come from `claude_local_resolve` (unchanged). `run_cell` calls `d_sc_get`/`d_commit_worktree`/`d_sc_set`/`d_sidecar_dir`/`d_now` — all confirmed in `lib/dispatch-lib.sh`. Sidecar fields `.backend`/`.model` match what the cell test asserts and what `codex-run` uses. Contestant `{backend:'claude-local', model:'qwen3-coder-30b'}` strings match the lint assertions.

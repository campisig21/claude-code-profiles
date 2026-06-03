# local-llama profile — local-inference steward — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Equip the `local-llama` Claude Code profile with steward skills + persona for the remote llama.cpp fleet, split the codex backend into interactive (`local`) and Claude-driven (`local-headless`) profiles, and add the `--ensure-up` flag and `local-ask` one-shot wrapper.

**Architecture:** Two halves. **Phase A (engine, codex implements, TDD):** additive changes to the mature `codex_dispatch.sh` subsystem — repoint the local backend default to `local-headless`, teach `install.sh` to write that profile, add an opt-in `--ensure-up` readiness flag and a `local-ask` PATH tool for no-repo one-shots. **Phase B (knowledge, Claude writes):** the profile persona + four single-purpose skills that teach the mental model and pull live specifics over SSH/HTTP, with the workstation `~/docker/llama/AGENTS.md` staying canonical.

**Tech Stack:** Pure bash; the dependency-free test harness (`tests/lib.sh` + `tests/run.sh`, fake `codex`/`ssh`/repo doubles); codex 0.136 file-overlay profiles (`$CODEX_HOME/<name>.config.toml`); llama.cpp router-mode `/v1`; Claude Code profile skills (`SKILL.md` frontmatter).

**Spec:** `docs/specs/2026-06-02-local-llama-profile-design.md`

---

## File Structure

**Phase A — codex engine (repo: `~/.claude/profile-system/`):**
- Modify `lib/dispatch.sh` — `d_backend_args` default profile `local` → `local-headless`.
- Modify `codex_dispatch.sh` — `--ensure-up` flag in `cmd_quick` + `cmd_dispatch`; updated refusal message.
- Create `bin/local-ask` — no-repo one-shot wrapper (readiness + headless preamble + `codex exec`).
- Modify `install.sh` — write `local-headless` codex profile (file overlay + `[profiles.local-headless]` table for back-compat); symlink `bin/local-ask` onto PATH.
- Modify tests: `dispatch_backend_test.sh`, `dispatch_local_preflight_test.sh`, `install_test.sh`.
- Create tests: `dispatch_ensure_up_test.sh`, `local_ask_test.sh`.

**Phase A — codex profiles (user home: `$CODEX_HOME` = `~/.codex/`):**
- Keep `local.config.toml` as the **interactive** profile (TUI retained).
- Create `local-headless.config.toml` as the **Claude-driven** profile (no TUI, lean). Written by `install.sh`.

**Phase B — profile (`~/.claude/profiles/local-llama/`):**
- Modify `CLAUDE.md` — steward persona.
- Create `skills/local-fleet-ops/SKILL.md`.
- Create `skills/local-model-selection/SKILL.md`.
- Create `skills/local-codex-backend/SKILL.md`.
- Create `skills/local-model-acquisition/SKILL.md`.

---

# Phase A — codex engine (codex implements, TDD)

> Run all engine tests with: `bash ~/.claude/profile-system/tests/run.sh`
> Run one file with: `bash ~/.claude/profile-system/tests/<name>_test.sh`

### Task 1: Write the `local-headless` codex profile via install.sh

**Files:**
- Modify: `install.sh` (codex-config region, ~lines 66–104)
- Test: `tests/install_test.sh`

- [ ] **Step 1: Update the install_test assertions to expect the headless profile**

In `tests/install_test.sh`, replace the existing `[profiles.local]` block of assertions with the headless-profile expectations (file overlay is what codex 0.136 `-p` loads; the in-config table is kept for back-compat):

```bash
PROF="$CODEX_HOME/config.toml"
HEADLESS="$CODEX_HOME/local-headless.config.toml"
assert_file "$PROF" "codex config.toml written"
assert_file "$HEADLESS" "local-headless.config.toml overlay written"
assert_contains "$(cat "$PROF" 2>/dev/null)" '[model_providers.llamacpp]' "config declares llamacpp provider"
assert_contains "$(cat "$PROF" 2>/dev/null)" 'wire_api = "responses"' "provider uses responses wire_api"
# Claude-driven profile (file overlay loaded by `codex -p local-headless`)
assert_contains "$(cat "$HEADLESS" 2>/dev/null)" 'model = "qwen36-35b"' "headless profile pins the qwen36-35b alias"
assert_contains "$(cat "$HEADLESS" 2>/dev/null)" 'model_provider = "llamacpp"' "headless profile uses llamacpp provider"
assert_contains "$(cat "$HEADLESS" 2>/dev/null)" 'model_context_window' "headless profile supplies ctx metadata"
if grep -q '^\[tui\]' "$HEADLESS"; then echo "  FAIL: headless profile must not carry TUI config"; exit 1; fi
if grep -q '^env_key' "$HEADLESS"; then echo "  FAIL: headless profile must not set an env_key"; exit 1; fi
# back-compat table inside config.toml (harmless on 0.136, required on 0.135)
assert_contains "$(cat "$PROF" 2>/dev/null)" '[profiles.local-headless]' "config declares [profiles.local-headless] for 0.135 -p"
```

Also update the idempotence assertions further down to reference `local-headless`:

```bash
assert_eq "$(grep -c '^\[profiles\.local-headless\]' "$PROF")" "1" "no duplicate [profiles.local-headless] on rerun"
assert_eq "$(grep -c '^\[model_providers\.llamacpp\]' "$PROF")" "1" "no duplicate llamacpp provider on rerun"
```

(Delete the old `[profiles.local]`-named assertions that this replaces.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash ~/.claude/profile-system/tests/install_test.sh`
Expected: FAIL — `local-headless.config.toml overlay written` (file missing) and `[profiles.local-headless]` not found.

- [ ] **Step 3: Update install.sh to write the headless profile (file + table)**

In `install.sh`, change `LOCAL_PROFILE_NAME` default and write BOTH a file overlay and the in-config table. Replace the `if grep -q "^\[profiles\.${LOCAL_PROFILE_NAME}\]" ...` block with:

```bash
LOCAL_PROFILE_NAME="${CODEX_DISPATCH_LOCAL_PROFILE:-local-headless}"

# File overlay — this is what `codex -p <name>` loads on codex 0.136.
HEADLESS_OVERLAY="$CODEX_HOME_DIR/${LOCAL_PROFILE_NAME}.config.toml"
if [ -e "$HEADLESS_OVERLAY" ]; then
  echo "  codex ${LOCAL_PROFILE_NAME}.config.toml exists (left untouched)"
else
  cat > "$HEADLESS_OVERLAY" <<TOML
# Claude-driven (headless) codex profile — selected by:  codex -p ${LOCAL_PROFILE_NAME}
# Used by --backend local (codex_dispatch.sh) and bin/local-ask. No TUI: this
# profile never drives an interactive session — that is the separate 'local' profile.
model                = "${CODEX_DISPATCH_LOCAL_MODEL:-qwen36-35b}"
model_provider       = "llamacpp"
model_context_window = ${CODEX_DISPATCH_LOCAL_CTX:-262144}

[model_providers.llamacpp]
name     = "llama.cpp (workstation)"
base_url = "${CODEX_DISPATCH_LOCAL_ENDPOINT:-http://100.64.0.4:8080/v1}"
wire_api = "responses"
TOML
  echo "  wrote $HEADLESS_OVERLAY"
fi

# Back-compat: also declare the table inside config.toml (codex 0.135 -p path).
if grep -q "^\[profiles\.${LOCAL_PROFILE_NAME}\]" "$CODEX_CONFIG"; then
  echo "  codex config already declares [profiles.${LOCAL_PROFILE_NAME}] (left untouched)"
else
  cat >> "$CODEX_CONFIG" <<TOML

[profiles.${LOCAL_PROFILE_NAME}]
model = "${CODEX_DISPATCH_LOCAL_MODEL:-qwen36-35b}"
model_provider = "llamacpp"
model_context_window = ${CODEX_DISPATCH_LOCAL_CTX:-262144}
TOML
  echo "  added [profiles.${LOCAL_PROFILE_NAME}] to $CODEX_CONFIG"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash ~/.claude/profile-system/tests/install_test.sh`
Expected: PASS (ends with `(N checks, 0 failed)` and exit 0).

- [ ] **Step 5: Commit**

```bash
cd ~/.claude/profile-system
git add install.sh tests/install_test.sh
git commit -m "feat(local): install writes local-headless codex profile (file + table)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Repoint the local backend default profile to `local-headless`

**Files:**
- Modify: `lib/dispatch.sh:92-96` (`d_backend_args`)
- Test: `tests/dispatch_backend_test.sh`, `tests/dispatch_local_preflight_test.sh`

- [ ] **Step 1: Update the resolver test to expect the new default**

In `tests/dispatch_backend_test.sh`, change the default-profile assertion:

```bash
assert_eq "$(d_backend_args local)" "-p local-headless" "local backend -> -p <headless profile>"
```

(Leave the `CODEX_DISPATCH_LOCAL_PROFILE=ws` override assertion as-is — it must still print `-p ws`.)

In `tests/dispatch_local_preflight_test.sh`, update the quick iterate-hint assertion:

```bash
assert_contains "$out" "resume --last -p local-headless" "quick local iterate hint carries the backend"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash ~/.claude/profile-system/tests/dispatch_backend_test.sh`
Expected: FAIL — `local backend -> -p <headless profile>`: expected [-p local-headless], got [-p local].

- [ ] **Step 3: Change the default in d_backend_args**

In `lib/dispatch.sh`, edit the `local)` branch:

```bash
    local) printf '%s %s' '-p' "${CODEX_DISPATCH_LOCAL_PROFILE:-local-headless}" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash ~/.claude/profile-system/tests/dispatch_backend_test.sh ; bash ~/.claude/profile-system/tests/dispatch_local_preflight_test.sh`
Expected: both PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
cd ~/.claude/profile-system
git add lib/dispatch.sh tests/dispatch_backend_test.sh tests/dispatch_local_preflight_test.sh
git commit -m "feat(local): default --backend local to the local-headless profile

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Add the opt-in `--ensure-up` flag to quick + dispatch

**Files:**
- Modify: `codex_dispatch.sh` (`cmd_quick` flag loop + local preflight; `cmd_dispatch` flag loop + local preflight)
- Test: `tests/dispatch_ensure_up_test.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `tests/dispatch_ensure_up_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
fssh="$(ps_make_fake_ssh)"
repo="$(ps_make_sandbox_repo)"

# 1. Without --ensure-up, refusal now also advertises the flag.
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        bash "$ENGINE" quick --backend local "x" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "quick local still refused when not ready and no --ensure-up"
assert_contains "$out" "--ensure-up" "refusal advertises --ensure-up"

# 2. With --ensure-up and not ready, l_up IS invoked (then times out under fake ssh).
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=up-not-loaded \
        CODEX_DISPATCH_SSH_BIN="$fssh" CODEX_DISPATCH_LOCAL_POLL_TIMEOUT=1 CODEX_DISPATCH_LOCAL_POLL_INTERVAL=1 \
        bash "$ENGINE" quick --backend local --ensure-up "x" 2>&1 )"; rc=$?
assert_contains "$out" "local-up:" "--ensure-up invokes l_up when not ready"

# 3. With --ensure-up and already ready, proceeds normally (no l_up needed).
qlog="$PS_SANDBOX/eu.log"; : > "$qlog"
out="$( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=ready \
        FAKE_CODEX_ARGV_LOG="$qlog" bash "$ENGINE" quick --backend local --ensure-up "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "quick local --ensure-up proceeds when already ready"
assert_contains "$(cat "$qlog")" "-p local-headless" "still uses the headless profile"

# 4. dispatch also accepts --ensure-up when ready.
out="$( cd "$repo" && CODEX_DISPATCH_NOW=20260603T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
        CODEX_DISPATCH_FAKE_STATE=ready \
        bash "$ENGINE" dispatch --backend local --ensure-up --verify checks --check 'bash check.sh' --slug eu "x" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "dispatch local --ensure-up proceeds when ready"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash ~/.claude/profile-system/tests/dispatch_ensure_up_test.sh`
Expected: FAIL — `refusal advertises --ensure-up` (old message) and `unknown flag: --ensure-up`.

- [ ] **Step 3: Implement --ensure-up in cmd_quick**

In `codex_dispatch.sh` `cmd_quick`, add `ensure_up=0` to the locals and a flag case:

```bash
  local verify=none snapshot=0 backend=codex ensure_up=0
```
```bash
      --ensure-up) ensure_up=1; shift;;
```

Then replace the local readiness preflight block:

```bash
  if [ "$backend" = local ]; then
    if ! l_ready; then
      if [ "$ensure_up" -eq 1 ]; then
        l_up || die "ensure-up failed to make local ready (state: $(l_probe))"
      else
        die "local model not ready (state: $(l_probe)). Load it first:  codex_dispatch.sh local-up  (or pass --ensure-up)"
      fi
    fi
  fi
```

- [ ] **Step 4: Implement the same in cmd_dispatch**

In `codex_dispatch.sh` `cmd_dispatch`, add `ensure_up=0` to the locals, add the same `--ensure-up) ensure_up=1; shift;;` flag case, and replace its local readiness block with the identical block from Step 3.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash ~/.claude/profile-system/tests/dispatch_ensure_up_test.sh`
Expected: PASS, `0 failed`.

- [ ] **Step 6: Run the full suite (no regressions)**

Run: `bash ~/.claude/profile-system/tests/run.sh`
Expected: `=== N/N test files passed ===`, exit 0.

- [ ] **Step 7: Commit**

```bash
cd ~/.claude/profile-system
git add codex_dispatch.sh tests/dispatch_ensure_up_test.sh
git commit -m "feat(local): opt-in --ensure-up flag loads the model before quick/dispatch

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Add the `local-ask` no-repo one-shot wrapper

**Files:**
- Create: `bin/local-ask`
- Modify: `install.sh` (PATH symlink, mirroring the `ccp` block)
- Test: `tests/local_ask_test.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `tests/local_ask_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ASK="$PS_REPO_ROOT/bin/local-ask"
fake="$(ps_make_fake_codex)"

# usage error with no args
out="$( bash "$ASK" 2>&1 )"; rc=$?
assert_eq "$rc" "2" "no args -> usage exit 2"
assert_contains "$out" "usage" "prints usage"

# ready: threads -p local-headless, --skip-git-repo-check, bypass, preamble, and the prompt
log="$PS_SANDBOX/ask.log"; : > "$log"
out="$( CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$log" \
        bash "$ASK" "what is 2+2?" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "ready -> succeeds"
argv="$(cat "$log")"
assert_contains "$argv" "exec"                  "calls codex exec"
assert_contains "$argv" "-p local-headless"     "uses the headless profile"
assert_contains "$argv" "--skip-git-repo-check" "skips the git-repo check (no repo needed)"
assert_contains "$argv" "--dangerously-bypass-approvals-and-sandbox" "runs autonomously"
assert_contains "$argv" "one-shot"              "injects the headless preamble"
assert_contains "$argv" "what is 2+2?"          "passes the question"

# profile override honored
log2="$PS_SANDBOX/ask2.log"; : > "$log2"
( CODEX_DISPATCH_CODEX_BIN="$fake" CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$log2" \
  LOCAL_ASK_PROFILE=ws bash "$ASK" "x" >/dev/null 2>&1 )
assert_contains "$(cat "$log2")" "-p ws" "LOCAL_ASK_PROFILE override honored"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash ~/.claude/profile-system/tests/local_ask_test.sh`
Expected: FAIL — `bin/local-ask` does not exist (cannot execute).

- [ ] **Step 3: Create bin/local-ask**

Create `bin/local-ask`:

```bash
#!/usr/bin/env bash
# local-ask — one-shot delegation to the local model from ANY session.
# No git repo needed (unlike codex_dispatch.sh quick/dispatch). Ensures the
# model is loaded, then runs a headless `codex exec` against the Claude-driven
# profile with a concise-output preamble.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/local.sh"

CODEX_BIN="${CODEX_DISPATCH_CODEX_BIN:-codex}"
PROFILE="${LOCAL_ASK_PROFILE:-local-headless}"
PREAMBLE="You are a one-shot subagent invoked by another agent. Answer concisely and return only the result — no preamble, no follow-up questions. "

[ "$#" -ge 1 ] || { echo "usage: local-ask \"<question or task>\"" >&2; exit 2; }
prompt="$*"

if ! l_ready; then
  l_up || { echo "local-ask: could not make the local model ready (state: $(l_probe))" >&2; exit 1; }
fi

exec "$CODEX_BIN" exec -p "$PROFILE" --skip-git-repo-check \
  --dangerously-bypass-approvals-and-sandbox "${PREAMBLE}${prompt}"
```

Make it executable:

```bash
chmod +x ~/.claude/profile-system/bin/local-ask
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash ~/.claude/profile-system/tests/local_ask_test.sh`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Symlink local-ask onto PATH in install.sh**

In `install.sh`, just after the `ccp` PATH block (inside the same `if [ "${CCP_SKIP_PATH:-0}" != "1" ]; then` guard), add:

```bash
    ln -sfn "$SRC/bin/local-ask" "$HOME/.local/bin/local-ask"
    echo "  Linked local-ask -> $HOME/.local/bin/local-ask"
```

- [ ] **Step 6: Run the full suite**

Run: `bash ~/.claude/profile-system/tests/run.sh`
Expected: `=== N/N test files passed ===`, exit 0.

- [ ] **Step 7: Commit**

```bash
cd ~/.claude/profile-system
git add bin/local-ask install.sh tests/local_ask_test.sh
git commit -m "feat(local): local-ask one-shot wrapper for no-repo delegation to local

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Apply install.sh + live-verify the codex profiles

**Files:** none (runs the updated installer against the real `~/.codex`, then smoke-tests)

- [ ] **Step 1: Re-run the installer (writes the headless profile for real)**

Run: `bash ~/.claude/profile-system/install.sh`
Expected output includes: `wrote /Users/gregorycampisi/.codex/local-headless.config.toml` and `Linked local-ask -> …/.local/bin/local-ask`.

- [ ] **Step 2: Ensure the interactive `local` profile still exists (it predates this work)**

Run: `test -f ~/.codex/local.config.toml && echo INTERACTIVE_OK`
Expected: `INTERACTIVE_OK`. (If missing, copy from the headless file and re-add its `[tui]` section — the interactive profile keeps TUI; the headless one must not.)

- [ ] **Step 3: Live smoke — headless profile resolves and answers (model is loaded now)**

Run: `local-ask "Reply with exactly: PONG"`
Expected: the model replies (contains `PONG`). This proves `-p local-headless` resolves on codex 0.136 and the tailnet path works.

- [ ] **Step 4: Live smoke — quick uses the headless profile end-to-end (in a throwaway repo)**

Run:
```bash
d=$(mktemp -d) && git -C "$d" init -q && echo seed > "$d/README.md" && git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -qm seed
( cd "$d" && codex_dispatch.sh quick --backend local "append a line 'hello' to README.md" )
rm -rf "$d"
```
Expected: a diff shows `hello` added; no readiness refusal (model already loaded).

- [ ] **Step 5: Commit (only if Step 2 required editing a tracked file; otherwise skip)**

```bash
cd ~/.claude/profile-system && git status --short
# commit only if a tracked file changed
```

---

# Phase B — knowledge layer (Claude writes)

> Skills live at `~/.claude/profiles/local-llama/skills/<name>/SKILL.md`. Each
> SKILL.md starts with YAML frontmatter (`name`, `description`) then the body.
> Every skill ENDS with a "Source of truth" footer pointing at the canonical
> file(s). Skills must **pull live data**, not embed the roster table.

### Task 6: Profile persona — `CLAUDE.md`

**Files:**
- Modify: `~/.claude/profiles/local-llama/CLAUDE.md`

- [ ] **Step 1: Rewrite the persona (replace the stub body, keep the `@curator/INDEX.md` include line)**

Write `~/.claude/profiles/local-llama/CLAUDE.md` containing, concretely:
- One-line identity: *steward of the user's local inference stack and its codex `local` backend.*
- `@curator/INDEX.md` include (preserve at top, as the stub has it).
- **The stack (invariants):** workstation `greg-campisi@100.64.0.4` over a headscale tailnet; 2× RTX 3090 / 48 GB VRAM, NVLink; Docker llama.cpp **router mode**, OpenAI `/v1` at `:8080`; GGUFs in `/models/gguf/`; canonical operator doc `~/docker/llama/AGENTS.md` (never duplicate its roster here — pull/cross-reference).
- **Two access types:** (1) interactive `codex -p local`; (2) Claude-driven one-shot — `codex_dispatch.sh quick|dispatch --backend local` for repo work, `local-ask "…"` for no-repo. Both Claude-driven paths use the `local-headless` profile.
- **Operating style:** thin + pull-live (always read live `/v1/models`/VRAM before asserting fleet state); AGENTS.md is canonical.
- **Dev process:** Claude reasons/plans; codex implements (`/codex-implement`).

- [ ] **Step 2: Verify it loads**

Run: `head -40 ~/.claude/profiles/local-llama/CLAUDE.md`
Expected: persona content present; the `@curator/INDEX.md` line retained.

- [ ] **Step 3: Commit** (the profile dir may be its own git repo or untracked; commit only if tracked)

```bash
cd ~/.claude/profiles/local-llama && git rev-parse --is-inside-work-tree 2>/dev/null && git add CLAUDE.md && git commit -m "feat(local-llama): steward persona" || echo "profile dir untracked — skipping commit"
```

---

### Task 7: Skill — `local-fleet-ops`

**Files:**
- Create: `~/.claude/profiles/local-llama/skills/local-fleet-ops/SKILL.md`

- [ ] **Step 1: Write the skill**

Frontmatter (exact):
```yaml
---
name: local-fleet-ops
description: Use when operating the local llama.cpp fleet on the workstation — checking what's loaded, loading/swapping/restarting models, inspecting VRAM, switching presets, or diagnosing the router. Pulls live state over SSH/HTTP.
---
```
Body must concretely include:
- **Mental model:** router mode (b9209+, experimental), LRU eviction at `MODELS_MAX`, **no unload endpoint**, presets select which GGUFs are addressable, `--split-mode row` + `--tensor-split 1,1` (server-wide, two equal 3090s, NVLink).
- **Pull live state first (commands):**
  - `curl -s --max-time 6 http://100.64.0.4:8080/v1/models | jq -r '.data[] | "\(.id)\t\(.status.value)"'`
  - over SSH: `ssh greg-campisi@100.64.0.4 'source ~/docker/llama/llama-control.sh; llama_status; llama_vram'`
- **Lifecycle (via `llama-control.sh` over SSH):** `llama_preload <alias>`, `llama_ping <alias>`, `llama_preset <name>`, `llama_models_max <N>`, `llama_restart`, `llama_stop`, `llama_up`, `llama_logs`.
- **The no-unload reality + workaround:** `llama_unload` is best-effort LRU eviction (only works at `MODELS_MAX` cap, needs a spare evictor); the only guaranteed unload is `llama_restart`.
- **The qwen36 fatal-OOM trap (call out prominently):** `--tensor-split 1,1` disables auto-fit, so loading a model that doesn't fit is **fatal, not adaptive** (router retry-OOMs ~27 min). Big models get their own `MODELS_MAX=1` preset (`qwen36-only`) — never rely on eviction to fit them.
- **Source of truth footer:** `~/docker/llama/AGENTS.md`, `~/docker/llama/llama-control.sh`, `presets/*.ini` (canonical — pull from these; do not copy the roster here).

- [ ] **Step 2: Verify frontmatter parses**

Run: `head -5 ~/.claude/profiles/local-llama/skills/local-fleet-ops/SKILL.md`
Expected: valid `name:` and `description:` keys between `---` fences.

---

### Task 8: Skill — `local-model-selection`

**Files:**
- Create: `~/.claude/profiles/local-llama/skills/local-model-selection/SKILL.md`

- [ ] **Step 1: Write the skill**

Frontmatter (exact):
```yaml
---
name: local-model-selection
description: Use when choosing which local model to run for a task — reasoning vs no-thinking, long context, smallest-that-works — or when a local model is "thinking" when it shouldn't. Pulls the live roster and maps task to alias.
---
```
Body must concretely include:
- **Pull the live roster first:** `curl -s http://100.64.0.4:8080/v1/models` then cross-reference roles in `~/docker/llama/AGENTS.md` (do not hardcode the table — it drifts).
- **Role guidance (as of canonical AGENTS.md; verify live):** heavy reasoning → `qwopus-27b` or the 35B MoE `qwen36-35b` (128K+ ctx, on-demand, evicts others); genuine **no-thinking** aux/long-context → `llama31-8b` (~64K ctx); small no-think fallback → `qwen25-7b`; small reasoning → `qwen-9b` / `qwen-4b`.
- **Thinking-template gotcha (prominent):** Qwen3.5 / Qwopus custom fine-tunes **always think** — `chat_template_kwargs.enable_thinking:false` is **inert** (template ignores it), `/no_think` only partially helps, `reasoning.effort=none` can make it *worse*. For truly no-reasoning work use `llama31-8b` or `qwen25-7b` (confirmed `reasoning_content` length 0).
- **`max_tokens` budgeting:** reasoning eats the budget — size to ~100–300 reasoning + content tokens; even a 6-word title needs `max_tokens ≥ 200` on a thinking model.
- **Coexistence note:** `qwen36-35b` (~33 GB) cannot coexist with `qwopus-27b` in 48 GB — selecting it implies a preset/eviction cost (see `local-fleet-ops`).
- **Source of truth footer:** `~/docker/llama/AGENTS.md` "Current model lineup" + "Known gotchas".

- [ ] **Step 2: Verify frontmatter parses**

Run: `head -5 ~/.claude/profiles/local-llama/skills/local-model-selection/SKILL.md`
Expected: valid `name:`/`description:`.

---

### Task 9: Skill — `local-codex-backend`

**Files:**
- Create: `~/.claude/profiles/local-llama/skills/local-codex-backend/SKILL.md`

- [ ] **Step 1: Write the skill**

Frontmatter (exact):
```yaml
---
name: local-codex-backend
description: Use when running codex against the local model — interactively, or delegating a one-shot/agentic task from another Claude session ("offload to local", "use the local model with codex"). Covers profiles, readiness, and quick vs dispatch.
---
```
Body must concretely include:
- **The two access types, one mechanism:**
  - **Interactive (you):** `codex -p local` (TUI, human-in-the-loop; the `local` profile keeps `[tui]`).
  - **Claude-driven (headless), in a repo:** `codex_dispatch.sh quick --backend local "…"` (edits in place, uncommitted) or `dispatch --backend local "…"` (isolated worktree + checks + Claude-gated `land`). Both use the `local-headless` profile.
  - **Claude-driven, no repo:** `local-ask "…"` (no git repo required; injects a concise-output preamble).
- **quick vs dispatch (the harness difference, not a profile difference):** both make the *same* headless `codex exec` call; `quick` = in-place, no lifecycle; `dispatch` = worktree + verify + land/abandon/resume.
- **Readiness:** local backends refuse when the model isn't loaded (`state: up-not-loaded|unreachable`) and tell you to run `codex_dispatch.sh local-up`; pass `--ensure-up` to load it first (note: loading `qwen36-only` takes ~30–90s and evicts the rest of the fleet). `local-ask` ensures readiness automatically.
- **local vs codex-cloud guidance:** local for cheap/offline/privacy-bound subtasks; codex-cloud (default `--backend codex`) for heavier or higher-stakes work.
- **Config locations:** `~/.codex/local.config.toml` (interactive), `~/.codex/local-headless.config.toml` (Claude-driven), `profile-system/lib/local.sh` (lifecycle), `profile-system/codex_dispatch.sh` (engine), `CODEX_DISPATCH_LOCAL_*` env overrides.
- **Source of truth footer:** `profile-system/docs/specs/2026-06-02-local-llama-profile-design.md`, `lib/local.sh`, the two `~/.codex/*.config.toml`.

- [ ] **Step 2: Verify frontmatter parses**

Run: `head -5 ~/.claude/profiles/local-llama/skills/local-codex-backend/SKILL.md`
Expected: valid `name:`/`description:`.

---

### Task 10: Skill — `local-model-acquisition`

**Files:**
- Create: `~/.claude/profiles/local-llama/skills/local-model-acquisition/SKILL.md`

- [ ] **Step 1: Write the skill**

Frontmatter (exact):
```yaml
---
name: local-model-acquisition
description: Use when adding or updating a local model from HuggingFace — picking a GGUF/quant, sizing it against VRAM, downloading it to the workstation, registering a preset alias, and verifying. 
---
```
Body must concretely include:
- **Source GGUFs:** prefer `bartowski/*` and `unsloth/*-GGUF` (direct curl with HTTP 302 follow). For accuracy-per-byte prefer unsloth **UD "Dynamic 2.0"** quants (`UD-Q6_K_XL`, `UD-Q8_K_XL`).
- **Size it first:** pull free VRAM (`llama_vram` over SSH); budget = weights + KV cache per loaded model + flash-attn overhead; **leave 4–8 GB headroom** for KV growth at long contexts. 48 GB total across the two 3090s.
- **Procedure (per AGENTS.md):**
  1. `curl -L` the GGUF into `/models/gguf/` on the workstation.
  2. Add an `[alias]` block to `presets/concurrent.ini` (set `model =`, `ctx-size =`, decide `load-on-startup`).
  3. `llama_restart` (env/preset only re-read at start).
  4. `llama_ping <alias>` to smoke-test (use `max_tokens ≥ 200` for thinking models).
  5. **Update the lineup table in `~/docker/llama/AGENTS.md`** (canonical).
- **Large-model caveat:** a model that can't coexist needs its own `MODELS_MAX=1` preset (see the qwen36-only pattern) — don't rely on LRU eviction (fatal OOM trap).
- **Source of truth footer:** `~/docker/llama/AGENTS.md` "When asked to add a new model", `presets/*.ini`.

- [ ] **Step 2: Verify frontmatter parses**

Run: `head -5 ~/.claude/profiles/local-llama/skills/local-model-acquisition/SKILL.md`
Expected: valid `name:`/`description:`.

---

### Task 11: Live verification — skills trigger and pull real data

**Files:** none (manual smoke in a fresh `local-llama` session)

- [ ] **Step 1: Launch the profile session**

Run: `ccp local-llama`

- [ ] **Step 2: Trigger each skill and confirm it loads + uses live data**

Ask, one per turn, and confirm the matching skill activates and reads live state (not a stale table):
- "what's loaded on the local fleet right now?" → `local-fleet-ops`, shows live `/v1/models`.
- "which local model should I use for a no-thinking long-context summary?" → `local-model-selection`, recommends `llama31-8b`.
- "offload this question to the local model" → `local-codex-backend`, uses `local-ask`/`quick --backend local`.
- "add the gemma-4 31B gguf to the fleet" → `local-model-acquisition`, gives the bartowski/unsloth + preset procedure.

- [ ] **Step 3: Confirm no embedded-roster drift**

Grep the skills for a hardcoded roster table:
```bash
grep -rl "Qwopus3.5-27B" ~/.claude/profiles/local-llama/skills/ && echo "DRIFT: roster embedded — remove" || echo "OK: no embedded roster"
```
Expected: `OK: no embedded roster`.

- [ ] **Step 4: Commit the skills + persona** (if the profile dir is a git repo)

```bash
cd ~/.claude/profiles/local-llama && git rev-parse --is-inside-work-tree 2>/dev/null \
  && git add CLAUDE.md skills && git commit -m "feat(local-llama): steward skills (fleet-ops, selection, codex-backend, acquisition)" \
  || echo "profile dir untracked — skipping commit"
```

---

## Self-Review

**Spec coverage:**
- Persona → Task 6. ✓
- Two codex profiles (interactive `local` + Claude-driven `local-headless`) → Tasks 1, 5. ✓
- Repoint dispatch default → Task 2. ✓
- `--ensure-up` → Task 3. ✓
- `local-ask` no-repo one-shot → Task 4. ✓
- 4 skills (fleet-ops, selection, codex-backend, acquisition) → Tasks 7–10. ✓
- Thin + pull-live / no embedded roster → enforced in every skill task + Task 11 Step 3. ✓
- Source-of-truth footers → every skill task. ✓
- Live verification → Tasks 5, 11. ✓

**Placeholder scan:** No TBD/TODO. Engine tasks carry full test + implementation code. Skill tasks carry exact frontmatter + concrete required facts/commands (the prose-writing is the act; the material is specified, not deferred).

**Type/name consistency:** profile name `local-headless` used consistently (d_backend_args default, install.sh `LOCAL_PROFILE_NAME`, local-ask `LOCAL_ASK_PROFILE` default, all tests, skills). `local` reserved for interactive throughout. Env seams (`CODEX_DISPATCH_LOCAL_PROFILE`, `CODEX_DISPATCH_FAKE_STATE`, `CODEX_DISPATCH_SSH_BIN`, `FAKE_CODEX_ARGV_LOG`) match `lib/local.sh` and `tests/lib.sh`.

**Known risk flagged:** codex 0.135 (`[profiles.local-headless]` in config.toml) vs 0.136 (file overlay) — Task 1 writes both forms; Task 5 Step 3 live-smokes resolution before anything depends on it.

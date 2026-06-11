# Subsystem D — Phase 1 (De-personalization + Ollama backend) — Implementation Plan

> **For agentic workers:** Implemented via the project's **Claude-plans / codex-implements** process. Each task is a self-contained, independently-verifiable unit suitable for `/codex-implement` dispatch (`codex_dispatch.sh dispatch --verify checks --check 'bash tests/run.sh' …`), Claude-gated landing. Steps use checkbox (`- [ ]`) syntax. Tasks are ordered so each leaves `tests/run.sh` green.

**Goal:** Make the local-LLM backend usable by a stranger. Two outcomes: (1) a bare `install.sh` no longer writes any author endpoint into a user's `~/.codex` (local-LLM becomes opt-in); (2) **Ollama** is a first-class local backend, selected at runtime, dispatched into codex via its native `--oss --local-provider ollama` path. The author's llama.cpp-remote rig keeps working as an env-driven backend with zero hardcoded personal values.

**Architecture:** `lib/local.sh` becomes a thin **facade** that sources `lib/local-<backend>.sh` per `CODEX_DISPATCH_LOCAL_BACKEND` (default `llamacpp`, preserving today's behavior). The current lifecycle moves verbatim into `lib/local-llamacpp.sh`; a new `lib/local-ollama.sh` implements the same `l_probe/l_ready/l_up/l_down` interface against Ollama's native API plus an `ollama_chat` primitive. `lib/dispatch.sh` learns `--backend ollama`. `install.sh` gains `--with-local[=ollama|llamacpp]`; absent it, the codex-config step is skipped entirely. Author values are removed from code defaults and shipped as a committed `.example` overlay.

**Tech Stack:** bash (sourced libs, `set -euo pipefail`), `jq`, codex 0.136 (`--oss --local-provider ollama`). Tests: the repo's dependency-free bash harness (`tests/lib.sh`, `tests/run.sh`), sandbox-isolated, with HTTP stubbed via `CODEX_DISPATCH_CURL_BIN` and state via `CODEX_DISPATCH_FAKE_STATE`.

**Spec:** `docs/specs/2026-06-10-portability-productization-design.md` (§5.1 D.1, §5.2 D.2).

---

## File structure (created / modified)

| File | New/Mod | Responsibility |
|---|---|---|
| `lib/local.sh` | Rewrite | Thin facade: `source lib/local-${CODEX_DISPATCH_LOCAL_BACKEND:-llamacpp}.sh`. No logic of its own. |
| `lib/local-llamacpp.sh` | New | The current `lib/local.sh` lifecycle, **verbatim**, with author values demoted to env (neutral defaults). |
| `lib/local-ollama.sh` | New | `l_*` interface against Ollama native API (`/api/ps`, `/api/tags`, `/api/chat`) + `ollama_chat` (§5.2). |
| `templates/local-headless.config.toml.example` | New | The llama.cpp overlay with `${...}` placeholders — no real endpoint/model. |
| `lib/dispatch.sh` | Mod | `d_backend_args ollama` → `--oss --local-provider ollama -m "$(l_model)"` (§5.2). |
| `lib/install-common.sh` | Mod | Gate the codex-config block (step 6) behind opt-in; no writes by default (§5.1). |
| `install.sh` | Mod | Parse `--with-local[=ollama|llamacpp]`; export selection for the common core. |
| `tests/*` | New/Mod | Per-task; all registered in `tests/run.sh`. |

**Conventions (from the repo):** sourced bash libs; `set -euo pipefail`; tests via `tests/lib.sh` (`assert_eq/assert_file/assert_contains`, `ps_setup_sandbox`, `ps_report`) added to `tests/run.sh`; sandbox root `CC_PROFILE_ROOT`, codex home `CODEX_HOME`; HTTP seam `CODEX_DISPATCH_CURL_BIN`, state seam `CODEX_DISPATCH_FAKE_STATE`; atomic writes tmp+`mv`.

---

## Task 1 — Backend facade: split `lib/local.sh` → `lib/local-llamacpp.sh` (no behavior change)

**Files:** Rewrite `lib/local.sh`; New `lib/local-llamacpp.sh`; existing `tests/local_lifecycle_test.sh` must stay green unchanged.

- [ ] **Step 1: Move logic.** Copy the entire current body of `lib/local.sh` (the `l_endpoint/l_model/l_ssh_tgt/l_probe/l_ready/l_up_cmd/l_down_cmd/l_preload/l_up/l_down` functions) verbatim into `lib/local-llamacpp.sh`.
- [ ] **Step 2: Facade.** Replace `lib/local.sh` with:
  ```bash
  #!/usr/bin/env bash
  # lib/local.sh — backend facade. Sources the selected local-LLM backend so all
  # consumers (codex dispatch, local-ask, MCP, curator) share one interface.
  : "${CODEX_DISPATCH_LOCAL_BACKEND:=llamacpp}"
  _here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  source "$_here/local-${CODEX_DISPATCH_LOCAL_BACKEND}.sh"
  ```
- [ ] **Step 3: Verify** `bash tests/local_lifecycle_test.sh` and `bash tests/run.sh` stay green (default backend = llamacpp ⇒ identical behavior). No new test needed; this is a refactor under existing coverage.

## Task 2 — `lib/local-ollama.sh`: the Ollama backend

**Files:** New `lib/local-ollama.sh`; Test `tests/local_ollama_test.sh` (new; add to `tests/run.sh`).

Ollama uses the **native** API (not `/v1`): `GET /api/ps` (loaded), `GET /api/tags` (installed), `POST /api/chat`. Endpoint `${OLLAMA_HOST:-http://localhost:11434}`. Lifecycle is lighter than llama.cpp — no docker/preset; `l_down` unloads via `ollama stop`.

- [ ] **Step 1: Write the failing test** — `tests/local_ollama_test.sh`
  ```bash
  #!/usr/bin/env bash
  set -uo pipefail
  source "$(dirname "$0")/lib.sh"
  ps_setup_sandbox
  export CODEX_DISPATCH_LOCAL_BACKEND=ollama
  export OLLAMA_HOST="http://localhost:11434"
  export CODEX_DISPATCH_LOCAL_MODEL="qwen2.5-coder"
  # stub curl: /api/ps returns the model as loaded; /api/chat returns a message
  stub="$PS_SANDBOX/curl"; cat > "$stub" <<'SH'
  #!/usr/bin/env bash
  for a in "$@"; do case "$a" in */api/ps) echo '{"models":[{"name":"qwen2.5-coder"}]}'; exit 0;;
    */api/chat) echo '{"message":{"content":"pong"}}'; exit 0;; esac; done; exit 0
  SH
  chmod +x "$stub"; export CODEX_DISPATCH_CURL_BIN="$stub"
  source "$PS_REPO_ROOT/lib/local.sh"
  assert_eq "$(l_probe)" "ready" "ollama probe: loaded model -> ready"
  assert_eq "$(l_ready; echo $?)" "0" "l_ready true when loaded"
  assert_contains "$(ollama_chat qwen2.5-coder 'ping')" "pong" "ollama_chat returns content"
  ps_teardown_sandbox; ps_report; exit $?
  ```
- [ ] **Step 2: Implement** `lib/local-ollama.sh` with `l_endpoint` (`OLLAMA_HOST`, default `http://localhost:11434`), `l_model` (`CODEX_DISPATCH_LOCAL_MODEL`, default `qwen2.5-coder`), `l_probe` (parse `/api/ps`; `unreachable|up-not-loaded|ready`), `l_ready`, `l_preload` (1-token `/api/chat`), `l_up`/`l_down` (local: ensure `ollama serve` / `ollama stop "$(l_model)"`; honor `CODEX_DISPATCH_FAKE_STATE`), and `ollama_chat <model> <prompt> [--format <schema>]` (POST `/api/chat`, `jq -r '.message.content'`). All net calls through `${CODEX_DISPATCH_CURL_BIN:-curl}`.
- [ ] **Step 3: Register** in `tests/run.sh`; verify green.

## Task 3 — `--backend ollama` resolver

**Files:** Mod `lib/dispatch.sh` (`d_backend_args`); Test `tests/dispatch_backend_ollama_test.sh` (new).

- [ ] **Step 1: Failing test** — assert the resolver maps `ollama` to codex's native oss flags:
  ```bash
  source "$PS_REPO_ROOT/lib/local.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  out="$(CODEX_DISPATCH_LOCAL_BACKEND=ollama CODEX_DISPATCH_LOCAL_MODEL=qwen2.5-coder d_backend_args ollama)"
  assert_contains "$out" "--oss" "ollama backend uses --oss"
  assert_contains "$out" "--local-provider ollama" "selects ollama provider"
  assert_contains "$out" "-m qwen2.5-coder" "threads the model alias"
  ```
- [ ] **Step 2: Implement.** Extend `d_backend_args`: `codex` → ``; `local`/`llamacpp` → `-p <profile>` (unchanged); `ollama` → `--oss --local-provider ollama -m "$(l_model)"`. Keep the case default safe.
- [ ] **Step 3: Register + verify;** confirm `dispatch_backend_test.sh` (existing) still passes.

## Task 4 — Opt-in install: stop writing codex config by default

**Files:** Mod `install.sh` (flag parse) + `lib/install-common.sh` (gate step 6); Mod `tests/install_test.sh`; New `tests/install_optin_test.sh`.

Today `lib/install-common.sh` step 6 writes `[model_providers.llamacpp]` + the overlay **unconditionally**. Gate it.

- [ ] **Step 1: Flag parse** in `install.sh` — accept `--with-local` and `--with-local=<ollama|llamacpp>`; export `PS_WITH_LOCAL` (empty = off) and `PS_LOCAL_BACKEND` (default `ollama` when `--with-local` given bare). Auto-detect: if bare `--with-local` and `command -v ollama`, prefer ollama.
- [ ] **Step 2: Gate** step 6 in `lib/install-common.sh` behind `[ -n "${PS_WITH_LOCAL:-}" ]`. For `ollama`, write **no** codex provider (native path needs none) — just record the chosen backend (e.g. a line in `.curator_state` or a `local.env`); for `llamacpp`, render `templates/local-headless.config.toml.example` with env substitution into `$CODEX_HOME`.
- [ ] **Step 3: Update `install_test.sh`** — the existing codex-config assertions move under a `--with-local=llamacpp` invocation; the default invocation now asserts `~/.codex` is **untouched**.
- [ ] **Step 4: New `install_optin_test.sh`** — bare `install.sh` writes no `config.toml`/overlay; `--with-local=ollama` records the backend but writes no provider; `--with-local=llamacpp` writes the overlay from the example. Verify idempotency/non-clobber preserved.
- [ ] **Step 5:** `bash tests/run.sh` green.

## Task 5 — De-value: remove author values from defaults + ship the example

**Files:** Mod `lib/local-llamacpp.sh` (neutral defaults); New `templates/local-headless.config.toml.example`; New `tests/no_personal_values_test.sh`.

- [ ] **Step 1: Failing guard test** — `tests/no_personal_values_test.sh`:
  ```bash
  # No author infra in code/defaults/templates (docs may reference as examples).
  hits="$(grep -rEl '100\.64\.0\.4|greg-campisi|qwen36-35b' "$PS_REPO_ROOT" \
            --exclude-dir=docs --exclude-dir=.git || true)"
  assert_eq "$hits" "" "no hardcoded author values outside docs/"
  ```
- [ ] **Step 2: Parameterize** `lib/local-llamacpp.sh`: keep the env-var seams but set **neutral** defaults (e.g. `l_endpoint` default `http://localhost:8080/v1`, `l_model` default empty/`local-model`, `l_ssh_tgt` empty ⇒ lifecycle treats blank SSH target as "local/no-op"). Move the docker-preset `up`/`down` commands to env with empty defaults (no `~/docker/llama`, no `MODE=`).
- [ ] **Step 3: Example overlay** — `templates/local-headless.config.toml.example` with `${CODEX_DISPATCH_LOCAL_ENDPOINT}` / `${CODEX_DISPATCH_LOCAL_MODEL}` placeholders and a comment pointing to the README "advanced: llama.cpp remote" section.
- [ ] **Step 4:** Confirm the author can still run by exporting the real values (documented); `bash tests/run.sh` green, guard test passes.

---

## Sequencing & landing
1 → 2 → 3 → 4 → 5. Each task lands via `/codex-implement` with `--verify checks --check 'bash tests/run.sh'`, Claude-gated. After Task 5, update the README "Local LLM" section (default = Ollama opt-in; llama.cpp under "advanced"). Phases 2–4 (MCP server, onboarding/auto-detect, curator-ollama, plugin packaging) follow as separate plans per the spec's §10 sequencing.

## Out of scope (Phase 1)
The `local-llm` MCP server (Phase 2), curator `CURATOR_BACKEND=ollama` (Phase 3), capability-detection onboarding docs (Phase 3), and plugin packaging (Phase 4). A `doctor` migration to neutralize the legacy author endpoint in **existing** `~/.codex` installs (spec R1) is tracked for Phase 3's doctor work.

# Subsystem D — Portability & Productization (public distribution) — Design Spec

Status: **approved** (2026-06-11). Supersedes the personal-infra defaults
baked into C.1. §9 decisions resolved to the recommended defaults (revisable).

## 1. Goal

Make `claude-code-profiles` usable by **someone who is not the author**. The repo
is now public, but subsystem C.1 (local-model backend) is hardcoded to the
author's environment — a remote llama.cpp docker on a Tailscale IP, SSH lifecycle,
and a private model alias. A stranger who clones and runs `install.sh` today gets
the author's dead endpoint written into their `~/.codex`.

This subsystem de-personalizes the framework and turns the local-LLM story into a
portable, opt-in capability with **Ollama-local as the zero-config default**,
delivered as a distributable Claude Code plugin.

The author's llama.cpp-remote rig must keep working — demoted from "everyone's
default" to "an env-driven advanced backend."

## 2. Non-goals

- Rewriting subsystem A (profiles) or the codex-**cloud** backend — both are
  already portable (need only `claude`/`codex` + auth).
- Supporting every local runtime. Two backends: **ollama** (default, portable)
  and **llamacpp** (advanced, the author's existing remote path). lmstudio is
  reachable for free via codex `--local-provider lmstudio` but is not a
  first-class lifecycle target in D.
- Hosting/distributing models. We detect and drive a local runtime; we don't ship weights.

## 3. Locked decisions (from scoping, 2026-06-10)

- **L1 — Driver is third-party usability.** Every default must work, or no-op
  cleanly, on a machine with zero author infrastructure.
- **L2 — Ollama is the default local backend.** Codex consumes it natively via
  `codex exec --oss --local-provider ollama -m <model>` (confirmed codex 0.136).
  No custom `[model_providers.*]`, so it sidesteps the Responses-API constraint
  that forced llama.cpp's `wire_api = "responses"` hack.
- **L3 — Local-LLM is opt-in at install.** A bare `install.sh` no longer writes
  any codex provider/overlay config. Backend config is written only on opt-in.
- **L4 — No author values in defaults or code.** Endpoints, SSH targets, model
  aliases, docker preset commands move to env vars + a committed `.example`
  overlay. `grep -r 100.64.0.4` over non-doc files must return nothing.
- **L5 — Backend abstraction mirrors the daemon split.**
  `CODEX_DISPATCH_LOCAL_BACKEND=ollama|llamacpp` selects `lib/local-<backend>.sh`
  behind the existing `l_probe/l_ready/l_up/l_down` interface — the same pattern
  as `lib/daemon-<os>.sh`.
- **L6 — In-session local subagents ship as an MCP server.** Claude Code's native
  Task/Agent subagents run Claude models and cannot be repointed at Ollama; a
  `local-llm` MCP server exposes local models as callable, parallelizable tools.
- **L7 — Curator stays Claude by default.** `CURATOR_BACKEND=claude|ollama`;
  `ollama` is opt-in for offline/zero-spend operation, using structured outputs
  for JSON reliability.
- **L8 — Distribute as a Claude Code plugin.** Add plugin + marketplace manifests
  so others install via the plugin system; `install.sh` remains for the parts a
  plugin can't do (daemon, `ccp` on PATH, profile adoption).

## 4. System overview

```
                         ┌─────────────────── one Ollama access layer ───────────────────┐
install.sh (opt-in)      │  lib/local-ollama.sh : l_probe l_ready l_up l_down + ollama_chat │
   └─ local setup ───────┤  lib/local-llamacpp.sh : the existing remote/docker/SSH path     │
      (detect + write)   └───────────────┬───────────────┬───────────────┬─────────────────┘
                                         │               │               │
                  D.2 codex backend ─────┘   D.4 MCP server ┘   D.5 curator backend ┘
                  --oss --local-provider     local-llm:          CURATOR_BACKEND=ollama
                  ollama -m <model>          local_ask(model,…)  (structured-output JSON)
```

Five workstreams, all on the single access layer:

- **D.1 De-personalization** — strip author infra from defaults; local-LLM opt-in.
- **D.2 Ollama codex backend** — `--backend ollama` via codex's native oss path.
- **D.3 Onboarding & auto-detect** — install/doctor detects ollama/codex/claude and configures; onboarding docs.
- **D.4 `local-llm` MCP server** — local models as in-session subagent tools.
- **D.5 Curator-on-Ollama** — offline subsystem B.
- **D.6 Plugin packaging & contributor docs** — distributable + extensible.

## 5. Detailed design

### 5.1 D.1 — De-personalization (the unblocker)

Current personal coupling to remove from defaults/code:

| Location | Personal value today | Target |
|---|---|---|
| `lib/install-common.sh` §6 | writes `[model_providers.llamacpp]` `base_url=http://100.64.0.4:8080/v1` + `local-headless.config.toml` **unconditionally** | only on `--with-local`; no values absent explicit config |
| `lib/local.sh` | `100.64.0.4:8080`, `greg-campisi@100.64.0.4`, `qwen36-35b`, `~/docker/llama`, `MODE=qwen36-only` | move to `lib/local-llamacpp.sh`; values from env; ship `.example` |
| `templates/*.config.toml` | author endpoint/model | `local-headless.config.toml.example` with `${...}` placeholders |
| README / install comments | "llama.cpp (workstation)" + IP | neutral wording; author rig documented as one example backend |

`install.sh` gains `--with-local[=ollama|llamacpp]` (and an interactive prompt
when run without flags on a TTY). Default: **no local backend configured**.

### 5.2 D.2 — Ollama codex backend

- New `lib/local-ollama.sh` implementing the `l_*` interface:
  - `l_endpoint` → `${OLLAMA_HOST:-http://localhost:11434}` (note: native API, not `/v1`).
  - `l_probe` → `GET /api/ps` (loaded) / `/api/tags` (installed); maps to
    `unreachable | up-not-loaded | ready`.
  - `l_up` → ensure `ollama serve` is up (local: start if missing; remote: env command), then a keep-alive warm-up request.
  - `l_down` → `ollama stop <model>` (unload), not a process kill.
  - `ollama_chat <model> <prompt> [--json schema]` → raw `POST /api/chat`, returns content (used by D.4/D.5).
- `lib/dispatch.sh` `d_backend_args`: `ollama` → `--oss --local-provider ollama -m "$model"`.
  Reuses C.1's resolver seam and the `CODEX_DISPATCH_CODEX_BIN` fake-codex test harness.
- Codex needs **no** provider overlay for Ollama — a portability win over llama.cpp.

### 5.3 D.3 — Onboarding & auto-detect

- `install.sh` / `/profile doctor` gain a capability probe: is `ollama` on PATH and serving?
  is `codex` installed + authed? is `claude` present? `jq`/`python3`?
- On `--with-local` without an explicit backend: prefer ollama if detected, else
  fall through to llamacpp (env-driven), else print the one-line install hint.
- `docs/ONBOARDING.md` (or README "Quickstart for new users"): clone → install →
  `ccp` → optional `--with-local`. No design-doc reading required.

### 5.4 D.4 — `local-llm` MCP server (in-session local subagents)

- A small MCP server (python, reusing the curator stack) registered in the
  default profile's `settings.json` (additively, like the hooks).
- Tools:
  - `local_ask(model?, prompt, json_schema?)` → one-shot answer via `ollama_chat`.
  - `local_models()` → list installed local models.
- The main Claude session calls `local_ask` like any tool and can **fan several
  out in parallel** — the genuine "dispatch local models as subagents" experience.
  Philosophically the in-session cousin of `local-ask`/`non-agentic-claude-subprocess`.
- Honors the same backend env, so it works against ollama (default) or the
  llama.cpp endpoint.

### 5.5 D.5 — Curator-on-Ollama (offline subsystem B)

- `bin/curator.py`: add `CURATOR_BACKEND=claude|ollama` (default `claude`).
  The ollama path swaps the `claude -p` call for `ollama_chat` with the existing
  `CURATOR_SYSTEM_PROMPT`, using Ollama **structured outputs** (`format: <schema>`)
  to enforce the §5.8 decision schema — small-model JSON becomes reliable.
- Keep claude the default (judgment quality). Document ollama as the
  offline/zero-spend mode, optionally as a cheap pre-filter that escalates
  borderline cases to claude.

### 5.6 D.6 — Plugin packaging & contributor docs

- Add `.claude-plugin/plugin.json` (+ a marketplace manifest) exposing the
  commands (`/profile`, `/curator`, `/codex-implement`), skills, the MCP server,
  and the hooks, so others can install via the plugin system.
- `install.sh` still handles what a plugin can't: `ccp` on PATH, the curator
  daemon (launchd/systemd), and `~/.claude` default-profile adoption.
- `CONTRIBUTING.md`: repo layout, the test harness (`tests/run.sh`), the
  add-a-backend recipe (drop in `lib/local-<x>.sh` + `d_backend_args`), and the
  Claude-plans/codex-implements workflow.

## 6. Acceptance criteria

- **Clean-room install:** on a machine with no author infra, `bash install.sh`
  leaves `~/.codex` untouched; `ccp`, `/profile`, and the curator daemon install fine.
- **No personal values leak:** `grep -rE '100\.64\.0\.4|greg-campisi|qwen36-35b' --
  exclude-dir=docs` returns nothing (docs may reference them as examples).
- **Ollama happy path:** with `ollama` installed, `install.sh --with-local=ollama`
  configures the backend against `localhost:11434`; `--backend ollama` dispatch
  and `local_ask` both return output.
- **llama.cpp preserved:** the author's rig works via env (`CODEX_DISPATCH_LOCAL_BACKEND=llamacpp` + the `.example` overlay), with zero values hardcoded.
- **Curator offline:** `CURATOR_BACKEND=ollama` produces schema-valid decisions
  with no network to Anthropic.
- **Plugin install:** the framework is installable via the Claude Code plugin system.
- **Green suite:** existing 42 test files pass; new tests cover the ollama
  backend, opt-in install (no-write-by-default), capability detection, the MCP
  tools, and the curator ollama path.

### Testing approach
- Reuse the hermetic sandbox + fake-bin seams: `CODEX_DISPATCH_FAKE_STATE`,
  `CODEX_DISPATCH_CURL_BIN`, `CODEX_DISPATCH_CODEX_BIN`, `CC_PROFILE_ROOT`,
  `CODEX_HOME`. Add an `OLLAMA_HOST` + fake-curl stub for `/api/ps`/`/api/chat`.
- New: `install_optin_test.sh` (no codex writes by default), `local_ollama_test.sh`
  (probe/lifecycle/ask against stubbed HTTP), `dispatch_backend_ollama_test.sh`
  (resolver → `--oss --local-provider ollama`), `mcp_local_llm_test.sh`,
  `curator_ollama_backend_test.sh`.

## 7. Out of scope (this spec)
- Auto-installing Ollama or pulling models for the user (we detect + hint).
- A GUI/dashboard. Cloud-hosted local inference. Non-Claude-Code editors.
- Windows-native (WSL behaves as Linux, per the installer).

## 8. Risks & mitigations
- **R1 — Existing installs already carry the author endpoint** in `~/.codex`.
  Mitigation: a `doctor` migration that detects the legacy `[model_providers.llamacpp]`
  default and offers to neutralize/parameterize it (mirrors C.1's legacy-table strip).
- **R2 — Small-model curation quality** (D.5). Mitigation: claude default;
  structured-output enforcement; optional escalate-to-claude pre-filter.
- **R3 — MCP server surface/security** — local models executing as tools.
  Mitigation: the MCP is non-agentic (text in/out, no file/shell), like the
  `non-agentic-claude-subprocess` contract.
- **R4 — VRAM coexistence on a shared GPU host** (author only). Mitigation: doc
  guidance — ollama for warm small/mid models, llama.cpp for the heavy coder, or
  pick one. Irrelevant to ollama-local users.
- **R5 — codex oss-flag drift across minors** (0.135→0.136 already churned).
  Mitigation: `codex-local-doctor` extended to assert the ollama path; pin the
  observed flag set per codex version.

## 9. Decisions (resolved 2026-06-11; revisable)
1. **llama.cpp stays in the public repo** as a documented, de-valued advanced
   backend (env-driven), not ollama-only.
2. **Plugin distribution:** own marketplace manifest in this repo first.
3. **Default Ollama model:** `qwen2.5-coder` as the suggested new-user default
   (env-overridable via `CODEX_DISPATCH_LOCAL_MODEL`); revisit per availability.
4. **MCP server language:** python (reuse the curator stack).
5. **Curator ollama mode:** full replacement behind `CURATOR_BACKEND=ollama`
   first; escalate-to-claude pre-filter is a later refinement.

## 10. Build & sequencing
- **Phase 1 (unblock third parties): D.1 + D.2.** De-personalize, make local opt-in,
  add `lib/local-ollama.sh` + `--backend ollama`. Highest value, smallest blast radius.
- **Phase 2 (new capability): D.4 MCP server.** The headline net-new feature.
- **Phase 3: D.3 onboarding/auto-detect + D.5 curator-ollama.** Adoption polish + offline B.
- **Phase 4: D.6 plugin packaging + contributor docs.** Make it installable/extensible.

Each phase ships its own implementation plan (`docs/plans/`) and lands via the
Claude-plans / codex-implements workflow with green tests.

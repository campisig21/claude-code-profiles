---
name: codex-local-doctor
description: Audit and repair the codex local-model dispatch backend (`--backend local`, the qwen path used by codex-implement) before you rely on it — catch codex version/config drift (above all the codex >=0.136 legacy `[profiles.<name>]` conflict that makes local dispatch SILENTLY no-op), correct it via the self-healing installer, and re-verify readiness. Use before the first local dispatch of a session, after a `codex` upgrade, or the moment a `--backend local` dispatch comes back as an empty-message `noop`.
---

# codex-local-doctor

The local dispatch backend (`codex_dispatch.sh --backend local` → qwen on the
workstation) has two independent failure surfaces that look identical from the
outside — a dispatch that does nothing:

1. **Reachability** — the workstation/container is down (`doctor` shows
   `unreachable | up-not-loaded`).
2. **codex config** — codex can load neither the profile nor its provider, so
   `codex exec -p <profile>` dies on startup. The engine swallows that error
   (`|| true`) and you get an empty-diff run.

The engine's **`noop` status is the tripwire**: a `--backend local` dispatch that
returns `status: noop` with a **blank `codex:` message** is almost always #2 (a
codex config-load failure), NOT a dumb model. This skill is the audit→correct
loop for both surfaces, with a bias toward catching version-drift before it bites.

## 1. Audit (read-only)

Run from any git repo (the engine needs one):

```
codex --version                                   # note the major.minor
codex_dispatch.sh doctor                          # codex ver + local state + dispatches
grep -n '^\[profiles\.' ~/.codex/config.toml      # legacy profile tables (see §3)
ls -l ~/.codex/local-headless.config.toml         # the 0.136 overlay must exist
```

`doctor`'s `local backend:` line is one of `unreachable | up-not-loaded | ready`.
**`ready` only proves the HTTP `/models` endpoint answers — it does NOT prove codex
can load the profile.** So `ready` + a config fault still no-ops. Treat §3 as
mandatory even when `doctor` says `ready`.

## 2. Symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| `--backend local` → `noop`, **blank `codex:` msg** | codex couldn't start (config error, swallowed) | read `.git/codex-dispatch/<id>.codexlog.jsonl`; match its error below |
| log: `Error loading config.toml … --profile <name> cannot be used while … legacy [profiles.<name>]` | codex >=0.136 + a `[profiles.<name>]` table left in `config.toml` | §3 — strip the legacy table |
| log: `wire_api` / custom-provider 4xx | provider missing `wire_api = "responses"` (codex >=0.135 dropped `chat`) | fix `[model_providers.llamacpp]` in the overlay |
| `doctor`: `unreachable` | host off / container stopped | bring the workstation up, then `codex_dispatch.sh local-up` |
| `doctor`: `up-not-loaded` | server up, model not loaded | `codex_dispatch.sh local-up` (nudges an on-demand load) |
| `noop` but `codex:` msg is **non-empty** | a real model no-op (misread/already-done task) | not a config issue — `resume` with sharper guidance or take over (see `codex-implement`) |

## 3. Correct — the legacy `[profiles.<name>]` conflict (the common one)

codex **>=0.136 refuses** `--profile local-headless` while `~/.codex/config.toml`
still declares `[profiles.local-headless]`. Profile settings must live ONLY in the
overlay `~/.codex/local-headless.config.toml` (the global `[model_providers.llamacpp]`
table in `config.toml` is fine and should stay).

**Preferred fix — re-run the installer (idempotent + self-healing):**
```
bash ~/.claude/profile-system/install.sh
```
It strips a stale `[profiles.<name>]` table (preserving everything around it),
rewrites the overlay if missing, and re-links skills. Safe to run anytime.

**Manual strip (if you can't re-run install):** back up first, then drop just that
table — `awk '$0=="[profiles.local-headless]"{s=1;next} s&&/^\[/{s=0} s{next} {print}'`
over `~/.codex/config.toml`.

## 4. Re-verify (always close the loop)

```
codex_dispatch.sh doctor                          # expect: ready
codex_dispatch.sh quick --backend local --snapshot "create a file PROBE.txt containing ok"
```
A healthy backend produces a **non-empty diff** (not `noop`). Revert the probe.
Then proceed with the real `codex-implement` dispatch.

## 5. Prevent legacy version issues

- **After every `codex` upgrade, run §1 before trusting `--backend local`.** Profile-config
  contracts change across codex minors (0.135 dropped `chat`; 0.136 banned the in-`config.toml`
  profile table) — the breakage is silent.
- **Never hand-add `[profiles.<name>]` to `~/.codex/config.toml`.** Put profile settings in
  `~/.codex/<name>.config.toml` only. `install.sh` already enforces this.
- **Wire the tripwire to your reflex:** a blank-message `noop` on `--backend local` → run this
  skill, don't blame qwen.

## Red flags — STOP if you think any of these

| Thought | Reality |
|---|---|
| "local dispatch no-op'd, qwen must be incapable" | A **blank-`codex:`** noop on `--backend local` is almost always a codex config-load error — read the codexlog, run §1–§3. |
| "`doctor` says `ready`, so dispatch will work" | `ready` only probes the `/models` HTTP endpoint, NOT codex's profile-config load — a config fault still no-ops. |
| "I'll add `[profiles.local-headless]` to config.toml" | codex >=0.136 rejects that under `--profile`; settings go in `<name>.config.toml` only. |
| "I'll hand-edit `~/.codex/config.toml` to fix it" | Prefer `install.sh` — idempotent and self-heals the legacy table; hand-edits drift and recur. |

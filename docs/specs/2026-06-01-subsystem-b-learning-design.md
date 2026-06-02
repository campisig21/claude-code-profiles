# Subsystem B — Self-Improvement Learning — Design Spec

- **Date:** 2026-06-01
- **Status:** Draft (design); pending spec review
- **Subsystem:** B of 3 (A = Profiles · B = Self-improvement learning · C = Codex dev-process dispatch)
- **Scope of THIS spec:** **B.0 + B.1 + B.2.** Deferred to follow-on specs: **B.3** (skill-sharing Claude↔codex) and **B.4** (local-Qwen curation routing).
- **Project home:** `~/.claude/profile-system/` (this repo)
- **Predecessors:**
  - Subsystem A — `docs/specs/2026-05-28-profile-layer-design.md`. **Done & merged.** Laid B's contract: `curator/inbox/`, `.curator_state`, the shared `Stop` hook (`learn-capture.sh`, a stub), the `learn` skill placeholder, and the A.8 `.lock` convention (deferred to B).
  - Subsystem C / C.1 — `docs/specs/2026-05-31-codex-dispatch-design.md`, `…-local-backend-design.md`. **Done & merged.** B.2 adds one small additive change to C (persist the codex exec stream).

---

## 1. Goal

Grow and curate each profile's **learned skills** and **memories** automatically, and keep
them *good* over time rather than just accumulating. A lean background daemon drains a
per-profile candidate queue, hands the heavy synthesis to **headless Sonnet**
(`claude -p --model sonnet`), and writes results **autonomously but reversibly**, announcing
every change to the next session and to the operator.

Three layers, one spec:
- **B.0 — Core curation daemon.** Inbox → Sonnet → write skills/memories → notify. The `/learn`
  flag skill. `.curator_state` metrics. The A.8 `.lock` convention.
- **B.1 — Skill performance.** Per-skill usage tracking; prune (archive) skills that never fire;
  merge duplicates. The "performance improving" core.
- **B.2 — Codex-execution learning feed.** Persist each codex dispatch's exec stream (small C
  change), then analyze which tools/skills codex used and mine repeated manual patterns.

## 2. Non-goals (this spec)

- **B.3 — skill-sharing Claude↔codex** (making learned skills available *to* codex at dispatch
  time). Codex has no native "skills" concept; that needs its own design discovery.
- **B.4 — local-Qwen curation routing.** All B intelligence runs on headless Sonnet for now;
  routing curation work to C.1's local backend is a later additive phase.
- **Description-tuning refinement** of skills (rewriting triggers from usage) — explicitly
  dropped during brainstorming; B prunes and consolidates, it does not re-tune descriptions.
- Editing any **hand-written** artifact (`CLAUDE.md`, `settings.json`, persona). Structurally
  forbidden (§6 allowlist).

## 3. Locked decisions (brainstorming, 2026-06-01)

| # | Decision | Choice |
|---|----------|--------|
| B1 | Codex's role in B | **Build process only.** `codex_dispatch.sh` implements B's code (Claude-plans/codex-implements). B's *runtime* is pure headless Sonnet; codex is **not** in the curation path. |
| B2 | Candidate signal | **Deliberate `/learn` flags + codex-run analysis.** The every-turn breadcrumb (A's stub behavior) is **removed**. Primary signal is the main session flagging what it learned; secondary is each codex dispatch's execution log (on `land`). |
| B3 | Autonomy | **Fully autonomous (per A's D3), made safe by reversibility + transparency, not a blocking gate.** Every removal is an **archive, never a hard delete**; every run **notifies** the next session and the operator. |
| B4 | Performance scope | **Usage tracking + pruning + consolidation/dedup + curator self-metrics.** (Not description-tuning.) |
| B5 | Local-model use | **Sonnet only (this spec).** Local-Qwen routing = B.4. |
| B6 | Curation engine | **Headless Sonnet** (`claude -p --model sonnet`), **standard 200K context** — no 1M, no beta header, no premium-tier cost. Inputs are *digests*, not full content; codex logs are reduced to bounded tool-call events; on overflow the daemon applies **backpressure** (process fewer candidates, leave the rest queued) rather than chunking. |
| B7 | Daemon flavor | **One lean Python daemon on launchd**, iterating **all** profiles; per-profile `flock`; JSON sidecar state; atomic tmp+rename writes. |
| B8 | CLAUDE.md as TOC | The daemon **never writes CLAUDE.md.** CLAUDE.md carries one static, seeded `@curator/INDEX.md` import; the daemon owns and regenerates `curator/INDEX.md` (learned skills + memory roll-up). |

## 4. System overview

```
/learn skill ───────────────┐
                            ├──▶ <profile>/curator/inbox/*.json        (candidate queue)
codex `land` ─▶ codexlog ───┘
Stop hook ──▶ curator/sessions.jsonl  +  curator/last_activity   (usage index + idle debounce)

launchd (StartInterval 30m) ─▶ bin/curator.py:
  for each profile in {default} ∪ profiles/* :
    flock(.curator.lock, non-blocking)  — held? → skip profile
    .curator_state.paused == true       → skip
    last_activity within idle_threshold (10m) → skip (don't curate mid-work)
    GATHER     candidates = drain inbox/  +  unprocessed codex logs
               usage      = parse transcripts named in new sessions.jsonl lines + codex logs
                            → bump skill-stats.json
    SYNTHESIZE decisions  = claude -p --model sonnet ( candidates,
                            digest(existing skills+memories), skill-stats )   ← only intelligent step
    APPLY      create/update/merge/prune  (allowlist-guarded, archive-never-delete, idempotent)
               regenerate curator/INDEX.md ; update <profile> MEMORY.md
    RECORD     .curator_state metrics · curator.log · notifications/<ts>.json
    release lock

SessionStart wakeup ─▶ reads notifications/ → banner + "what changed" block → notifications/shown/
operator: /curator … (on demand) ─▶ status · log · stats · pending · restore · pause/resume · run
```

The daemon is a thin orchestrator: it shuttles JSON to/from `claude -p` and applies decisions
mechanically. **No editorial judgment lives in the daemon.**

## 5. Detailed design

### 5.1 File structure (additive over A; one change to C)
```
~/.claude/profile-system/
├── bin/curator.py                  # NEW — the daemon (orchestrator; intelligence is in claude -p)
├── bin/curator                     # NEW — thin CLI wrapper backing the /curator command
├── lib/dispatch.sh                 # EXTEND (C) — persist codex exec stream to <sidecar>/<id>.codexlog.jsonl
├── codex_dispatch.sh               # EXTEND (C) — on `land`, drop a codex_run candidate into the active inbox
├── hooks/learn-capture.sh          # REWRITE — session index + last_activity (no per-turn candidate breadcrumb)
├── skills/learn/SKILL.md           # REWRITE — real /learn flag (replaces placeholder)
├── commands/curator.md             # NEW — /curator operator command
├── templates/persona.md            # EXTEND — seed the static `@curator/INDEX.md` import line
├── install.sh                      # EXTEND — install launchd plist (idempotent); seed default INDEX import
├── templates/curator.plist         # NEW — launchd job template
└── tests/
    ├── curator_loop_test.sh        # NEW — drain/lock/debounce/apply/allowlist/backpressure/metrics
    ├── curator_stats_test.sh       # NEW — usage stats from fake transcripts + fake codex logs; prune at threshold
    ├── curator_codexfeed_test.sh   # NEW — codex log → candidate; analysis → stats + new-skill candidate
    ├── curator_cli_test.sh         # NEW — /curator status/log/stats/pending/restore/pause/resume/run
    ├── curator_index_test.sh       # NEW — INDEX.md regeneration; CLAUDE.md untouched
    ├── learn_capture_test.sh       # UPDATE — new session-index behavior (no breadcrumb)
    ├── dispatch_codexlog_test.sh   # NEW (C) — exec stream persisted; session-id parse unchanged
    └── install_curator_test.sh     # NEW — plist written when absent, idempotent, existing left untouched
```

### 5.2 Per-profile curator files (all under `<profile>/curator/`)
| File | Owner | Purpose |
|---|---|---|
| `inbox/*.json` | feeders | Candidate queue (`/learn` flags, `codex_run`). |
| `sessions.jsonl` | Stop hook | Append-only session index: `{session_id, transcript_path, ended_at, cwd}`. Feeds usage scans + idle debounce. |
| `skill-stats.json` | daemon | Per-skill usage (§5.6). |
| `archive/<ts>-<name>/` | daemon | Reversible graveyard for pruned/superseded artifacts. |
| `notifications/*.json` → `notifications/shown/` | daemon → wakeup | "What changed" per run; consumed at SessionStart. |
| `INDEX.md` | daemon | Generated TOC: learned skills + memory roll-up. Imported by CLAUDE.md. |
| `.curator.lock` | daemon | `flock` (A.8). |
| `.curator_state` | daemon | Extended A file (§5.7). |
| `last_activity` | Stop hook | Unix ts of last turn-end (idle debounce). |
| `.cursors.json` | daemon | Progress trackers so work is never re-processed: `sessions.jsonl` line offset + set of already-analyzed codex-log ids. |
| `curator.log` | daemon | Raw run log (operator tailing). |

### 5.3 The `/learn` skill (`skills/learn/SKILL.md`)
Replaces the A placeholder. When the main session decides something is worth learning, it writes
a candidate into the **active profile's** `curator/inbox/`:
```jsonc
{ "kind":"flag", "captured_at":"…Z", "profile":"default", "session_id":"…",
  "type":"skill|memory|auto",          // "auto" = let the curator decide which
  "title":"…", "body":"…",              // the substance the session wants captured
  "context":"…" }                       // why/when it came up (helps Sonnet write a good "use-when")
```
The skill is rich-but-cheap: the main model (full context) supplies *what* was learned; the daemon
(Sonnet) validates, dedupes, consolidates, and *files* it. Filename `inbox/<ts>-<session>-<rand>.json`.

**Mechanism:** a skill is *instructions*, not code, so the `/learn` SKILL.md directs the session to
call a small helper `bin/learn-flag` (added with the skill) that validates the fields and writes the
candidate atomically into the active profile's inbox. This mirrors the `/curator → bin/curator`
pattern and keeps the write robust regardless of how the session phrases it.

### 5.4 Stop hook, repurposed (`hooks/learn-capture.sh`)
A's stub dropped a candidate every turn (noise). New behavior — never fails, always exits 0:
1. Append one line to `curator/sessions.jsonl`: `{session_id, transcript_path, ended_at, cwd}`.
2. Write the current epoch seconds to `curator/last_activity`.

No inbox writes. Same filename ⇒ **no `settings.json` re-registration** (A already registered it).
The session index is the daemon's list of transcripts to scan for skill-usage stats (§5.6); the
`last_activity` stamp is the idle-debounce signal. Because the `Stop` hook fires at every turn-end,
`last_activity` tracks active use at minute granularity, so "10m since last stamp" ≈ "stepped away".

### 5.5 The daemon loop (`bin/curator.py`)
Per profile (default ∪ profiles/*), in order:
1. `flock(.curator.lock, LOCK_EX|LOCK_NB)` — held → **skip** (prior run or guard). Released in `finally`.
2. `paused` → skip. `now - last_activity < idle_threshold` → skip.
3. **GATHER** — `candidates = inbox/*.json + codex logs not in the processed-set`; build `usage`
   by parsing transcripts named in new `sessions.jsonl` lines + the codex logs, bumping
   `skill-stats.json`.
4. **SYNTHESIZE** — one batched `claude -p --model sonnet` call per profile per run. Input
   (standard 200K context): the candidates, a **digest** of existing skills+memories (names +
   one-line "use-when", never full bodies), and `skill-stats`. Output: a **decision list**
   validated against the §5.8 schema. Malformed/non-zero/timeout → candidates retained,
   `failures_total++`, logged; **no partial apply**, other profiles unaffected.
5. **APPLY** (mechanical, idempotent, allowlist-guarded — §6):
   - `create` → write `skills/<name>/SKILL.md` or a memory file under `projects/<slug>/memory/`.
   - `update` → archive prior copy → write new.
   - `merge` → write merged artifact → archive each original.
   - `prune` → archive the artifact (**never** hard-delete).
   - `skip` → leave it.
   Each consumed inbox file is removed **only after** its decision lands. Codex logs are recorded
   in the processed-set.
6. **INDEX/MEMORY** — regenerate `curator/INDEX.md`; update the relevant `MEMORY.md`.
7. **RECORD** — `.curator_state` metrics; append `curator.log`; write `notifications/<ts>.json`
   iff anything changed.

**Backpressure (B6):** before step 4, the daemon estimates input size; if a full batch would
approach the context budget, it processes a **prefix** of candidates this run and leaves the rest
queued — no chunker, no compression.

### 5.6 Skill performance (B.1) — `skill-stats.json`
```jsonc
{ "<skill-name>": { "created_at":"…Z", "source":"learned|codex",
                    "times_triggered":N, "last_used_at":"…Z|null", "runs_since_used":K } }
```
- **Usage signal** comes from two places: (a) Claude sessions — the daemon parses transcripts
  (from `sessions.jsonl`) for `Skill`-tool invocations of learned skills; (b) codex runs (§5.9) —
  which learned skills/tools codex used.
- On each run: every learned skill present gets `runs_since_used += 1`; any skill seen used since
  the last run gets `times_triggered += hits`, `last_used_at = now`, `runs_since_used = 0`.
  **Local-backend codex runs are additive-only** (§5.9): they may bump `times_triggered`, but their
  non-use never advances `runs_since_used` — so prune nomination is driven only by Claude-session +
  cloud-codex evidence.
- **Prune nomination:** `times_triggered == 0 && runs_since_used >= PRUNE_THRESHOLD` (default
  **100**) nominates a skill. Sonnet makes the final keep/prune call in step 4 (it may keep a
  rarely-needed-but-valuable skill); the action, if taken, is always archive + notification.
- **Consolidation/dedup:** Sonnet detects overlapping skills/memories and emits a `merge` decision.

### 5.7 `.curator_state` (extends A's file)
```jsonc
{ "last_run_at":"…Z|null", "last_run_duration_seconds":N, "last_run_summary":"…",
  "paused":false, "run_count":N,
  "accepted_total":N, "rejected_total":N, "pruned_total":N, "merged_total":N, "failures_total":N }
```

### 5.8 Decision schema (Sonnet output, validated by the daemon)
```jsonc
{ "decisions": [
    { "action":"create", "kind":"skill|memory", "name":"…", "path":"…",
      "content":"…", "use_when":"…", "reason":"…" },
    { "action":"update", "kind":"skill|memory", "name":"…", "content":"…", "reason":"…" },
    { "action":"merge",  "kind":"skill|memory", "into":"…", "from":["…","…"],
      "content":"…", "reason":"…" },
    { "action":"prune",  "kind":"skill|memory", "name":"…", "reason":"…" },
    { "action":"skip",   "candidate_ref":"…", "reason":"…" }
  ],
  "new_skill_candidates": [ { "title":"…", "rationale":"…", "source_backend":"codex|local" } ]  // §5.9
}
```
Any decision whose target path falls outside the §6 allowlist is **rejected and logged**, never
applied.

### 5.9 Codex-execution learning feed (B.2)
**C change (additive, behind the single `d_codex_*` boundary):** `d_codex_exec`/`d_codex_resume`
currently tee the codex `--json` stream to a temp file, grep the session/thread id, then delete it.
Change: **persist** the stream to `<sidecar>/<id>.codexlog.jsonl` (`d_sidecar_dir` = the repo's
`.git/codex-dispatch/`); `resume` **appends**. Session/thread-id extraction is unchanged ⇒ all C/A
tests still pass. A new guard test asserts the log exists and the id still parses.

**Feed:** on a successful `codex_dispatch.sh land <id>`, drop into the **active profile's**
(`resolve_active_profile`) inbox:
```jsonc
{ "kind":"codex_run", "captured_at":"…Z", "profile":"…",
  "dispatch_id":"…", "log_path":"…/.git/codex-dispatch/<id>.codexlog.jsonl",
  "task":"…", "backend":"codex|local" }
```
**Analysis (step 4):** the daemon reduces the log to **bounded tool-call/skill-use events** (never
the raw stream — B6) and asks Sonnet to (1) report which learned skills/tools codex used → bumps
`skill-stats.json` (keeps a codex-relied-upon skill alive even if Claude sessions rarely trigger
it; one used by *neither* is a prune candidate), and (2) surface **repeated manual patterns** as
`new_skill_candidates` (the "codex keeps doing X the long way — capture it" signal), which re-enter
the inbox as `flag` candidates next run.

**Backend-aware asymmetry (the learning signal is only as good as the executor).** The candidate's
`backend` field (`codex` cloud vs `local` Qwen, from C.1's sidecar) is carried into the analysis,
because a weaker local model under-uses good skills and tends to do things the long way. So a
`backend:"local"` run is treated **conservatively**:
- **Usage stats are additive-only for local runs.** A local run that *used* a learned skill bumps
  `times_triggered`/`last_used_at` (a real positive signal — the model reached for it). A local
  run's *non-use* does **not** increment `runs_since_used`. **Prune nomination (§5.6) counts only
  Claude-session + cloud-codex evidence** — a valuable skill can never be pruned merely because a
  weak model neglected it.
- **New-skill mining is deprioritized for local runs.** Patterns mined from a `local` log are
  emitted with `source_backend:"local"` on the `new_skill_candidate` so Sonnet treats them
  skeptically and the operator notification flags the provenance — we do not codify
  model-weakness *workarounds* as "best practice."

This mirrors C.1 §10's provenance-aware posture. (Noisier local logs from C.1's R8 `<think>`
interleaving only ever *undercount* usage best-effort — never corrupt state, same class as R2.)

### 5.10 CLAUDE.md as a living TOC (B8)
- **CLAUDE.md** (hand-written, operator-owned) gets **one static line, seeded once** by
  `templates/persona.md` at profile creation: `@curator/INDEX.md`. The daemon never edits CLAUDE.md.
- **`curator/INDEX.md`** (daemon-owned, regenerated every run) is the table of contents:
  ```
  ## Learned skills
  - <name> — <use-when>  →  skills/<name>/
  ## Memory
  - <project> → projects/<slug>/memory/MEMORY.md
  ```
  Because CLAUDE.md `@`-imports it, the TOC is always in session context and always fresh, while
  the hand-written file never changes. Each hop (CLAUDE.md → INDEX.md → MEMORY.md → memory files)
  has exactly one writer.

### 5.11 Operator surface
**Passive (in-session):** the SessionStart wakeup banner gains a line, and when
`notifications/*.json` exist, a `CURATOR UPDATE` block lists exactly what was created / updated /
pruned / merged since the last session, then moves them to `notifications/shown/`.

**Active (on demand) — `/curator` command** (`commands/curator.md` → `bin/curator`):
| Command | Behavior |
|---|---|
| `/curator status [profile]` | last run, pending candidates, paused state, headline metrics |
| `/curator log [-n N]` | recent run summaries with per-run decisions |
| `/curator stats` | per-skill usage table; flags prune candidates |
| `/curator pending` | notifications not yet surfaced |
| `/curator restore <name>` | un-archive a pruned/superseded skill or memory |
| `/curator pause` \| `resume [profile]` | toggle `.curator_state.paused` |
| `/curator run [profile]` | force a **foreground** run now (inspect/debug; same code path) |

### 5.12 launchd job (`templates/curator.plist`)
`install.sh` writes `~/Library/LaunchAgents/com.profile-system.curator.plist` **only if absent**
(never clobbers operator edits), `RunAtLoad=false`, `StartInterval=1800` (30m), invoking
`bin/curator.py`. Coalesced across sleep. `/curator run` is the manual/foreground equivalent.

### 5.13 Configuration knobs (env, with defaults)
| Var | Default | Purpose |
|---|---|---|
| `CURATOR_CLAUDE_BIN` | `claude` | Headless-Sonnet binary; **test-injection seam** (fake returns canned decisions). |
| `CURATOR_MODEL` | `sonnet` | Model for `claude -p`. |
| `CURATOR_INTERVAL_SECONDS` | `1800` | launchd `StartInterval`. |
| `CURATOR_IDLE_THRESHOLD_SECONDS` | `600` | Skip if a session was active more recently. |
| `CURATOR_PRUNE_THRESHOLD` | `100` | `runs_since_used` to nominate an unused skill. |
| `CC_PROFILE_ROOT` | `$HOME/.claude` | Test root override (inherited from A). |

## 6. Invariant — writable allowlist (enforced in `apply`)
The daemon may write only:
- `<profile>/skills/**`
- `<profile>/projects/*/memory/**` (incl. `MEMORY.md`)
- `<profile>/curator/**` (incl. `INDEX.md`, archive, state, notifications)

**Forbidden, structurally:** `CLAUDE.md`, `settings.json`, the persona, plugins/hooks symlinks,
anything outside the profile. A decision targeting a forbidden path is rejected + logged. This is
the hermes "curator only mutates agent-created artifacts" invariant, made code rather than custom.

## 7. Acceptance criteria
B is "done" (B.0+B.1+B.2) when, with A and C landed:
1. `/learn` writes a well-formed candidate into the active profile's `curator/inbox/`.
2. The Stop hook appends a `sessions.jsonl` line and updates `last_activity`, and writes **no**
   inbox candidate.
3. The daemon, run against a sandbox profile with a fake `claude` returning canned decisions:
   drains the inbox, applies create/update/merge/prune, **archives (never deletes)** on
   update/merge/prune, regenerates `INDEX.md`, updates `MEMORY.md`, writes a notification, and
   updates `.curator_state` metrics.
4. **Lock contention:** a held `.curator.lock` makes the run skip that profile cleanly.
5. **Debounce:** `last_activity` within the idle threshold skips the profile. **Paused** skips it.
6. **Allowlist:** a decision targeting `CLAUDE.md` (or any forbidden path) is rejected, not written.
7. **Stats/prune (B.1):** usage parsed from a fake transcript and a fake codex log bumps
   `skill-stats.json`; a skill at the prune threshold is nominated and (per the fake decision)
   archived + notified.
8. **Codex feed (B.2):** `d_codex_exec` persists the stream and the session-id parse is unchanged
   (C regression); `land` drops a `codex_run` candidate; the daemon's analysis bumps stats and can
   emit a `new_skill_candidate`.
9. **CLAUDE.md TOC:** a freshly created profile's CLAUDE.md contains the `@curator/INDEX.md` import;
   after a run, `INDEX.md` lists skills + memory roll-up; **CLAUDE.md is byte-unchanged** by the run.
10. **Operator surface:** `/curator status|log|stats|pending|restore|pause|resume|run` behave per
    §5.11; the wakeup `CURATOR UPDATE` block reflects the last run and is consumed (moved to
    `notifications/shown/`).
11. **Failure handling:** a non-zero / malformed `claude` invocation leaves candidates queued,
    increments `failures_total`, and does not crash other profiles.
12. `install.sh` writes the launchd plist when absent and leaves an existing one untouched; **all
    A and C tests still pass** (regression guard).

### Testing approach
- Extends the repo's dependency-free **bash** harness; sandbox-isolated; **no network/model/launchd**.
- `bin/curator.py` is driven from bash tests with `CURATOR_CLAUDE_BIN` pointing at a fake that
  emits canned decision JSON, plus fixture transcripts and fixture codex logs; assertions are on
  **file outcomes and state**.
- Each acceptance criterion maps to ≥1 `tests/*_test.sh`.
- **Boundary (like A's keychain smoke / C's real-codex smoke):** stubs prove orchestration, not
  real Sonnet curation quality or real launchd timing. A **manual smoke checklist**
  (`docs/smoke/`) covers the real path: daemon fires under launchd → real `claude -p` produces a
  real skill → wakeup shows it → INDEX.md/CLAUDE.md surface it → forced prune archives a dead skill
  → `/curator restore` recovers it.

## 8. Risks & mitigations
- **R1 — Sonnet writes a bad/over-eager skill.** *Mitigation:* archive-never-delete + notification
  + `/curator restore` + `/curator pause`; allowlist confines blast radius to agent-created files.
- **R2 — Transcript format drift breaks usage parsing.** *Mitigation:* parser is best-effort and
  isolated; a parse miss only undercounts usage (skill survives longer), never corrupts state;
  covered by a fixture test that pins the expected shape.
- **R3 — Lock/atomicity races with a live session.** *Mitigation:* per-profile `flock` + atomic
  tmp+rename; the daemon only writes agent-created artifacts, disjoint from a live session's working
  files.
- **R4 — Cost creep from frequent `claude -p`.** *Mitigation:* runs only when a profile has work;
  one batched call per profile per run; standard 200K context (no premium tier); backpressure.
- **R5 — Codex log bloat / context overflow.** *Mitigation:* reduce to bounded tool-call events,
  never raw stream (B6); backpressure on the batch.
- **R6 — `claude -p` unavailable / changed flags.** *Mitigation:* single `CURATOR_CLAUDE_BIN` seam;
  failure is non-fatal (candidates retained, logged); `/curator status` surfaces `failures_total`.
- **R7 — Multi-profile daemon touches an inactive profile mid-edit.** *Mitigation:* per-profile
  lock + debounce + allowlist; worst case is a deferred run, not corruption.

## 9. Open micro-decisions (defaulted; revisable)
- **MC1:** launchd `StartInterval` 30m; idle threshold 10m; prune threshold 100 runs.
- **MC2:** one batched `claude -p` per profile per run (not per-candidate).
- **MC3:** archive retention indefinite (manual cleanup); `/curator restore` is the recovery path.
- **MC4:** memory files written under the active profile's `projects/<slug>/memory/`, slug derived
  from the candidate's `cwd` when present, else a `_profile` catch-all store.
- **MC5:** `new_skill_candidates` re-enter the inbox as `flag` candidates next run (two-pass), so a
  mined pattern is validated/written by the normal create path, not a special case.

## 10. Build & sequencing
Implemented via the established **Claude-plans / codex-implements** process (B1): this spec → a
`writing-plans` implementation plan → `/codex-implement` dispatches each plan task to codex with
verify, Claude-gated landing. Suggested task order: C log change (prereq) → Stop-hook rewrite +
`/learn` → daemon core (gather/lock/debounce/apply/allowlist) → stats+prune → codex feed →
INDEX/MEMORY + wakeup notifications → `/curator` CLI → launchd install → e2e + smoke checklist.

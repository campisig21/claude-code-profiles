# Codex Dev-Process Dispatch (Subsystem C) — Design Spec

- **Date:** 2026-05-31
- **Status:** Approved (design); pending spec review
- **Subsystem:** C of 3 (A = Profiles · B = Self-improvement learning · C = Codex dev-process dispatch)
- **Project home:** `~/.claude/profile-system/` (this repo)
- **Predecessor:** Subsystem A (Profile Layer) — built + merged. Spec: `docs/specs/2026-05-28-profile-layer-design.md` (decisions D1–D12).

---

## 1. Goal

Make the user's dev process — **Claude reasons / brainstorms / plans, and `codex` implements** — a first-class, repeatable mechanism instead of an ad-hoc manual handoff.

A *dispatch* is one handoff of implementation work to codex. Subsystem C lets the main Claude session:

1. **Auto-select the codex mode** — fresh one-shot (`codex exec`) vs. resume of a prior session (`codex exec resume`) (decision D1).
2. **Run the work in a git worktree per dispatch** (decision D9) so the live working tree is never touched until Claude approves.
3. **Auto-verify the diff** before reporting done (decision D8), with the verification depth chosen per task.
4. **Land only on Claude's explicit approval** — nothing merges unreviewed.

The defining constraint, surfaced repeatedly in brainstorming: **Claude is the policy-maker; the engine is a dumb, deterministic, unit-tested mechanism.** Everything that requires judgment lives in the skill; everything mechanical lives in tested bash.

This spec covers **only Subsystem C**. It builds on A's machinery (shared-skill symlinking, the `_shared/skills/codex-implement/` target) and is independent of B.

---

## 2. Locked decisions

### 2.1 Project-wide decisions inherited from A (govern C)
| # | Decision | Choice |
|---|----------|--------|
| D1 | "Two types" | **Codex dispatch modes**: one-shot `codex exec` vs. resumable `codex exec resume`. |
| D8 | Codex dispatch flow | **Auto-select** exec vs. resume **+ auto-verify** the diff before reporting done. |
| D9 | Codex workspace | **Git worktree per dispatch.** |
| D11 | Build order | **A → C → B** (C is now). |

### 2.2 Subsystem C decisions (resolved in brainstorming, 2026-05-31)
| # | Decision | Choice |
|---|----------|--------|
| C1 | Dispatch unit of work | **Flexible — Claude decides.** The engine handles a single task or a whole plan identically; the granularity heuristic lives in the skill. |
| C2 | Verify gate | **Per-dispatch mode, chosen by task impact.** Default for impactful work = **checks + diff-review**; also **checks-only** and **review-only** modes for lower-impact tasks. |
| C3 | Landing | **Claude-gated merge.** The engine NEVER lands on its own — even on all-green checks it stops at `needs_review`. Landing is always a separate explicit `land` call after Claude's review. A failed/unreviewed dispatch keeps its worktree for debugging or resume. |
| C4 | Retry loop | **Configurable retry budget, user-overridable.** Claude sets a budget per dispatch (0 = hand failures straight back; N = engine resumes the codex session feeding it the verify-failure output, up to N). When exhausted, hands back to Claude (who may consult the user). |
| C5 | Codex sandbox posture | **Full access** — `codex --dangerously-bypass-approvals-and-sandbox`. The worktree is the isolation boundary for the *working tree* (not the machine — see R3). Matches how the user runs codex locally. |
| C6 | System structure | **Pure-bash engine + thin rigid skill** (mirrors A's `profile_mgmt.sh` + `/profile`). The engine is deterministic and unit-tested; the skill carries judgment. |
| C7 | Entry points | A **skill** `codex-implement` (Claude auto-invokes mid-dev) **and** a **`/codex-implement` slash command** (manual trigger) supporting the full isolated flow plus a `--quick` in-place mode. |
| E1 | Diff token economy | **Diffstat by default.** The full diff is on-demand (`show <id> --diff`) and pulled into Claude's context **only** for review-mode dispatches. `checks-only`/`--quick` never auto-surface the full diff. |
| E2 | Skill token economy | The skill is a **decision table + checklist**, not prose. Runtime hand-holding comes from the engine's `ALLOWED NEXT ACTIONS` output, not standing skill text. |

### 2.3 Environment facts (verified 2026-05-31)
- `codex` CLI present: **`codex-cli 0.135.0`** (spec A saw 0.130.0 — the CLI moves fast; see R4).
- `codex exec [OPTIONS] [PROMPT]` supports: `--json` (JSONL events to stdout), `-o/--output-last-message <FILE>`, `--output-schema`, `-s/--sandbox`, `-C/--cd <DIR>`, `--add-dir`, `--skip-git-repo-check`, `--dangerously-bypass-approvals-and-sandbox`.
- `codex exec resume [SESSION_ID] [PROMPT]` exists for **non-interactive** resume; `--last` resumes the most recent session, **cwd-filtered by default**. (Distinct from the interactive `codex resume` TUI.)
- Codex sessions are stored under `~/.codex/sessions/` (`$CODEX_HOME`), per-cwd. Because each dispatch has a unique worktree cwd, `resume --last -C <worktree>` reliably targets that dispatch's session without needing the UUID.

---

## 3. System overview

```
            Claude plans ──▶ codex-implement skill (judgment)
                                   │  composes prompt, picks mode/verify/retry
                                   ▼
   codex_dispatch.sh dispatch  ── creates worktree+branch from HEAD
                                   │
                          codex exec (full access, -C worktree)
                                   │
                            run checks in worktree
                          ┌────────┴─────────┐
                  fail (budget>0)         pass / review-only
                  resume + re-verify           │
                  (loop, budget--)             ▼
                          └──▶ exhausted   [needs_review]  ◀── Claude reviews diff
                                  │              │              (show <id> --diff)
                                  ▼              │
                              [failed]   ┌───────┼────────┐
                          (worktree kept)▼       ▼        ▼
                                     land <id>  resume   abandon <id>
                                  rebase+merge   <id>    rm worktree+branch
                                  rm worktree   "<fb>"
                                   [landed]              [abandoned]
```

State for every dispatch lives **with the target repo, not the profile**: a JSON sidecar at `$(git rev-parse --git-dir)/codex-dispatch/<id>.json`, with the worktree out of the working tree at a sibling path `…/.codex-dispatch-worktrees/<repo>/<id>/` on branch `codex/<slug>-<shortid>`. So dispatch state never pollutes the working tree (no `.gitignore` needed) and is discoverable per-repo via `list`.

---

## 4. Detailed design

### 4.1 Components & file structure
Subsystem C adds a tested bash engine + a rigid skill + a thin command, slotting in exactly like A's `profile_mgmt.sh` / `/profile` pair:

```
~/.claude/profile-system/
├── codex_dispatch.sh               # NEW — the engine (like profile_mgmt.sh)
├── lib/dispatch.sh                 # NEW — helpers: worktree mgmt, codex invocation, sidecar I/O
├── lib/jsonutil.sh                 # REUSED — js_get etc. for the result sidecar
├── lib/paths.sh                    # REUSED — repo/shared resolution
├── commands/codex-implement.md     # NEW — /codex-implement glue (full + --quick), like commands/profile.md
├── skills/codex-implement/SKILL.md # REPLACE placeholder — the real, rigid skill
└── tests/
    ├── lib.sh                      # EXTEND — ps_make_fake_codex + ps_make_sandbox_repo
    ├── dispatch_exec_test.sh       # NEW
    ├── dispatch_verify_test.sh     # NEW
    ├── dispatch_resume_test.sh     # NEW
    ├── dispatch_land_test.sh       # NEW
    ├── dispatch_quick_test.sh      # NEW
    ├── dispatch_guardrails_test.sh # NEW — proves wrong sequences fail loudly
    └── dispatch_doctor_test.sh     # NEW
```

**The engine/skill split (core principle C6):**

| | **Engine** (`codex_dispatch.sh` + `lib/dispatch.sh`) | **Skill** (`codex-implement/SKILL.md`) |
|---|---|---|
| Nature | Deterministic mechanism, unit-tested | Judgment/policy, executed by the main Claude session |
| Owns | worktree create/remove, codex `exec`/`resume` invocation, running checks, sidecar I/O, rebase+merge on land, cleanup, `doctor` reconciliation | choosing `dispatch` vs `resume`, picking verify mode by impact, setting retry budget, composing the codex prompt, **reviewing the diff**, deciding land vs resume vs abandon |
| Inputs | explicit flags only — no heuristics inside | the task/plan + its context |

### 4.2 Engine CLI surface
`codex_dispatch.sh <command>`:

| Command | Purpose |
|---|---|
| `dispatch [flags] "<prompt>"` | start isolated dispatch (worktree). Flags: `--verify checks\|review\|both` (default `both`), `--check '<cmd>'` (repeatable), `--retry N` (default 1), `--slug <label>` |
| `quick [flags] "<prompt>"` | in-place dispatch, no worktree. Flags: `--verify none\|checks\|review\|both` (default `none`), `--check '<cmd>'`, `--snapshot` |
| `resume <id> "<feedback>"` | resume the dispatch's codex session, re-verify |
| `show <id> [--diff]` | print the sidecar summary; `--diff` appends the full diff (the E1 gate) |
| `land <id> [--reviewed]` | rebase + merge branch → working branch, remove worktree |
| `abandon <id>` | remove worktree + branch |
| `list` | active dispatches for this repo (id · status · slug · branch) |
| `doctor` | reconcile sidecars vs `git worktree list`, prune stale/landed leftovers, report drift + codex version |

There is deliberately **no `--mode exec\|resume` flag**: the mode is *which command* Claude calls (`dispatch` = exec, `resume` = resume). That removes a whole class of misuse.

### 4.3 Dispatch lifecycle (state machine)
The sidecar `status` field drives a small state machine:

- `running` → codex working (transient)
- `verifying` → checks running (transient)
- `needs_review` → verification satisfied; awaiting Claude's review + land decision
- `failed` → checks failed and retry budget exhausted; **worktree retained**
- `landed` → merged into the working branch, worktree removed
- `abandoned` → cleaned up without landing

Standard isolated flow:
1. `dispatch` checks preconditions (in a git repo; branch/worktree don't already exist), creates the worktree+branch from current HEAD, writes the sidecar (`status=running`, records prompt/branch/worktree/base_ref/verify/retry budget).
2. Runs `codex exec --dangerously-bypass-approvals-and-sandbox --json -C <worktree> -o <lastmsg> "<prompt>"`. Captures `session_id` (best-effort, from the `--json` init event), `codex_last_message`.
3. `status=verifying`; for verify modes that include `checks`, runs each `--check` command in the worktree, capturing exit code + an **output tail** (not the whole log).
4. If a check fails and budget > 0: runs `codex exec resume <session_id|--last -C wt>` feeding the failure output + a fix instruction, decrements the budget, re-runs checks. Loops until green or exhausted.
5. Green / `review`-only / no checks → `status=needs_review`. Exhausted → `status=failed` (worktree retained).
6. Every command prints a structured summary + an `ALLOWED NEXT ACTIONS` block (§4.4). Claude reviews (for review modes, via `show <id> --diff`) then calls exactly one of `land` / `resume` / `abandon`.

**`land` is conflict-safe (resolves flag #2):** it rebases the dispatch branch onto current HEAD *inside the worktree*, re-runs the checks, then merges into the working branch. On conflict it aborts cleanly, keeps the worktree, leaves status `needs_review`, and reports — never a half-merged tree.

**Quick mode (`--quick`, resolves flag #1):** runs `codex exec` in the *current working tree* — no worktree, no branch, no land step (changes are already in place); optional checks; reports `git diff` + results. It **refuses a dirty working tree unless `--snapshot`**, which records a restore point (e.g. `git stash create` ref / snapshot commit) before codex runs, so it is always revertable. Iterate with `codex exec resume --last`.

### 4.4 Faithful-usage design (the C-specific emphasis)
Faithfulness is enforced in **three layers, mechanism first**:

**Layer 1 — the engine refuses illegal transitions (the real guarantee).** Wrong sequences fail loudly rather than relying on Claude's discipline:
- `land` **refuses** unless `status == needs_review` *and* verification was satisfied — checks-passing for any mode including `checks`; an explicit `--reviewed` assertion for `review`-only/quick. Refuses outright on `running`/`verifying`/`failed`/`landed`/`abandoned`.
- `dispatch`/`quick` refuse outside a git repo or if the branch/worktree already exists; `quick` refuses a dirty tree without `--snapshot`.
- `resume` refuses when no session can be resolved.
- Unknown `<id>` → error listing valid ids. **Every refusal prints why + the correct next command.**

**Layer 2 — every command emits an explicit `ALLOWED NEXT ACTIONS` block.** e.g. at `needs_review`:
```
ALLOWED NEXT ACTIONS (pick exactly one):
  show <id> --diff       # review (required when verify=both)
  land <id>              # after review passes
  resume <id> "<fb>"     # send fixes to codex
  abandon <id>           # discard
```
This runtime guidance is what lets the skill stay lean (E2).

**Layer 3 — the skill is a rigid checklist that forbids freelancing.** SKILL.md contains: (a) a **decision table** (task impact → verify mode + retry budget; fresh task → `dispatch`, iterating → `resume`, trivial → `quick`); (b) a **mandatory sequence** (`dispatch` → read result → if review-mode `show --diff` + review → `land`/`resume`/`abandon`); (c) a **red-flag table** (governed below); (d) a hard rule: **the skill never runs raw `git worktree`/`git merge`/`codex` — it always goes through the engine**, the sole exception being `codex exec resume --last` for quick-mode iteration. The skill also tells Claude to make a TodoWrite item per step.

Ordering matters: even if Claude ignores the skill, Layer 1 still prevents an unreviewed/half-finished dispatch from landing. **Instructions are convenience; the engine is the seatbelt.**

**Red-flag governance rule (bounds the table):**
> A red-flag entry only earns its place if **Layer 1 cannot mechanically catch the misuse.**

Every candidate red-flag is first routed to the engine: *can the engine refuse it?* If yes → make it a guardrail and **delete the red-flag**. The table is only for judgment-level misuse the engine can't see (e.g. "skipped the diff review when `verify=both`"; "did it in raw git instead of the engine"). Plus three lean rules: **hard cap ≤7 entries** (past the cap, adding one removes/merges one); **phrase by category, not instance** (one entry — "don't do engine-owned git/codex ops by hand" — covers merge/worktree/branch-delete/resume); **provenance, not speculation** (seed ~4 from anticipated real misuse; subsystem B later grows/prunes the set with provenance). Meta-principle: **prefer mechanism over instruction everywhere; the skill text only carries what mechanism can't enforce.**

### 4.5 Result sidecar schema
`$(git rev-parse --git-dir)/codex-dispatch/<id>.json`:
```json
{
  "id": "20260531T143000-fix-auth",
  "created_at": "2026-05-31T14:30:00Z",
  "updated_at": "2026-05-31T14:34:10Z",
  "repo": "/abs/repo",
  "worktree": "/abs/.codex-dispatch-worktrees/repo/20260531T143000-fix-auth",
  "branch": "codex/fix-auth-ab12cd",
  "base_ref": "<sha at creation>",
  "verify": "both",
  "retry_budget": 1,
  "retries_used": 0,
  "session_id": "<uuid or null>",
  "status": "needs_review",
  "checks": [{ "cmd": "bash tests/run.sh", "exit": 0, "output_tail": "…" }],
  "touches_tests": false,
  "codex_last_message": "…"
}
```
`touches_tests` (resolves flag #3): the engine computes whether the diff touches test paths and surfaces `⚠ diff modifies tests` in the result **even in checks-only mode**, so verifier-gaming can't pass silently.

### 4.6 Codex invocation isolation (resolves flag #4)
Every codex call lives behind **one function in `lib/dispatch.sh`**. The primary resume path is `codex exec resume --last -C <worktree>` (cwd-scoped, independent of the `--json` event schema); UUID capture is best-effort for `list`/display only. `doctor` checks the codex version so drift is visible.

---

## 5. Acceptance criteria

C is "done" when, on this machine:
1. `dispatch --verify both --check '<cmd>' "<prompt>"` creates a worktree+branch from HEAD, invokes codex, runs the check, stops at `needs_review`, and prints diffstat + check result + `ALLOWED NEXT ACTIONS` — with the **full diff NOT dumped**.
2. `show <id> --diff` prints the full diff on demand.
3. A failing check with `--retry 1` triggers exactly one `codex exec resume`; still failing → `failed`, worktree retained.
4. `land <id>` refuses unless `needs_review` + verified; on success rebases onto HEAD, merges into the working branch, removes the worktree, sets `landed`; on conflict aborts cleanly and keeps the worktree.
5. `resume <id> "<fb>"` continues the codex session and re-verifies; `abandon <id>` removes worktree+branch.
6. `quick "<prompt>"` refuses a dirty tree without `--snapshot`; with a clean tree (or `--snapshot`) it edits in place, reports the diff, and creates no worktree.
7. Guardrails: wrong-status `land` refused; review-only `land` requires `--reviewed`; `dispatch` outside a git repo refused; unknown id errors with the valid-id list; `ALLOWED NEXT ACTIONS` present on every command.
8. `list` shows active dispatches; `doctor` reconciles a deliberately-orphaned sidecar/worktree and reports the codex version.
9. The `codex-implement` skill (decision table + checklist + ≤7-entry red-flag table; never instructing raw git/codex except quick `resume --last`) and `/codex-implement` command (full + `--quick`) are in place.
10. All `tests/dispatch_*_test.sh` pass via `tests/run.sh`, and A's existing tests still pass.

### Testing approach
- Extends A's **dependency-free pure-bash harness** (no bats), sandbox-isolated so tests never touch the real repo or `~/.codex`.
- `tests/lib.sh` gains `ps_make_fake_codex` (a fake `codex` driven by `FAKE_CODEX_BEHAVIOR=pass|fail|weaken-tests`: on `exec` writes a deterministic change + a fake `--json` session line + the `-o` last message; on `exec resume` makes a follow-up change) and `ps_make_sandbox_repo` (temp `git init` + seed commit + a fake check script). The engine honors `CODEX_DISPATCH_CODEX_BIN` to point at the fake (the `CCP_CLAUDE_BIN` pattern).
- Each acceptance criterion maps to at least one `dispatch_*_test.sh`.
- **Boundary note** (like A's keychain smoke checks): the fake proves the *engine's orchestration*, not real codex behavior. A short **manual smoke checklist** covers: real `codex exec` writes a diff in the worktree; real `codex exec resume` continues context; the full-access flag works end-to-end; resume picks the right session.

---

## 6. Out of scope
- **Subsystem B** internals (the learning daemon that will later grow/prune the red-flag set and learn dispatch heuristics with provenance). C ships a hand-curated seed only.
- **Subsystem A** changes — C consumes A's `_shared/skills/codex-implement/` symlink target and the shared machinery without modifying A.
- The **claude-peers role framework** (D5) — untouched.
- Multi-repo / cross-repo dispatch orchestration; parallel-dispatch auto-merge ordering (each dispatch is isolated; landing order is Claude's call).
- A persistent dispatch history/analytics store beyond the per-dispatch sidecars.

---

## 7. Risks & mitigations
- **R1 — Base-ref drift → land conflicts.** A dispatch branches from HEAD but codex may take minutes. *Mitigation:* `land` rebases onto current HEAD in the worktree, re-runs checks, then merges; clean abort + worktree retention on conflict (§4.3). (Resolved decision, flag #2.)
- **R2 — Quick mode has the least isolation.** `--quick` runs full-access codex in the live tree. *Mitigation:* clean-tree requirement + `--snapshot` restore point so it is always revertable (§4.3). (Resolved decision, flag #1.)
- **R3 — Full-access blast radius.** `--dangerously-bypass-approvals-and-sandbox` gives codex full disk + network; the worktree isolates the *tree*, not the *machine*. *Mitigation:* user's explicit, informed choice (C5); documented here; isolated worktree contains the diff-level blast radius; `--quick` snapshotting limits in-place damage. Revisable to `workspace-write` if it ever bites.
- **R4 — codex CLI drift.** The CLI moved 0.130→0.135 mid-project; the `--json` session-id event schema is the least stable surface. *Mitigation:* all codex calls behind one `lib/dispatch.sh` function; `resume --last -C <worktree>` (schema-independent) is primary; UUID capture is best-effort; `doctor` reports the codex version. (Flag #4.)
- **R5 — Verifier gaming.** Green checks ≠ correct (codex could weaken/delete tests). *Mitigation:* `touches_tests` warning surfaced even in checks-only mode (§4.5); `verify=both` review catches the rest; checks-only reserved for low-stakes tasks. (Flag #3.)
- **R6 — Sidecar ↔ git drift + worktree accumulation.** The sidecar is a second source of truth git can contradict; failed/abandoned dispatches retain worktrees that pile up. *Mitigation:* `doctor` reconciles against `git worktree list`, prunes stale/landed leftovers, reports drift (§4.2). (Flag #5.)
- **R7 — Skill ignored by Claude.** *Mitigation:* Layer 1 engine refusals make the unsafe outcomes impossible regardless of skill adherence (§4.4).

---

## 8. Open micro-decisions (defaulted; revisable)
- **MC1:** default `--retry` budget = `1`.
- **MC2:** worktree root = sibling `…/.codex-dispatch-worktrees/<repo>/<id>/` (vs. under the git dir). Chosen to keep worktrees out of the working tree and clear of git's own `.git/worktrees/` admin area.
- **MC3:** branch naming = `codex/<slug>-<shortid>`.
- **MC4:** dispatch id = `<UTC-timestamp>-<slug>`.
- **MC5:** `/codex-implement` is the command name (matches the skill name); no separate short alias for now.

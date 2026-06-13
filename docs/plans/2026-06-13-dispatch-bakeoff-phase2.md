# Dispatch Bake-off (Subsystem E, Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the multi-model bake-off — fan one task to N `(backend, model)` contestant cells in parallel, verify each, judge-rank the survivors, and return verdicts so the orchestrator lands exactly one (abandoning the rest).

**Architecture:** A single `Workflow`-tool script (`workflows/dispatch-bakeoff.js`) runs each contestant as a native dispatch cell (the Phase-1b `skills/dispatch/SKILL.md` contract: compose → `begin --label <model>` → delegate → `verify` once → `record`), `parallel()`-fanned, then a judge agent ranks survivors by diff quality. The workflow **lands nothing** (E9): it returns ranked verdicts + a recommendation, and the orchestrator reviews the winner's diff and runs `land`/`abandon`. Everything reuses the Phase-1b library, ledger, event log, and `land`/`abandon` unchanged — Phase 2 adds **no seam code**.

**Tech Stack:** Bash (the unchanged `bin/dispatch` library + pure-bash test harness `tests/run.sh`), one plain-JavaScript `Workflow` script (no TypeScript, no `Date.now`/`Math.random`, `meta` a pure literal — per the Workflow tool's constraints), a Claude slash command, and a manual smoke checklist for the parts fakes can't cover.

---

## ⚠️ Test-strategy note (read before starting)

This phase deviates from the strict red-green TDD loop the Phase-1a/1b plans used, **by design** and as the spec anticipated (§7 "Workflow caveat", line 210): the bake-off orchestrator is **JavaScript run by the Claude Code harness, not by the bash test runner**, so it cannot be unit-tested in `tests/run.sh`. Phase 2's correctness is therefore covered by **four** complementary mechanisms, only the first of which is a true behavioral test:

1. **`dispatch_bakeoff_spine_test.sh`** — a real behavioral test of the *library* in the bake-off shape: two contestants `begin`/`codex-run`/`verify`/`record` (fakes), then the orchestrator **lands one and abandons the rest**. This proves the spec's "lands exactly one via the same `land`" at the library level.
2. **Static-lint tests** of `workflows/dispatch-bakeoff.js` and `commands/dispatch-bakeoff.md` — grep-based contract checks (meta literal, plain-JS, no `Date.now`, references the right verbs, **lands nothing**), in the exact style of Phase-1b's `dispatch_skill_md_test.sh` / `dispatch_command_md_test.sh`.
3. **The existing `dispatch_bakeoff_id_test.sh`** (shipped in Phase 1b) — collision-free ids/branches for parallel same-slug contestants. **Reused unchanged.**
4. **A manual smoke checklist** (`docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md`) — the parts no fake can prove: real fan-out across real models, true-concurrent `git worktree add` safety, `/workflows` live surfacing, real diff-compare + land.

Where a task's "test" is a static lint or doc-presence guard, that is called out explicitly. **No task fabricates a behavioral test for the `.js` orchestrator.**

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `workflows/dispatch-bakeoff.js` | **Create** | The `Workflow` orchestrator: `parallel()` fan-out of contestant cells → judge → return verdicts + recommendation. Lands nothing (E9). First file in a new `workflows/` dir. |
| `commands/dispatch-bakeoff.md` | **Create** | `/dispatch-bakeoff` slash command: the explicit opt-in to the `Workflow` tool; parses `--models`/`--check`, invokes the workflow via `scriptPath`, then reviews + lands one / abandons the rest. Auto-symlinked by the installer's existing `commands/*.md` loop. |
| `tests/dispatch_bakeoff_spine_test.sh` | **Create** | Behavioral: library land-one/abandon-rest with fakes. |
| `tests/dispatch_bakeoff_workflow_test.sh` | **Create** | Static lint of `dispatch-bakeoff.js`. |
| `tests/dispatch_bakeoff_command_test.sh` | **Create** | Static lint of `dispatch-bakeoff.md`. |
| `tests/dispatch_bakeoff_smoke_doc_test.sh` | **Create** | Doc-presence guard: the smoke checklist exists and covers the key items. |
| `docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md` | **Create** | Manual smoke checklist (real models, concurrency, `/workflows`, land). |
| `docs/specs/2026-06-13-dispatch-harness-decoupling-design.md` | **Modify** (§10 append only) | Document the Phase-2 resolutions. **Status line stays `Approved (design); pending spec review`.** |
| `lib/*.sh`, `skills/dispatch/SKILL.md`, `bin/dispatch` | **UNTOUCHED** | The seam is frozen in Phase 2. |

**Invariants this plan must hold (do not violate):**
- The workflow **executes** no `land`/`abandon` and no raw `git`/`codex` — it returns next-actions; the orchestrator lands. (E9)
- No changes to `lib/dispatch-lib.sh`, `lib/dispatch.sh`, `lib/console.sh`, `bin/dispatch`, or `skills/dispatch/SKILL.md`.
- The full suite (`bash tests/run.sh`) stays green; commits land on `feat/subsystem-e-design` with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.

---

## Task 1: Library bake-off spine — land one, abandon the rest

Proves the spec's central Phase-2 claim ("the orchestrator diff-compares survivors and lands exactly one via the **same** `land <id>`") at the library level, with fakes. This is a **behavioral** test. It exercises *existing* Phase-1b library behavior composed into the bake-off shape, so it should pass on first run; a failure means a real Phase-1b gap — **stop and report, do not paper over it.**

**Files:**
- Test: `tests/dispatch_bakeoff_spine_test.sh`

- [ ] **Step 1: Write the test**

Create `tests/dispatch_bakeoff_spine_test.sh`:

```bash
#!/usr/bin/env bash
# Bake-off spine (library level): two contestants reach needs_review in distinct
# worktrees; the orchestrator lands EXACTLY ONE and abandons the rest. Proves
# spec §5.6 "lands exactly one via the same land <id>" without the JS orchestrator
# (which is harness-run and not bash-testable — see the plan's test-strategy note).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
FAKE="$(ps_make_fake_codex)"            # honors -C/-o/--json; pass behavior writes IMPL=ok
export CODEX_DISPATCH_CODEX_BIN="$FAKE"
ro="$(ps_make_sandbox_repo ok)"

base_head() { git -C "$ro" rev-parse HEAD; }

# --- Fan out two contestants: SAME slug, DIFFERENT --label (the bake-off shape) ----
A="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T130000Z bash "$DISPATCH" begin race --label gpt-5.5 --verify checks )"
B="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T130001Z bash "$DISPATCH" begin race --label qwen2.5 --verify checks )"
assert_eq "$A" "20260613T130000Z-race-gpt-5-5" "contestant A id embeds the label"
assert_eq "$B" "20260613T130001Z-race-qwen2-5" "contestant B id embeds the label"

# Each contestant: codex-run (fake writes IMPL=ok in ITS OWN worktree) -> verify once -> record.
( cd "$ro" && bash "$DISPATCH" codex-run "$A" --backend codex -m gpt-5.5 "implement A" ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" codex-run "$B" --backend codex -m qwen2.5 "implement B" ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" verify "$A" --check 'bash check.sh' ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" verify "$B" --check 'bash check.sh' ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" record "$A" --status needs_review ) >/dev/null 2>&1
( cd "$ro" && bash "$DISPATCH" record "$B" --status needs_review ) >/dev/null 2>&1

# Both reviewable, in distinct worktrees, before any landing.
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$A" '.status')" "needs_review" "A reviewable pre-land"
  assert_eq "$(d_sc_get "$B" '.status')" "needs_review" "B reviewable pre-land"
  wta="$(d_sc_get "$A" '.worktree')"; wtb="$(d_sc_get "$B" '.worktree')"
  assert_file "$wta" "A worktree present pre-land"
  assert_file "$wtb" "B worktree present pre-land"
  case "$wta" in "$wtb") echo "  FAIL: contestants share a worktree"; exit 1;; esac )

# Orchestrator review surface: show --diff is available and non-empty for the winner.
diffout="$( cd "$ro" && bash "$DISPATCH" show "$A" --diff 2>/dev/null )"
assert_contains "$diffout" "IMPL" "show --diff surfaces the winner's change for review"

# --- LAND EXACTLY ONE (A) ----
pre_land_head="$(base_head)"
landout="$( cd "$ro" && bash "$DISPATCH" land "$A" 2>&1 )"
assert_contains "$landout" "Landed $A" "winner A lands"
case "$(base_head)" in "$pre_land_head") echo "  FAIL: land did not advance base HEAD"; exit 1;; esac
assert_eq "ok" "ok" "land advanced the base branch HEAD"
# winner's commit (its codex-run commit message embeds the id) reached the base branch:
assert_contains "$(git -C "$ro" log --oneline -10)" "$A" "winner A's commit merged into base"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$A" '.status')" "landed" "A status=landed"
  wta="$(d_sc_get "$A" '.worktree')"
  [ -d "$wta" ] && { echo "  FAIL: winner worktree not removed after land"; exit 1; }
  assert_eq "ok" "ok" "winner worktree removed after land" )

# --- ABANDON THE REST (B) ----
abandonout="$( cd "$ro" && bash "$DISPATCH" abandon "$B" 2>&1 )"
assert_contains "$abandonout" "Abandoned $B" "loser B is abandoned"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$B" '.status')" "abandoned" "B status=abandoned"
  wtb="$(d_sc_get "$B" '.worktree')"
  [ -d "$wtb" ] && { echo "  FAIL: loser worktree not removed after abandon"; exit 1; }
  assert_eq "ok" "ok" "loser worktree removed after abandon" )
# the loser's commit never reached the base branch:
if git -C "$ro" log --oneline | grep -q "$B"; then echo "  FAIL: loser commit leaked onto base"; exit 1; fi
assert_eq "ok" "ok" "loser's commit never reached the base branch"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it — expect PASS (characterization of existing library behavior)**

Run: `bash tests/dispatch_bakeoff_spine_test.sh`
Expected: all assertions PASS, final line `... passed`. **If anything fails, STOP** — it means a Phase-1b gap in `land`/`abandon`/`verify`; report it rather than editing the seam under this plan.

- [ ] **Step 3: Run the full suite**

Run: `bash tests/run.sh`
Expected: `=== N/N test files passed ===` with N = previous baseline + 1 (this new file). (`curator_loop_test.sh` is a known intermittent full-suite flake — if it wedges, re-run the suite; it passes in isolation.)

- [ ] **Step 4: Commit**

```bash
git add tests/dispatch_bakeoff_spine_test.sh
git commit -m "test(subsystem-e): bake-off spine — library lands one, abandons the rest

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: The bake-off Workflow script

The `Workflow`-tool orchestrator. Write the **static lint first** (it fails until the file exists), then the `.js`.

**Files:**
- Test: `tests/dispatch_bakeoff_workflow_test.sh`
- Create: `workflows/dispatch-bakeoff.js`

- [ ] **Step 1: Write the static-lint test**

Create `tests/dispatch_bakeoff_workflow_test.sh`:

```bash
#!/usr/bin/env bash
# Static lint of the bake-off Workflow script. The .js is harness-run JavaScript, not
# bash-testable (see the plan's test-strategy note) — so we assert its CONTRACT by grep:
# pure-literal meta, plain JS, Workflow-safe (no Date.now/Math.random), the right dispatch
# verbs, structured verdicts, and the E9 invariant (LANDS NOTHING).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
JS="$PS_REPO_ROOT/workflows/dispatch-bakeoff.js"

assert_file "$JS" "bake-off workflow script exists"
body="$(cat "$JS")"

# --- meta block (the Workflow tool requires a pure-literal meta) ---
assert_contains "$body" "export const meta" "exports a meta block"
assert_contains "$body" "name: 'dispatch-bakeoff'" "meta.name is dispatch-bakeoff"
assert_contains "$body" "description:" "meta has a description"
assert_contains "$body" "phases:" "meta declares phases"

# --- plain JavaScript only (Workflow scripts are JS, not TS) ---
if grep -qE ":[[:space:]]*(string|number|boolean)\b" "$JS"; then
  echo "  FAIL: looks like a TypeScript type annotation (Workflow scripts are plain JS)"; exit 1; fi
if grep -q "interface " "$JS"; then echo "  FAIL: TS 'interface' found"; exit 1; fi
assert_eq "ok" "ok" "no TypeScript annotations"

# --- Workflow runtime constraints (these throw inside a workflow) ---
for bad in 'Date.now' 'Math.random' 'new Date('; do
  if grep -qF "$bad" "$JS"; then echo "  FAIL: forbidden Workflow API '$bad'"; exit 1; fi
done
assert_eq "ok" "ok" "no Date.now / Math.random / new Date()"

# --- fan-out + structured output ---
assert_contains "$body" "parallel(" "fans out contestants with parallel()"
assert_contains "$body" "agent(" "spawns contestant cells via agent()"
assert_contains "$body" "schema:" "forces structured verdicts via a schema"

# --- drives the dispatch CLI through the cell contract ---
assert_contains "$body" "dispatch begin" "cell prompt drives begin"
assert_contains "$body" "--label" "begin uses --label (collision-free ids §5.6)"
assert_contains "$body" "codex-run" "cell prompt drives codex-run"
assert_contains "$body" "dispatch verify" "cell prompt drives verify"
assert_contains "$body" "dispatch record" "cell prompt drives record"
assert_contains "$body" "dispatch show" "judge/verdict reads diffs via show"

# --- default contestant set: gpt + qwen + a direct-Claude cell (spec §5.6) ---
assert_contains "$body" "gpt-5.5" "default contestant gpt-5.5"
assert_contains "$body" "qwen2.5" "default contestant qwen2.5"
assert_contains "$body" "claude"  "default contestant claude (direct cell)"

# --- E9: the workflow LANDS NOTHING; the orchestrator lands one ---
assert_contains "$body" "LANDS NOTHING" "carries the E9 sentinel"
assert_contains "$body" "NEVER LAND" "contestant prompt forbids landing"
assert_contains "$body" "args.task" "reads the task from args"

ps_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/dispatch_bakeoff_workflow_test.sh`
Expected: FAIL on the first assertion (`bake-off workflow script exists`) — the `.js` does not exist yet.

- [ ] **Step 3: Write the workflow script**

Create `workflows/dispatch-bakeoff.js`:

```javascript
export const meta = {
  name: 'dispatch-bakeoff',
  description: 'Fan one task to N (backend,model) contestant cells in isolated worktrees; verify each; a judge ranks the survivors; return verdicts for the orchestrator to land exactly one.',
  phases: [
    { title: 'Bake-off', detail: 'one dispatch cell per contestant: compose -> begin --label -> delegate -> verify -> record' },
    { title: 'Judge', detail: 'review each survivor diff; recommend a single winner' },
  ],
}

// ---------------------------------------------------------------------------
// E9: this workflow LANDS NOTHING. It fans out contestant cells, verifies each,
// and a judge ranks the survivors — then it RETURNS verdicts + a recommendation.
// The orchestrator (main session) reviews the winner's diff and runs `land`
// (exactly one) + `abandon` (the rest). The cells never land; neither does this.
// ---------------------------------------------------------------------------

// args: { task: string, slug?: string, contestants?: [{backend, model}], checks?: string[] }
const A = args || {}
const task = (A.task || '').trim()
if (!task) throw new Error('dispatch-bakeoff: args.task is required (the work to bake off)')
const slug = A.slug || 'bakeoff'
const checks = Array.isArray(A.checks) ? A.checks : []
const contestants = Array.isArray(A.contestants) && A.contestants.length
  ? A.contestants
  : [
      { backend: '—',  model: 'claude'  }, // em-dash backend: a direct Claude cell (no codex)
      { backend: 'codex',   model: 'gpt-5.5' },
      { backend: 'ollama',  model: 'qwen2.5' },
    ]

// Each contestant returns this — forced via agent({schema}); no parsing needed.
const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'backend', 'model', 'status', 'checks_passed', 'touches_tests'],
  properties: {
    id:            { type: 'string',  description: 'the dispatch id echoed by begin' },
    harness:       { type: 'string',  description: "always 'workflow' for a bake-off contestant" },
    backend:       { type: 'string',  description: 'codex | ollama | em-dash (direct claude)' },
    model:         { type: 'string',  description: 'the contestant model' },
    status:        { type: 'string',  enum: ['needs_review', 'failed', 'noop'] },
    checks_passed: { type: 'boolean', description: 'did every verify --check pass' },
    touches_tests: { type: 'boolean', description: 'does the diff add/modify/delete test files' },
    diffstat:      { type: 'string',  description: 'output of `dispatch show <id>` (NOT --diff)' },
    check_summary: { type: 'string',  description: 'one-line summary of the verify result' },
    notes:         { type: 'string',  description: 'optional: blockers, scope cuts, caveats' },
  },
}

const RECO_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['winner_id', 'why', 'ranking'],
  properties: {
    winner_id:            { type: 'string', description: 'id of the single best implementation' },
    why:                  { type: 'string', description: 'concise justification grounded in the diffs' },
    ranking:              { type: 'array',  items: { type: 'string' }, description: 'ids, best -> worst' },
    test_integrity_flags: { type: 'array',  items: { type: 'string' }, description: 'ids whose diff weakened/deleted tests' },
  },
}

function checkFlags() {
  return checks.length ? checks.map(q => `--check '${q}'`).join(' ') : ''
}

// A self-contained dispatch-cell prompt (the SKILL contract inlined so the cell works
// even if skills aren't auto-loaded in the subagent). NEVER LAND is the E9 guardrail.
function cellPrompt(c) {
  const verifyMode = checks.length ? 'checks' : 'review'
  const verifyLine = checks.length
    ? `   dispatch verify "$id" ${checkFlags()}`
    : `   (review-only worker: skip --check; you still record a status)`
  return [
    `You are a DISPATCH CELL — one contestant in a multi-model bake-off. Other cells`,
    `implement the SAME task in parallel on different workers. Follow the dispatch cell`,
    `contract (skills/dispatch/SKILL.md): compose -> begin -> delegate -> verify ONCE ->`,
    `record -> return a verdict. Shell to the \`dispatch\` CLI (on PATH; if not found use`,
    `~/.claude/profile-system/bin/dispatch). Each Bash call is a fresh shell: capture the`,
    `<id> that begin echoes and thread it through every later call.`,
    ``,
    `TASK:`,
    task,
    ``,
    `YOUR WORKER: backend=${c.backend}, model=${c.model}.`,
    ``,
    `1. COMPOSE: use Read/Grep/Glob to understand the task in repo context; write a precise prompt.`,
    `2. BEGIN:  id="$(dispatch begin ${slug} --label ${c.model} --verify ${verifyMode})"   # capture <id>`,
    `3. DELEGATE by model:`,
    `   - Claude model (claude/opus/sonnet/haiku/fable): implement DIRECTLY — edit the files`,
    `     in the begin-returned worktree (find its path via \`dispatch show "$id"\`). Do NOT`,
    `     codex-run a Claude model; the library refuses it (E10).`,
    `   - Otherwise: dispatch codex-run "$id" --backend ${c.backend} -m ${c.model} "<your composed prompt>"`,
    `4. VERIFY ONCE, then DECIDE (no auto-retry):`,
    verifyLine,
    `   pass -> dispatch record "$id" --status needs_review ; fixable -> codex-run/edit again then`,
    `   re-verify ; stuck/out-of-scope -> dispatch record "$id" --status failed`,
    `5. NEVER LAND. NEVER abandon. Return the verdict object only (fill diffstat from`,
    `   \`dispatch show "$id"\`, NOT --diff). The orchestrator reviews and lands exactly one.`,
  ].join('\n')
}

phase('Bake-off')
const verdicts = (await parallel(
  contestants.map((c) => () =>
    agent(cellPrompt(c), { label: `bakeoff:${c.model}`, phase: 'Bake-off', schema: VERDICT_SCHEMA })
  )
)).filter(Boolean)

const survivors = verdicts.filter(v => v && v.status === 'needs_review')
log(`${survivors.length}/${verdicts.length} contestants produced a reviewable result`)

phase('Judge')
let recommendation = null
if (survivors.length === 1) {
  recommendation = { winner_id: survivors[0].id, why: 'only surviving contestant', ranking: [survivors[0].id], test_integrity_flags: [] }
} else if (survivors.length > 1) {
  const board = survivors.map(v =>
    `- ${v.id}  [${v.backend}/${v.model}]  checks_passed=${v.checks_passed}  touches_tests=${v.touches_tests}\n` +
    `    diffstat: ${String(v.diffstat || '').replace(/\n/g, ' ')}`
  ).join('\n')
  recommendation = await agent([
    `You are the BAKE-OFF JUDGE. You only RANK — do NOT land or abandon anything.`,
    `Several dispatch cells implemented the SAME task on different (backend,model) workers.`,
    `Review EACH survivor's full diff:  dispatch show <id> --diff`,
    `Pick the single best implementation. Heavily penalize diffs that weaken or DELETE tests`,
    `to make checks pass — list any such ids in test_integrity_flags.`,
    ``,
    `TASK:`,
    task,
    ``,
    `SURVIVORS:`,
    board,
    ``,
    `Return {winner_id, why, ranking (best->worst), test_integrity_flags}.`,
  ].join('\n'), { label: 'judge', phase: 'Judge', schema: RECO_SCHEMA })
}

const allIds = verdicts.map(v => v.id)
const winner = recommendation ? recommendation.winner_id : null
return {
  task,
  slug,
  contestants: verdicts,
  survivors: survivors.map(v => v.id),
  losers: verdicts.filter(v => v.status !== 'needs_review').map(v => v.id),
  recommendation,
  // The ORCHESTRATOR acts on these — the workflow LANDS NOTHING (E9):
  next_actions: winner
    ? [
        `Review the winner:  dispatch show ${winner} --diff`,
        recommendation.test_integrity_flags && recommendation.test_integrity_flags.length
          ? `SCRUTINIZE test integrity for: ${recommendation.test_integrity_flags.join(', ')}`
          : `No test-integrity flags raised.`,
        `Land exactly one:   dispatch land ${winner}`,
        `Abandon the rest:   ${allIds.filter(x => x !== winner).map(x => `dispatch abandon ${x}`).join('  ;  ') || '(none)'}`,
      ]
    : [`No reviewable contestant. Inspect with \`dispatch console\`, then \`dispatch abandon <id>\` each.`],
}
```

- [ ] **Step 4: Run the static lint to verify it passes**

Run: `bash tests/dispatch_bakeoff_workflow_test.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Validate the script shape (the Workflow tool is the real executor)**

Do **not** run `node --check` here. The script is ESM (`export const meta`) executed by the
Workflow tool, and this repo has no `package.json` with `"type":"module"`, so `node --check`
on a bare `.js` misreads it as CommonJS and **false-fails on `export`**. The script's
syntax/shape is validated by (a) the static lint in Step 4 and (b) the **real run** in the
Task 4 smoke checklist (the authoritative check — the Workflow tool surfaces any syntax error
on first invocation). Sanity-eyeball the braces/quotes instead:

Run: `grep -c "agent(" workflows/dispatch-bakeoff.js`
Expected: ≥ `2` (the contestant fan-out call + the judge call) — a cheap smoke that the body wrote through.

- [ ] **Step 6: Commit**

```bash
git add workflows/dispatch-bakeoff.js tests/dispatch_bakeoff_workflow_test.sh
git commit -m "feat(subsystem-e): bake-off Workflow — parallel contestants, judge, land-nothing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: The `/dispatch-bakeoff` command

The ergonomic entry and the **explicit opt-in to the `Workflow` tool**. Static lint first, then the markdown.

**Files:**
- Test: `tests/dispatch_bakeoff_command_test.sh`
- Create: `commands/dispatch-bakeoff.md`

- [ ] **Step 1: Write the static-lint test**

Create `tests/dispatch_bakeoff_command_test.sh`:

```bash
#!/usr/bin/env bash
# Static lint of the /dispatch-bakeoff command markdown (style mirrors
# dispatch_command_md_test.sh). It must declare the Workflow tool (the opt-in),
# reference the workflow scriptPath, expand $ARGUMENTS, and encode land-one/abandon-rest.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MD="$PS_REPO_ROOT/commands/dispatch-bakeoff.md"

assert_file "$MD" "/dispatch-bakeoff command markdown exists"
body="$(cat "$MD")"
assert_contains "$body" "argument-hint:" "frontmatter has an argument-hint"
assert_contains "$body" "allowed-tools:" "frontmatter declares allowed-tools"
assert_contains "$body" "Workflow" "declares/uses the Workflow tool (the opt-in)"
assert_contains "$body" "dispatch-bakeoff.js" "references the workflow script"
assert_contains "$body" "scriptPath" "invokes the workflow via scriptPath"
assert_contains "$body" "\$ARGUMENTS" "expands the user task"
assert_contains "$body" "dispatch land" "orchestrator lands the winner"
assert_contains "$body" "dispatch abandon" "orchestrator abandons the rest"
assert_contains "$body" "Only the orchestrator lands" "encodes the E9 invariant"
assert_contains "$body" "/dispatch" "notes the relationship to single-worker /dispatch"

ps_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/dispatch_bakeoff_command_test.sh`
Expected: FAIL on the first assertion (file does not exist yet).

- [ ] **Step 3: Write the command markdown**

Create `commands/dispatch-bakeoff.md`:

```markdown
---
description: Bake one task off across N (backend,model) workers in parallel via a Workflow — each a dispatch cell in its own worktree — then review the winner's diff and land exactly one, abandoning the rest
argument-hint: [--models gpt-5.5,qwen2.5,claude] [--check 'cmd']... "<task>"
allowed-tools: Workflow, Bash, Read
---

Run a **multi-model dispatch bake-off** for the user's task, then land exactly one winner.

Task: `$ARGUMENTS`

- Parse `--models <a,b,c>` (default `gpt-5.5,qwen2.5,claude`) and any `--check 'cmd'` flags
  from `$ARGUMENTS`; the remainder is the task description. Map each model to a backend:
  `claude` (or `opus`/`sonnet`/`haiku`/`fable`) → a direct cell (no codex); `qwen*` → `ollama`;
  everything else → `codex`.
- Invoke the bake-off Workflow — **this is your explicit opt-in to the `Workflow` tool**:
  `Workflow({ scriptPath: "<HOME>/.claude/profile-system/workflows/dispatch-bakeoff.js",
    args: { task: "<task>", slug: "<short-slug>", contestants: [{backend, model}, ...],
            checks: ["<cmd>", ...] } })`
  (Expand `<HOME>` to the absolute home path; `scriptPath` does not expand `~`.)
  The workflow fans out one **dispatch cell per contestant** (each follows the dispatch skill:
  compose → `begin --label <model>` → delegate → `verify` once → `record`), then a judge ranks
  the survivors. The workflow **lands nothing** (E9) — it returns verdicts + a recommendation.
- When the workflow returns: review the recommended winner with `dispatch show <winner_id> --diff`
  and actually read it — scrutinize any id in `recommendation.test_integrity_flags` for
  weakened/deleted tests. Then take exactly one landing decision: `dispatch land <winner_id>`,
  and `dispatch abandon <id>` for every other contestant. **Only the orchestrator lands** — the
  cells and the workflow never do.
- Never run raw git/codex; always go through the `dispatch` CLI. Watch progress live with
  `/workflows` or `dispatch console`; live-tail one contestant with `dispatch attach <id>`.

> Companion to `/dispatch` (single worker). The bake-off reuses the same library, ledger, and
> `land` — it is just the parallel, pick-one form.
```

- [ ] **Step 4: Run the static lint to verify it passes**

Run: `bash tests/dispatch_bakeoff_command_test.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Confirm the installer ships it (no installer change needed)**

The installer's existing loop symlinks every `commands/*.md` into the profile (`lib/install-common.sh`, the `for c in "$SHARED/commands"/*.md` block). Verify the new command is picked up by that glob — no edit required:

Run: `ls commands/dispatch-bakeoff.md && grep -q 'for c in "\$SHARED/commands"/\*.md' lib/install-common.sh && echo "ships via existing loop"`
Expected: prints the path and `ships via existing loop`.

- [ ] **Step 6: Commit**

```bash
git add commands/dispatch-bakeoff.md tests/dispatch_bakeoff_command_test.sh
git commit -m "feat(subsystem-e): /dispatch-bakeoff command (Workflow opt-in, land one)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Manual smoke checklist

Captures everything fakes can't prove. Doc-presence guard test first, then the doc.

**Files:**
- Test: `tests/dispatch_bakeoff_smoke_doc_test.sh`
- Create: `docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md`

- [ ] **Step 1: Write the doc-presence guard test**

Create `tests/dispatch_bakeoff_smoke_doc_test.sh`:

```bash
#!/usr/bin/env bash
# Guard: the Phase-2 manual smoke checklist exists and covers the items no fake can
# prove (the spec §7 "Workflow caveat" boundary). Keeps the checklist from bit-rotting.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
DOC="$PS_REPO_ROOT/docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md"

assert_file "$DOC" "bake-off smoke checklist exists"
body="$(cat "$DOC")"
assert_contains "$body" "/workflows" "covers /workflows live surfacing"
assert_contains "$body" "worktree" "covers concurrent git worktree add safety"
assert_contains "$body" "concurrent" "explicitly calls out concurrency"
assert_contains "$body" "dispatch land" "covers landing exactly one"
assert_contains "$body" "dispatch abandon" "covers abandoning the rest"
assert_contains "$body" "dispatch attach" "covers live attach"
assert_contains "$body" "claude" "covers the direct-Claude contestant"
assert_contains "$body" "test_integrity_flags" "covers judge test-integrity flagging"

ps_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/dispatch_bakeoff_smoke_doc_test.sh`
Expected: FAIL on the first assertion (doc does not exist yet).

- [ ] **Step 3: Write the smoke checklist**

Create `docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md`:

```markdown
# Manual smoke checklist — dispatch bake-off (Subsystem E, Phase 2)

The bake-off orchestrator (`workflows/dispatch-bakeoff.js`) is JavaScript run by the
Claude Code harness, **not** by the bash test suite. The automated tests cover the
library spine (land-one/abandon-rest) and the static contracts; this checklist covers
what only a real run can prove. Run it on this machine after any change to the workflow,
the command, or the cell contract.

## Prerequisites
- [ ] `codex` is installed and authenticated (cloud `gpt-5.5` reachable).
- [ ] (Optional, for the local contestant) the ollama backend is configured and a model
      server is ready (`dispatch doctor` shows the local backend), so `qwen2.5` can run.
- [ ] A throwaway git repo with a small, real task and a real check command
      (e.g. `npm test`, `pytest`, or `bash check.sh`).

## 1. Fan-out + live surfacing
- [ ] Run: `/dispatch-bakeoff --models gpt-5.5,qwen2.5 --check '<your check>' "<your task>"`.
- [ ] Confirm **two contestant cells** appear in the `/workflows` live view, each progressing
      through the `Bake-off` phase, then a single `Judge` agent.
- [ ] Confirm the same dispatches appear in `dispatch console` with
      `id · harness · backend · model · status · last-activity`, `harness=workflow`.
- [ ] `dispatch attach <id>` on one contestant live-tails its event log (codex `--json`
      progress for the gpt/qwen cells).

## 2. Concurrent worktree safety (the gap the bash test does NOT cover)
- [ ] The automated `dispatch_bakeoff_id_test.sh` proves collision-free ids for **sequential**
      begins only. Here, both `begin` calls fire under **true parallelism**. Confirm both
      contestants created **distinct worktrees with no `git worktree add` lock error** in the
      cell logs.
- [ ] If you see a worktree/lock error: that is the R5 contention case. Fallback (a Phase-2.x
      follow-up, NOT a seam change made blind): add a short lock-retry around `git worktree add`
      in `d_begin`. File it; do not patch the seam without a paired review.

## 3. Verdicts + judge
- [ ] Each contestant returns a **schema-valid verdict** (the workflow does not error on
      structured output; `id/backend/model/status/checks_passed/touches_tests` present).
- [ ] With ≥2 survivors, the judge returns a `recommendation` with `winner_id`, `why`,
      `ranking`, and — if any contestant weakened tests — populated `test_integrity_flags`.
- [ ] To exercise the integrity path on purpose, give one model a task it is tempted to "pass"
      by editing the test; confirm the judge flags it and you can see it in `recommendation.test_integrity_flags`.

## 4. Land exactly one / abandon the rest (the orchestrator's job — E9)
- [ ] Review the winner: `dispatch show <winner_id> --diff` (actually read it).
- [ ] `dispatch land <winner_id>` → confirm it merges onto HEAD, removes the worktree,
      and sets status `landed`.
- [ ] `dispatch abandon <id>` for each other contestant → worktrees removed, status `abandoned`,
      their changes absent from the base branch.
- [ ] Confirm the **workflow itself landed/abandoned nothing** — all of it was your decision.

## 5. Direct-Claude contestant
- [ ] Run a bake-off whose contestant set includes `claude`. Confirm the `(—, claude)` cell
      **edits files directly in its worktree** (no `codex-run`) and produces a landable diff.
- [ ] If the contestant cannot edit files (the default Workflow subagent lacks editing tools):
      note it. Fallback: set `agentType` on that `agent()` call to a coding-capable agent. This
      is a workflow-script tweak only — it does not touch the seam.

## 6. Back-compat unaffected (E8)
- [ ] `/codex-implement "<task>"` still drives the original `harness=codex` autonomous loop
      end-to-end. The bake-off must not have disturbed it.
```

- [ ] **Step 4: Run the guard test to verify it passes**

Run: `bash tests/dispatch_bakeoff_smoke_doc_test.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md tests/dispatch_bakeoff_smoke_doc_test.sh
git commit -m "docs(subsystem-e): bake-off manual smoke checklist + guard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Document Phase 2 resolutions in the spec (§10 append only)

Mirror the Phase-1b precedent: append a resolved-notes subsection to §10. **Do NOT touch the `Status:` line** — it stays `Approved (design); pending spec review` until the author re-reads.

**Files:**
- Modify: `docs/specs/2026-06-13-dispatch-harness-decoupling-design.md` (append to §10 only)

- [ ] **Step 1: Confirm the current Status line (must stay unchanged)**

Run: `grep -n "Status:" docs/specs/2026-06-13-dispatch-harness-decoupling-design.md | head -1`
Expected: shows `- **Status:** Approved (design); pending spec review`. Note the line number; it must read identically after this task.

- [ ] **Step 2: Append the Phase-2 subsection at the END of §10**

Add this block at the end of the §10 section (after the Phase-1b resolved-notes subsection):

```markdown
### Resolved in Phase 2 implementation (2026-06-13)

- **The bake-off is a `Workflow`-tool script** (`workflows/dispatch-bakeoff.js`, the first file
  in a new `workflows/` dir): `parallel()` fan-out of contestant cells (each the Phase-1b
  dispatch SKILL contract) → a judge agent ranks survivors → it **returns verdicts +
  a recommendation and lands nothing**. The orchestrator reviews the recommended winner's diff
  and runs `land` (exactly one) + `abandon` (the rest), so **E9 holds end-to-end** — landing is
  never inside the workflow or a cell.
- **Invocation / Workflow opt-in:** a new `/dispatch-bakeoff` command (`commands/dispatch-bakeoff.md`)
  is the explicit opt-in to the `Workflow` tool and parses `--models`/`--check`; it invokes the
  workflow by **`scriptPath`** (no dependency on Claude Code's named-workflow discovery). It ships
  via the installer's existing `commands/*.md` symlink loop — no installer change. *Note:* §5.1
  enumerated only `commands/dispatch.md`; this companion command is additive and is the natural
  ergonomic + opt-in surface for the parallel form.
- **Contracts are inline JSON-Schema literals** in the `.js` (verdict + recommendation). Workflow
  scripts have **no filesystem access**, so a separate `.json` schema can't be read at runtime;
  each contestant is forced to structured output via `agent({schema})`.
- **Testability boundary (as §7 "Workflow caveat" anticipated):** the orchestrator `.js` is not
  bash-unit-testable. Phase 2 covers it with (a) `dispatch_bakeoff_spine_test.sh` — the **library**
  land-one/abandon-rest flow with fakes; (b) static-lint tests of the `.js` and the command md;
  (c) the existing `dispatch_bakeoff_id_test.sh`; and (d) a manual smoke checklist
  (`docs/smoke/2026-06-13-dispatch-bakeoff-smoke.md`).
- **Deferred to smoke (honest gaps):** true-concurrent `git worktree add` safety (the bash tests
  exercise sequential begins only — R5 contention) and the default Workflow subagent's editing
  tools for the direct-Claude contestant. Documented fallbacks: add a lock-retry to `d_begin`
  (paired-review change, not blind) / set `agentType` to a coding agent. **The seam is NOT touched
  in Phase 2** (no changes to `lib/*.sh`, `bin/dispatch`, or `skills/dispatch/SKILL.md`).
- **Status line intentionally unchanged** (still `Approved (design); pending spec review`).
```

- [ ] **Step 3: Verify the Status line is still unchanged**

Run: `grep -n "Status:" docs/specs/2026-06-13-dispatch-harness-decoupling-design.md | head -1`
Expected: identical to Step 1 — `- **Status:** Approved (design); pending spec review`.

- [ ] **Step 4: Commit**

```bash
git add docs/specs/2026-06-13-dispatch-harness-decoupling-design.md
git commit -m "docs(subsystem-e): record Phase 2 resolutions in spec §10 (status unchanged)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Acceptance check (run after all tasks)

- [ ] **Full suite green:** `bash tests/run.sh` → `=== N/N test files passed ===`, N = Phase-1b baseline + **4** new test files (`dispatch_bakeoff_spine`, `_workflow`, `_command`, `_smoke_doc`). (Re-run if `curator_loop_test.sh` flakes.)
- [ ] **Workflow validated by smoke, not `node`:** the `.js` is ESM run by the Workflow tool; its real validation is the Task 4 smoke run. (`node --check` on a bare `.js` false-fails on ESM and is intentionally not used.)
- [ ] **Seam untouched:** `git diff --name-only <phase-2-base>..HEAD` lists **no** changes to `lib/dispatch-lib.sh`, `lib/dispatch.sh`, `lib/console.sh`, `bin/dispatch`, or `skills/dispatch/SKILL.md`.
- [ ] **E9 preserved:** the workflow executes no `land`/`abandon` (it only emits them as `next_actions` strings); the spine test proves the orchestrator-driven land-one/abandon-rest path.
- [ ] **AC mapping (spec §7):** the bake-off realizes "the orchestrator diff-compares survivors and lands exactly one via the same `land`" (§5.6) — proven at the library level by `dispatch_bakeoff_spine_test.sh` and end-to-end by the smoke checklist §4.
- [ ] **Status line unchanged:** spec still reads `Approved (design); pending spec review`.

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-06-13-dispatch-bakeoff-phase2.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?

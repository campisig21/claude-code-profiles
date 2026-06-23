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

// args fields: task (required), slug (optional), contestants (optional array of {backend, model}), checks (optional array of strings)
// args may arrive parsed (the workflow() hook passes a real object) OR as a JSON
// string (the top-level Workflow tool launched via scriptPath delivers args
// stringified) — normalize both, else every A.field reads undefined.
let A = {}
if (args && typeof args === 'object') A = args
else if (typeof args === 'string' && args.trim()) {
  try { A = JSON.parse(args) } catch (e) { throw new Error('dispatch-bakeoff: args is a string but not valid JSON: ' + e.message) }
}
const task = (A.task || '').trim()
if (!task) throw new Error('dispatch-bakeoff: args.task is required (the work to bake off)')
const slug = A.slug || 'bakeoff'
const repo = (A.repo || '').trim()   // optional: target repo the cells operate in (else cwd)
const checks = Array.isArray(A.checks) ? A.checks : []
const contestants = Array.isArray(A.contestants) && A.contestants.length
  ? A.contestants
  : [
      { backend: '—',            model: 'claude'          }, // em-dash backend: a direct Claude cell (no codex)
      { backend: 'codex',        model: 'gpt-5.5'         },
      { backend: 'ollama',       model: 'qwen2.5'         },
      { backend: 'claude-local', model: 'qwen3-coder-30b' }, // claude -p on the local station via bin/claude-run cell
    ]

// Each contestant returns this — forced via agent({schema}); no parsing needed.
const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'backend', 'model', 'status', 'checks_passed', 'touches_tests'],
  properties: {
    id:            { type: 'string',  description: 'the dispatch id echoed by begin' },
    harness:       { type: 'string',  description: "always 'workflow' for a bake-off contestant" },
    backend:       { type: 'string',  description: 'codex | ollama | claude-local | em-dash (direct claude)' },
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

// A Claude model is implemented directly in the cell (no codex), so it needs a
// subagent with real editing tools — pin one via agentType (resolves a smoke gap).
function isClaudeModel(m) {
  return /^(claude|opus|sonnet|haiku|fable)(-|$)/.test(String(m || ''))
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
    repo ? `WORKING DIR: every Bash command MUST start with: cd ${repo} && ...  — ${repo} is the target repo (each Bash call is a fresh shell).` : ``,
    ``,
    `TASK:`,
    task,
    ``,
    `YOUR WORKER: backend=${c.backend}, model=${c.model}.`,
    ``,
    `1. COMPOSE: use Read/Grep/Glob to understand the task in repo context; write a precise prompt.`,
    `2. BEGIN:  id="$(dispatch begin ${slug} --label ${c.model} --verify ${verifyMode})"   # capture <id>`,
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
  contestants.map((c) => () => {
    const opts = { label: `bakeoff:${c.model}`, phase: 'Bake-off', schema: VERDICT_SCHEMA }
    if (isClaudeModel(c.model)) opts.agentType = 'general-purpose'  // direct-Claude cell needs edit tools
    return agent(cellPrompt(c), opts)
  })
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
    repo ? `Work inside the repo: start every Bash command with cd ${repo} (each Bash call is a fresh shell). The dispatch CLI is on PATH, or at ~/.claude/profile-system/bin/dispatch.` : ``,
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

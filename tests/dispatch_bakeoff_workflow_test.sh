#!/usr/bin/env bash
# Static lint of the bake-off Workflow script. The .js is harness-run JavaScript, not
# bash-testable (see the plan's test-strategy note) — so we assert its CONTRACT by grep:
# pure-literal meta, plain JS, Workflow-safe (no Date.now/Math.random), the right dispatch
# verbs, structured verdicts, and the E9 invariant (LANDS NOTHING).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
JS="$PS_REPO_ROOT/workflows/dispatch-bakeoff.js"

assert_file "$JS" "bake-off workflow script exists"
body="$(cat "$JS" 2>/dev/null || true)"

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

# --- claude-local contestant (Phase B): claude-on-qwen via bin/claude-run cell ---
assert_contains "$body" "claude-local"      "default contestant claude-local"
assert_contains "$body" "qwen3-coder-30b"   "claude-local contestant uses qwen3-coder-30b (ADR-0003)"
assert_contains "$body" "bin/claude-run cell" "cell prompt drives the claude-run cell delegate"

# --- E9: the workflow LANDS NOTHING; the orchestrator lands one ---
assert_contains "$body" "LANDS NOTHING" "carries the E9 sentinel"
assert_contains "$body" "NEVER LAND" "contestant prompt forbids landing"
assert_contains "$body" "args.task" "reads the task from args"
assert_contains "$body" "JSON.parse" "normalizes JSON-string args (scriptPath delivers args stringified)"

ps_report

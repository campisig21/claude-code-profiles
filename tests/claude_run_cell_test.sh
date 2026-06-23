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

# commit-failure path: the worker changed files but `git commit` is REJECTED (pre-commit
# hook) — the cell must NOT silently swallow it (work would be lost): warn + return nonzero.
id3="$( cd "$ro" && CODEX_DISPATCH_NOW=20260622T122000Z bash "$DISPATCH" begin add-cell3 --label qwen-local )"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  wt3="$(d_sc_get "$id3" '.worktree')"
  hd="$(cd "$wt3" && git rev-parse --git-path hooks)"
  mkdir -p "$hd"; printf '#!/bin/sh\nexit 1\n' > "$hd/pre-commit"; chmod +x "$hd/pre-commit" )
err3="$( cd "$ro" && CLAUDE_BIN="$fakecell" bash "$CLI" cell "$id3" "z" 2>&1 >/dev/null )"; rc4=$?
assert_contains "$err3" "commit failed" "cell warns when the commit is rejected (work not silently lost)"
assert_eq "$rc4" "1" "cell returns nonzero when the worker succeeded but the commit failed"

ps_teardown_sandbox
ps_report; exit $?

# Subsystem B — Self-Improvement Learning — Implementation Plan

> **For agentic workers:** This plan is implemented via the project's **Claude-plans / codex-implements** process. Each task is a self-contained, independently-verifiable unit suitable for `/codex-implement` dispatch (`codex_dispatch.sh dispatch --verify checks --check 'bash tests/run.sh' …`), Claude-gated landing. Steps use checkbox (`- [ ]`) syntax. Tasks are ordered so each leaves `tests/run.sh` green.

**Goal:** Build subsystem B (B.0 core curation daemon + B.1 skill performance + B.2 codex-execution learning feed) — a launchd-driven, headless-Sonnet curator that grows and prunes each profile's learned skills and memories autonomously, reversibly, and transparently.

**Architecture:** A lean Python daemon (`bin/curator.py`) iterates all profiles; per profile it acquires a `flock`, debounces on recent activity, drains a candidate queue (`/learn` flags + codex-run logs), bumps per-skill usage stats, and makes **one** batched `claude -p --model sonnet` call that returns a validated decision list. The daemon applies decisions mechanically — create/update/merge/prune — under a writable-path allowlist, archiving (never deleting) anything it supersedes, then regenerates `curator/INDEX.md`, updates `MEMORY.md`, records metrics, and emits a wakeup notification. Codex dispatch logs (newly persisted by a small C change) feed the same loop with backend-aware asymmetry so a weaker local model can't prune good skills or codify workarounds.

**Tech Stack:** Python 3 (stdlib only — `json`, `fcntl`, `pathlib`, `subprocess`, `datetime`), bash hooks/CLI, jq, launchd. Tests: the repo's dependency-free bash harness (`tests/lib.sh`, `tests/run.sh`), sandbox-isolated, with a fake `claude` binary injected via `CURATOR_CLAUDE_BIN`.

**Spec:** `docs/specs/2026-06-01-subsystem-b-learning-design.md` (sections referenced as §N below).

---

## File structure (created / modified)

| File | New/Mod | Responsibility |
|---|---|---|
| `lib/dispatch.sh` | Mod | C change: persist codex `--json` stream to `<sidecar>/<id>.codexlog.jsonl` (§5.9). |
| `codex_dispatch.sh` | Mod | On `land`, drop a `codex_run` candidate into the active profile's inbox (§5.9). |
| `hooks/learn-capture.sh` | Rewrite | Stop hook → `sessions.jsonl` line + `last_activity` stamp; no inbox breadcrumb (§5.4). |
| `bin/learn-flag` | New | Validates + atomically writes a `/learn` candidate into the active inbox (§5.3). |
| `skills/learn/SKILL.md` | Rewrite | Real `/learn` flag skill; instructs the session to call `bin/learn-flag` (§5.3). |
| `lib/curator_paths.py` | New | Python path/profile helpers mirroring `lib/paths.sh` (profile iteration, curator dirs). |
| `bin/curator.py` | New | The daemon: gather → synthesize → apply → record, per profile (§5.5). |
| `bin/curator` | New | Thin bash CLI wrapper backing `/curator` (status/log/stats/pending/restore/pause/resume/run) (§5.11). |
| `commands/curator.md` | New | `/curator` operator command (§5.11). |
| `hooks/profile-wakeup.sh` | Mod | Add the `CURATOR UPDATE` block from `notifications/`, then move them to `shown/` (§5.11). |
| `templates/persona.md` | Mod | Seed the static `@curator/INDEX.md` import line (§5.10). |
| `templates/curator.plist` | New | launchd job template (§5.12). |
| `install.sh` | Mod | Install the launchd plist (idempotent); ensure default profile has the INDEX import (§5.12). |
| `lib/jsonutil.sh` | Mod | Extend `js_init_curator_state` with the new metric fields (§5.7). |
| `tests/*` | New/Mod | One `*_test.sh` per behavior (listed per task); all run by `tests/run.sh`. |

**Conventions to follow (from the existing repo):**
- Bash libs are **sourced**, scripts `set -euo pipefail`; tests are pure bash via `tests/lib.sh` (`assert_eq`, `assert_file`, `assert_symlink`, `assert_contains`, `ps_setup_sandbox`, `ps_report`) and registered by adding the filename to `tests/run.sh`.
- Test sandbox root override: `CC_PROFILE_ROOT`. Binary-injection seams already used: `CCP_CLAUDE_BIN` (ccp), `CODEX_DISPATCH_CODEX_BIN` (fake codex). B adds `CURATOR_CLAUDE_BIN`.
- All JSON via `jq`; atomic writes via tmp+`mv`.
- Date/UTC: bash uses `date -u +%Y%m%dT%H%M%SZ`; Python uses `datetime.now(timezone.utc)`.

---

## Task 1 — C change: persist the codex exec stream (B.2 prereq)

**Files:**
- Modify: `lib/dispatch.sh` (`d_codex_exec`, `d_codex_resume`)
- Test: `tests/dispatch_codexlog_test.sh` (new; add to `tests/run.sh`)

Today `d_codex_exec` writes the stream to a `mktemp` file, greps the id, then `rm -f`s it. We persist it to the sidecar dir instead. The function gains a **dispatch-id** parameter so it knows the log path; callers already have the id.

- [ ] **Step 1: Write the failing test** — `tests/dispatch_codexlog_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/paths.sh"
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch.sh"

# fake codex that emits a thread.started line + a tool event, to a real git repo worktree
repo="$PS_SANDBOX/repo"; mkdir -p "$repo"; ( cd "$repo" && git init -q && git commit -q --allow-empty -m init )
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"th-123"}'
echo '{"type":"item.completed","item":{"type":"command_execution","command":"pytest"}}'
EOF
chmod +x "$fakebin/codex"
export CODEX_DISPATCH_CODEX_BIN="$fakebin/codex"

lastmsg="$PS_SANDBOX/last.txt"
sid="$(d_codex_exec "abc123" "$repo" "$lastmsg" "do a thing")"
log="$(d_sidecar_dir)/abc123.codexlog.jsonl"

assert_eq "$sid" "th-123" "session/thread id still parsed"
assert_file "$log" "codex log persisted to sidecar"
assert_contains "$(cat "$log")" "command_execution" "log retains tool events"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/dispatch_codexlog_test.sh`
Expected: FAIL — `d_codex_exec` currently takes 3 args (no id) and deletes the stream; `assert_file` on the log fails.

- [ ] **Step 3: Implement** — edit `lib/dispatch.sh`

Change the signature and persistence. New `d_codex_exec`:

```sh
# d_codex_exec <id> <worktree> <lastmsg_file> <prompt>  -> echoes captured session id
# Persists the codex --json stream to <sidecar>/<id>.codexlog.jsonl (B.2 feed) instead of discarding.
d_codex_exec() {
  local id="$1" wt="$2" lastmsg="$3" prompt="$4"
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}" log
  log="$(d_sidecar_dir)/$id.codexlog.jsonl"
  mkdir -p "$(d_sidecar_dir)" 2>/dev/null || true
  "$bin" exec --dangerously-bypass-approvals-and-sandbox --json \
         -C "$wt" -o "$lastmsg" "$prompt" > "$log" 2>&1 || true
  d_codex_session_id "$log"
}
```

New `d_codex_resume` (append to the same log so resume context is captured):

```sh
# d_codex_resume <id> <worktree> <session_id|""> <prompt>
d_codex_resume() {
  local id="$1" wt="$2" session="$3" prompt="$4"
  local bin="${CODEX_DISPATCH_CODEX_BIN:-codex}" log
  log="$(d_sidecar_dir)/$id.codexlog.jsonl"
  mkdir -p "$(d_sidecar_dir)" 2>/dev/null || true
  if [ -n "$session" ]; then
    "$bin" exec resume "$session" --dangerously-bypass-approvals-and-sandbox \
           -C "$wt" "$prompt" >> "$log" 2>&1 || true
  else
    "$bin" exec resume --last --dangerously-bypass-approvals-and-sandbox \
           -C "$wt" "$prompt" >> "$log" 2>&1 || true
  fi
}
```

- [ ] **Step 4: Update the two call sites in `codex_dispatch.sh`** to pass the id as the first arg.

Find the calls (`grep -n 'd_codex_exec\|d_codex_resume' codex_dispatch.sh`) and prepend `"$id"`:
`d_codex_exec "$id" "$wt" "$lastmsg" "$prompt"` and `d_codex_resume "$id" "$wt" "$session" "$prompt"`.

- [ ] **Step 5: Run the new test + the full suite**

Run: `bash tests/dispatch_codexlog_test.sh && bash tests/run.sh`
Expected: new test PASS; **all existing C/A tests still PASS** (session-id parse unchanged; only persistence added). Add `dispatch_codexlog_test.sh` to `tests/run.sh`.

- [ ] **Step 6: Commit**

```bash
git add lib/dispatch.sh codex_dispatch.sh tests/dispatch_codexlog_test.sh tests/run.sh
git commit -m "feat(C): persist codex exec stream to sidecar log (B.2 feed prereq)"
```

---

## Task 2 — Stop hook rewrite: session index + idle stamp (§5.4)

**Files:**
- Rewrite: `hooks/learn-capture.sh`
- Test: `tests/learn_capture_test.sh` (update existing)

- [ ] **Step 1: Update the test** — replace the body-assertion in `tests/learn_capture_test.sh` with the new contract.

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
HOOK="$PS_REPO_ROOT/hooks/learn-capture.sh"

# default profile: Stop hook indexes the session and stamps activity; writes NO inbox candidate.
mkdir -p "$CC_PROFILE_ROOT/curator/inbox"
echo '{"session_id":"sess-1","transcript_path":"/tmp/t.jsonl","cwd":"/work/acme"}' \
  | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$HOOK" >/dev/null 2>&1

idx="$CC_PROFILE_ROOT/curator/sessions.jsonl"
assert_file "$idx" "sessions.jsonl written"
assert_contains "$(cat "$idx")" "sess-1" "session id indexed"
assert_contains "$(cat "$idx")" "/tmp/t.jsonl" "transcript path indexed"
assert_file "$CC_PROFILE_ROOT/curator/last_activity" "last_activity stamped"
inbox_n="$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')"
assert_eq "$inbox_n" "0" "no inbox breadcrumb written"

# always exits 0 even on garbage stdin
echo 'not json' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$HOOK" >/dev/null 2>&1
assert_eq "$?" "0" "never fails the session"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it, verify it fails** — Run: `bash tests/learn_capture_test.sh`; Expected: FAIL (old hook writes an inbox file; `sessions.jsonl` absent).

- [ ] **Step 3: Implement** — replace `hooks/learn-capture.sh` body:

```bash
#!/usr/bin/env bash
# Stop hook (subsystem B). Indexes the finished session for the curator's usage
# scan and stamps activity for idle-debounce. Writes NO learning candidate
# (those come from /learn and codex runs). MUST never fail the session: exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/paths.sh"

input="$(cat 2>/dev/null || true)"
name="$(resolve_active_profile)"
cdir="$(profile_dir "$name")/curator"
mkdir -p "$cdir" 2>/dev/null || exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
tp="$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo "")"
ts="$(date -u +%Y%m%dT%H%M%SZ)"

jq -nc --arg sid "$sid" --arg tp "$tp" --arg cwd "$cwd" --arg ts "$ts" \
   '{session_id:$sid, transcript_path:$tp, cwd:$cwd, ended_at:$ts}' \
   >> "$cdir/sessions.jsonl" 2>/dev/null || true
date +%s > "$cdir/last_activity" 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Run test + suite** — `bash tests/learn_capture_test.sh && bash tests/run.sh`; Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hooks/learn-capture.sh tests/learn_capture_test.sh
git commit -m "feat(B): repurpose Stop hook to session-index + idle stamp (no breadcrumb)"
```

---

## Task 3 — `/learn` flag: `bin/learn-flag` + skill (§5.3)

**Files:**
- Create: `bin/learn-flag`, `tests/learn_flag_test.sh` (add to `run.sh`)
- Rewrite: `skills/learn/SKILL.md`

- [ ] **Step 1: Write the failing test** — `tests/learn_flag_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
FLAG="$PS_REPO_ROOT/bin/learn-flag"

out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$FLAG" \
        --type skill --title "ripgrep over grep" \
        --body "Prefer rg for code search" --context "came up debugging" 2>&1)"; rc=$?
assert_eq "$rc" "0" "learn-flag succeeds"
f="$(find "$CC_PROFILE_ROOT/curator/inbox" -type f -name '*.json' | head -1)"
assert_file "$f" "candidate written to inbox"
assert_eq "$(jq -r '.kind' "$f")" "flag" "kind=flag"
assert_eq "$(jq -r '.type' "$f")" "skill" "type carried"
assert_eq "$(jq -r '.title' "$f")" "ripgrep over grep" "title carried"

# missing required field -> nonzero, nothing written
n0="$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$FLAG" --type skill --body x >/dev/null 2>&1; rc2=$?
n1="$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')"
assert_eq "$rc2" "1" "missing --title rejected"
assert_eq "$n0" "$n1" "rejected flag writes nothing"

# invalid type rejected
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$FLAG" --type bogus --title t --body b >/dev/null 2>&1
assert_eq "$?" "1" "invalid type rejected"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it, verify it fails** — Run: `bash tests/learn_flag_test.sh`; Expected: FAIL (no `bin/learn-flag`).

- [ ] **Step 3: Implement `bin/learn-flag`**

```bash
#!/usr/bin/env bash
# learn-flag — write a /learn candidate into the active profile's curator inbox.
# Usage: learn-flag --type skill|memory|auto --title T --body B [--context C]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/paths.sh"

type=""; title=""; body=""; context=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type) type="$2"; shift 2;;
    --title) title="$2"; shift 2;;
    --body) body="$2"; shift 2;;
    --context) context="$2"; shift 2;;
    *) echo "learn-flag: unknown arg: $1" >&2; exit 1;;
  esac
done
case "$type" in skill|memory|auto) :;; *) echo "learn-flag: --type must be skill|memory|auto" >&2; exit 1;; esac
[ -n "$title" ] || { echo "learn-flag: --title required" >&2; exit 1; }
[ -n "$body" ]  || { echo "learn-flag: --body required" >&2; exit 1; }

name="$(resolve_active_profile)"
inbox="$(profile_dir "$name")/curator/inbox"
mkdir -p "$inbox"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
rand="$$-${RANDOM}"
f="$inbox/${ts}-${rand}.json"
tmp="$(mktemp)"
jq -nc --arg ts "$ts" --arg prof "$name" --arg type "$type" \
       --arg title "$title" --arg body "$body" --arg ctx "$context" \
   '{kind:"flag", captured_at:$ts, profile:$prof, session_id:(env.CLAUDE_SESSION_ID // "unknown"),
     type:$type, title:$title, body:$body, context:$ctx}' > "$tmp"
mv "$tmp" "$f"
echo "learn-flag: queued $f"
```

- [ ] **Step 4: Rewrite `skills/learn/SKILL.md`**

```markdown
---
name: learn
description: Use when you (the main session) have learned something worth keeping — a reusable technique, a project fact, or a correction — and want the background curator to file it as a skill or memory. Flags a learning candidate; the curator validates, dedupes, and writes it.
---

# /learn — flag a learning candidate

When something in this session is worth remembering for future sessions, call the
helper below. You supply *what* was learned; the background curator (headless Sonnet)
decides how to file it (skill vs memory), dedupes against existing artifacts, and writes it.

Run:

```bash
~/.claude/profile-system/bin/learn-flag \
  --type auto \
  --title "<short title>" \
  --body "<the substance — the technique/fact/correction, in enough detail to act on>" \
  --context "<why/when it came up — helps write a good 'use-when'>"
```

- `--type`: `skill` (reusable how-to), `memory` (a fact about the user/project), or
  `auto` (let the curator decide — the usual choice).
- Keep `--body` self-contained; the curator has no access to this conversation.
- This only *queues* the candidate. It is filed on the next curator run and you'll see
  a `CURATOR UPDATE` note at a future session start.
```

- [ ] **Step 5: Run test + suite** — `bash tests/learn_flag_test.sh && bash tests/run.sh`; Expected: PASS. Add to `run.sh`.

- [ ] **Step 6: Commit**

```bash
git add bin/learn-flag skills/learn/SKILL.md tests/learn_flag_test.sh tests/run.sh
git commit -m "feat(B): /learn flag skill + bin/learn-flag inbox writer"
```

---

## Task 4 — Python helpers + daemon skeleton: gather/lock/debounce/apply/allowlist (§5.5, §6)

**Files:**
- Create: `lib/curator_paths.py`, `bin/curator.py`
- Modify: `lib/jsonutil.sh` (`js_init_curator_state` new fields)
- Test: `tests/curator_loop_test.sh` (add to `run.sh`)

This task builds the daemon's mechanical core with a **stubbed synthesis step** (reads decisions from a fake `claude`); Task 5 hardens the synthesis contract.

- [ ] **Step 1: Extend `js_init_curator_state` in `lib/jsonutil.sh`**

```sh
js_init_curator_state() {
  local path="$1"
  [ -f "$path" ] && return 0
  jq -n '{last_run_at:null, last_run_duration_seconds:null, last_run_summary:null,
          paused:false, run_count:0,
          accepted_total:0, rejected_total:0, pruned_total:0, merged_total:0, failures_total:0}' > "$path"
}
```
(Existing A test asserts `run_count==0`; the added fields don't break it. If an A test asserts exact object equality, update it to check fields individually.)

- [ ] **Step 2: Write `lib/curator_paths.py`** (mirrors `lib/paths.sh`)

```python
"""Path + profile helpers for the curator daemon. Honors CC_PROFILE_ROOT (tests)."""
import os
from pathlib import Path

def cc_root() -> Path:
    return Path(os.environ.get("CC_PROFILE_ROOT", str(Path.home() / ".claude")))

def profiles_dir() -> Path:
    return cc_root() / "profiles"

def profile_dir(name: str) -> Path:
    return cc_root() if name == "default" else profiles_dir() / name

def all_profiles() -> list[str]:
    names = ["default"]
    pd = profiles_dir()
    if pd.is_dir():
        for d in sorted(pd.iterdir()):
            if d.is_dir() and d.name != "_shared" and not d.name.startswith("."):
                names.append(d.name)
    return names

def curator_dir(name: str) -> Path:
    return profile_dir(name) / "curator"

# Writable-path allowlist (§6). Returns True iff `target` is under an allowed root.
def is_writable(name: str, target: Path) -> bool:
    p = profile_dir(name).resolve()
    t = target.resolve()
    allowed = [p / "skills", p / "curator"]
    # any projects/*/memory tree
    try:
        rel = t.relative_to(p)
        parts = rel.parts
        if len(parts) >= 3 and parts[0] == "projects" and parts[2] == "memory":
            return True
    except ValueError:
        return False
    return any(str(t).startswith(str(a.resolve()) + os.sep) or t == a for a in allowed)
```

- [ ] **Step 3: Write the failing test** — `tests/curator_loop_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"

# seed default profile curator + a flag candidate
mkdir -p "$CC_PROFILE_ROOT/curator/inbox" "$CC_PROFILE_ROOT/skills"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
echo '{"kind":"flag","type":"skill","title":"use rg","body":"prefer ripgrep","context":"search"}' \
  > "$CC_PROFILE_ROOT/curator/inbox/c1.json"
# make it look idle (last_activity far in the past)
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"

# fake claude: returns a single create decision
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"decisions":[{"action":"create","kind":"skill","name":"use-rg",
  "path":"skills/use-rg/SKILL.md","content":"# use rg\nPrefer ripgrep.","use_when":"searching code","reason":"flagged"}],
 "new_skill_candidates":[]}
JSON
EOF
chmod +x "$fakebin/claude"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" \
  CURATOR_IDLE_THRESHOLD_SECONDS=600 python3 "$CURATOR" run default >/dev/null 2>&1

assert_file "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md" "skill created"
assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')" "0" "inbox drained"
assert_eq "$(jq -r '.run_count' "$CC_PROFILE_ROOT/.curator_state")" "1" "run_count bumped"
assert_eq "$(jq -r '.accepted_total' "$CC_PROFILE_ROOT/.curator_state")" "1" "accepted metric"
nf="$(find "$CC_PROFILE_ROOT/curator/notifications" -type f -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$nf" "1" "notification emitted"

# allowlist: a decision targeting CLAUDE.md is rejected, not written
echo '{"kind":"flag","type":"memory","title":"x","body":"y","context":""}' \
  > "$CC_PROFILE_ROOT/curator/inbox/c2.json"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"decisions":[{"action":"create","kind":"memory","name":"evil","path":"CLAUDE.md","content":"HACKED","reason":"x"}],"new_skill_candidates":[]}'
EOF
before="$(cat "$CC_PROFILE_ROOT/CLAUDE.md" 2>/dev/null || echo MISSING)"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
after="$(cat "$CC_PROFILE_ROOT/CLAUDE.md" 2>/dev/null || echo MISSING)"
assert_eq "$before" "$after" "CLAUDE.md untouched (allowlist)"
assert_eq "$(jq -r '.rejected_total' "$CC_PROFILE_ROOT/.curator_state")" "1" "rejected metric bumped"

# lock contention: a held lock makes run skip
( exec 9>"$CC_PROFILE_ROOT/curator/.curator.lock"; flock 9
  echo '{"kind":"flag","type":"skill","title":"z","body":"z","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c3.json"
  CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
  assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f -name c3.json | wc -l | tr -d ' ')" "1" "skipped under lock (candidate retained)"
)

# paused profile is skipped
jq '.paused=true' "$CC_PROFILE_ROOT/.curator_state" > "$CC_PROFILE_ROOT/.cs.tmp" && mv "$CC_PROFILE_ROOT/.cs.tmp" "$CC_PROFILE_ROOT/.curator_state"
echo '{"kind":"flag","type":"skill","title":"p","body":"p","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c4.json"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f -name c4.json | wc -l | tr -d ' ')" "1" "skipped when paused"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 4: Run it, verify it fails** — Run: `bash tests/curator_loop_test.sh`; Expected: FAIL (no `bin/curator.py`).

- [ ] **Step 5: Implement `bin/curator.py`** (core; synthesis reads from `CURATOR_CLAUDE_BIN`)

```python
#!/usr/bin/env python3
"""Curator daemon (subsystem B). Lean orchestrator: gather -> synthesize -> apply -> record.
Intelligence lives in `claude -p`; this file only shuttles JSON and applies decisions."""
import os, sys, json, fcntl, subprocess, datetime
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import curator_paths as cp

IDLE = int(os.environ.get("CURATOR_IDLE_THRESHOLD_SECONDS", "600"))
CLAUDE = os.environ.get("CURATOR_CLAUDE_BIN", "claude")
MODEL = os.environ.get("CURATOR_MODEL", "sonnet")

def now_iso(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
def epoch(): return int(datetime.datetime.now(datetime.timezone.utc).timestamp())

def read_json(p, default=None):
    try: return json.loads(Path(p).read_text())
    except Exception: return default

def write_atomic(p: Path, text: str):
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(text); tmp.replace(p)

def state_path(name): return cp.profile_dir(name) / ".curator_state"
def load_state(name): return read_json(state_path(name), {}) or {}
def save_state(name, s): write_atomic(state_path(name), json.dumps(s, indent=2))

def log(name, msg):
    cdir = cp.curator_dir(name); cdir.mkdir(parents=True, exist_ok=True)
    with open(cdir / "curator.log", "a") as f: f.write(f"{now_iso()} {msg}\n")

def gather_candidates(name):
    inbox = cp.curator_dir(name) / "inbox"
    items = []
    if inbox.is_dir():
        for f in sorted(inbox.glob("*.json")):
            c = read_json(f)
            if c is not None: items.append((f, c))
    return items

def synthesize(name, candidates):
    """Call claude -p with candidates + digest; return validated decision dict or None on failure."""
    payload = {
        "candidates": [c for _, c in candidates],
        "existing_digest": skills_digest(name),
        "skill_stats": read_json(cp.curator_dir(name) / "skill-stats.json", {}) or {},
    }
    prompt = build_prompt(payload)  # defined in Task 5
    try:
        out = subprocess.run([CLAUDE, "-p", "--model", MODEL, prompt],
                             capture_output=True, text=True, timeout=300)
        if out.returncode != 0: return None
        return validate_decisions(json.loads(extract_json(out.stdout)))  # Task 5
    except Exception:
        return None

def skills_digest(name):
    sk = cp.profile_dir(name) / "skills"; out = []
    if sk.is_dir():
        for d in sorted(sk.iterdir()):
            f = d / "SKILL.md"
            if f.is_file(): out.append({"name": d.name, "head": f.read_text()[:200]})
    return out

def apply_decision(name, d, state, notif):
    action = d.get("action"); kind = d.get("kind")
    pdir = cp.profile_dir(name)
    if action in ("create", "update", "merge"):
        target = pdir / d["path"] if d.get("path") else default_path(name, kind, d.get("name", "unnamed"))
        if not cp.is_writable(name, target):
            state["rejected_total"] += 1; log(name, f"REJECT (allowlist): {target}"); return
        if action in ("update", "merge") or target.exists():
            archive(name, target)
        if action == "merge":
            for src in d.get("from", []):
                archive(name, src_path(name, kind, src))
        write_atomic(target, d["content"])
        state["accepted_total"] += 1
        notif["created" if action == "create" else "updated"].append(f"{kind}:{d.get('name')}")
        if action == "merge":
            notif["merged"].append({"into": d.get("into"), "from": d.get("from")})
            state["merged_total"] += 1
    elif action == "prune":
        target = src_path(name, kind, d["name"])
        if not cp.is_writable(name, target):
            state["rejected_total"] += 1; return
        if target.exists():
            archive(name, target); state["pruned_total"] += 1
            notif["pruned"].append(f"{kind}:{d.get('name')}")
    # "skip" -> nothing

def default_path(name, kind, nm):
    p = cp.profile_dir(name)
    return p / "skills" / nm / "SKILL.md" if kind == "skill" else p / "projects" / "_profile" / "memory" / f"{nm}.md"

def src_path(name, kind, nm):
    return default_path(name, kind, nm)

def archive(name, target: Path):
    target = Path(target)
    if not target.exists(): return
    dest = cp.curator_dir(name) / "archive" / f"{now_iso()}-{target.name}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    # copy file (or dir's SKILL.md parent) into archive, then remove from live tree
    if target.is_file():
        dest.write_bytes(target.read_bytes()); target.unlink()
    else:
        import shutil; shutil.move(str(target), str(dest))

def run_profile(name):
    cdir = cp.curator_dir(name); cdir.mkdir(parents=True, exist_ok=True)
    lock = open(cdir / ".curator.lock", "w")
    try:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError: log(name, "skip: lock held"); return
        state = load_state(name)
        if state.get("paused"): log(name, "skip: paused"); return
        la = read_json_text(cdir / "last_activity")
        if la is not None and (epoch() - la) < IDLE: log(name, "skip: recent activity"); return
        candidates = gather_candidates(name)
        # (codex-log gather + stats added in Tasks 6-7)
        if not candidates: return
        t0 = epoch()
        decisions = synthesize(name, candidates)
        if decisions is None:
            state["failures_total"] = state.get("failures_total", 0) + 1
            save_state(name, state); log(name, "synthesize failed; candidates retained"); return
        notif = {"run_at": now_iso(), "created": [], "updated": [], "pruned": [], "merged": []}
        for d in decisions.get("decisions", []):
            apply_decision(name, d, state, notif)
        # consume inbox files we processed
        for f, _ in candidates:
            try: f.unlink()
            except FileNotFoundError: pass
        regen_index(name)            # Task 8
        update_memory_index(name)    # Task 8
        state["run_count"] = state.get("run_count", 0) + 1
        state["last_run_at"] = now_iso()
        state["last_run_duration_seconds"] = epoch() - t0
        state["last_run_summary"] = summarize(notif)
        save_state(name, state)
        if any(notif[k] for k in ("created", "updated", "pruned", "merged")):
            write_atomic(cdir / "notifications" / f"{now_iso()}.json", json.dumps(notif, indent=2))
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN); lock.close()

def read_json_text(p):
    try: return int(Path(p).read_text().strip())
    except Exception: return None

def summarize(n):
    return f"{len(n['created'])} created, {len(n['updated'])} updated, {len(n['pruned'])} pruned, {len(n['merged'])} merged"

def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "run"
    if cmd == "run":
        targets = [args[1]] if len(args) > 1 else cp.all_profiles()
        for name in targets: run_profile(name)
    else:
        sys.stderr.write(f"curator.py: unknown command {cmd}\n"); sys.exit(2)

if __name__ == "__main__":
    main()
```

> **Note for the implementer:** `regen_index`, `update_memory_index`, `build_prompt`, `validate_decisions`, `extract_json` are referenced here and **defined in Tasks 5 and 8**. To keep `tests/run.sh` green at *this* task, add minimal stubs now: `def regen_index(n): pass`, `def update_memory_index(n): pass`, `def build_prompt(p): return json.dumps(p)`, `def extract_json(s): return s`, and `def validate_decisions(d): return d if isinstance(d, dict) and "decisions" in d else None`. Tasks 5 and 8 replace the stubs with real implementations and their own tests.

- [ ] **Step 6: Run test + suite** — `bash tests/curator_loop_test.sh && bash tests/run.sh`; Expected: PASS. Add `curator_loop_test.sh` to `run.sh`.

- [ ] **Step 7: Commit**

```bash
git add lib/curator_paths.py bin/curator.py lib/jsonutil.sh tests/curator_loop_test.sh tests/run.sh
git commit -m "feat(B.0): curator daemon core — gather/lock/debounce/apply/allowlist + reversible archive"
```

---

## Task 5 — Synthesis contract: prompt, JSON extraction, decision validation, backpressure (§5.5, §5.8, B6)

**Files:**
- Modify: `bin/curator.py` (`build_prompt`, `extract_json`, `validate_decisions`, backpressure in `synthesize`)
- Test: `tests/curator_synth_test.sh` (add to `run.sh`)

- [ ] **Step 1: Write the failing test** — `tests/curator_synth_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"

# claude wraps JSON in prose + a fence -> extract_json must recover it
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo "Sure! Here is the plan:"
echo '```json'
echo '{"decisions":[{"action":"skip","candidate_ref":"c1","reason":"dup"}],"new_skill_candidates":[]}'
echo '```'
EOF
chmod +x "$fakebin/claude"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
echo '{"kind":"flag","type":"auto","title":"t","body":"b","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c1.json"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f | wc -l | tr -d ' ')" "0" "fenced-JSON parsed; inbox drained on skip"

# malformed output -> candidates retained, failures bumped
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo "no json here at all"
EOF
echo '{"kind":"flag","type":"auto","title":"t2","body":"b2","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c2.json"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
assert_eq "$(find "$CC_PROFILE_ROOT/curator/inbox" -type f -name c2.json | wc -l | tr -d ' ')" "1" "malformed -> candidate retained"
assert_eq "$(jq -r '.failures_total' "$CC_PROFILE_ROOT/.curator_state")" "1" "failures_total bumped"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it, verify it fails** — Run: `bash tests/curator_synth_test.sh`; Expected: FAIL (stub `extract_json` returns raw prose; `json.loads` raises → whole run fails differently than asserted, or fenced JSON not recovered).

- [ ] **Step 3: Implement in `bin/curator.py`** (replace the Task-4 stubs)

```python
import re

MAX_INPUT_CHARS = 150_000  # ~ backpressure budget (B6); chars, not tokens, kept well under 200K window

def build_prompt(payload):
    return (
        "You are the curator for a Claude Code profile. Given learning CANDIDATES, a DIGEST of "
        "existing skills/memories, and SKILL_STATS, decide what to create/update/merge/prune/skip.\n"
        "Rules: dedupe against the digest; consolidate overlaps via 'merge'; only prune a skill the "
        "stats show is genuinely unused; never invent paths outside skills/ or projects/*/memory/.\n"
        "Respond with ONE JSON object matching this schema and nothing else:\n"
        '{"decisions":[{"action":"create|update|merge|prune|skip", ...}], '
        '"new_skill_candidates":[{"title":"","rationale":"","source_backend":"codex|local"}]}\n\n'
        "INPUT:\n" + json.dumps(payload)
    )

def extract_json(s):
    """Recover a JSON object from claude output: prefer a ```json fence, else the first {...} span."""
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", s, re.DOTALL)
    if m: return m.group(1)
    start = s.find("{")
    if start == -1: raise ValueError("no JSON object in output")
    depth = 0
    for i in range(start, len(s)):
        if s[i] == "{": depth += 1
        elif s[i] == "}":
            depth -= 1
            if depth == 0: return s[start:i+1]
    raise ValueError("unbalanced JSON in output")

VALID_ACTIONS = {"create", "update", "merge", "prune", "skip"}

def validate_decisions(d):
    if not isinstance(d, dict) or not isinstance(d.get("decisions"), list): return None
    for dec in d["decisions"]:
        if not isinstance(dec, dict) or dec.get("action") not in VALID_ACTIONS: return None
        if dec["action"] in ("create", "update", "merge") and not isinstance(dec.get("content"), str):
            return None
    d.setdefault("new_skill_candidates", [])
    return d
```

And add backpressure to `synthesize` — cap candidates by serialized size:

```python
def synthesize(name, candidates):
    selected, size = [], 0
    for item in candidates:
        s = len(json.dumps(item[1]))
        if selected and size + s > MAX_INPUT_CHARS: break   # leave the rest queued (B6)
        selected.append(item); size += s
    payload = {
        "candidates": [c for _, c in selected],
        "existing_digest": skills_digest(name),
        "skill_stats": read_json(cp.curator_dir(name) / "skill-stats.json", {}) or {},
    }
    prompt = build_prompt(payload)
    try:
        out = subprocess.run([CLAUDE, "-p", "--model", MODEL, prompt],
                             capture_output=True, text=True, timeout=300)
        if out.returncode != 0: return None
        return validate_decisions(json.loads(extract_json(out.stdout)))
    except Exception:
        return None
```

Update `run_profile` to consume only the **selected** candidates. Simplest: have `synthesize` return `(decisions, selected_files)`; delete only `selected_files` after apply. Adjust the call site accordingly.

- [ ] **Step 4: Run test + suite** — `bash tests/curator_synth_test.sh && bash tests/run.sh`; Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/curator.py tests/curator_synth_test.sh tests/run.sh
git commit -m "feat(B.0): synthesis contract — prompt, JSON extraction, validation, backpressure"
```

---

## Task 6 — Skill usage stats + prune nomination (§5.6)

**Files:**
- Modify: `bin/curator.py` (stats gather from transcripts; `runs_since_used`; prune nomination injected into payload)
- Test: `tests/curator_stats_test.sh` (add to `run.sh`)

- [ ] **Step 1: Write the failing test** — `tests/curator_stats_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox" "$CC_PROFILE_ROOT/skills/use-rg"
echo "# use rg" > "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"

# a fake transcript that invoked the Skill tool with skill "use-rg"
tdir="$PS_SANDBOX/transcripts"; mkdir -p "$tdir"
cat > "$tdir/t1.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"use-rg"}}]}}
EOF
echo "{\"session_id\":\"s1\",\"transcript_path\":\"$tdir/t1.jsonl\",\"cwd\":\"/w\",\"ended_at\":\"x\"}" \
  > "$CC_PROFILE_ROOT/curator/sessions.jsonl"

# fake claude: skip everything (we are only asserting stats here)
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"decisions":[],"new_skill_candidates":[]}'
EOF
chmod +x "$fakebin/claude"
# need a candidate so the run proceeds
echo '{"kind":"flag","type":"auto","title":"t","body":"b","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c1.json"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
stats="$CC_PROFILE_ROOT/curator/skill-stats.json"
assert_file "$stats" "skill-stats written"
assert_eq "$(jq -r '."use-rg".times_triggered' "$stats")" "1" "usage counted from transcript"
assert_eq "$(jq -r '."use-rg".runs_since_used' "$stats")" "0" "runs_since_used reset on use"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it, verify it fails** — Run: `bash tests/curator_stats_test.sh`; Expected: FAIL (no stats logic; `skill-stats.json` absent).

- [ ] **Step 3: Implement in `bin/curator.py`**

```python
def stats_path(name): return cp.curator_dir(name) / "skill-stats.json"

def list_skills(name):
    sk = cp.profile_dir(name) / "skills"
    return [d.name for d in sk.iterdir() if (d / "SKILL.md").is_file()] if sk.is_dir() else []

def new_session_transcripts(name):
    """Transcript paths from sessions.jsonl lines past the stored cursor."""
    sfile = cp.curator_dir(name) / "sessions.jsonl"
    cursors = read_json(cp.curator_dir(name) / ".cursors.json", {}) or {}
    offset = cursors.get("sessions_lines", 0)
    paths, lines = [], []
    if sfile.is_file():
        lines = sfile.read_text().splitlines()
        for ln in lines[offset:]:
            try:
                tp = json.loads(ln).get("transcript_path")
                if tp: paths.append(tp)
            except Exception: pass
    return paths, len(lines)

def skill_hits_in_transcript(path, skill_names):
    hits = {}
    try: text = Path(path).read_text()
    except Exception: return hits
    for ln in text.splitlines():
        try: obj = json.loads(ln)
        except Exception: continue
        for tu in _tool_uses(obj):
            if tu.get("name") == "Skill":
                s = (tu.get("input") or {}).get("skill")
                if s in skill_names: hits[s] = hits.get(s, 0) + 1
    return hits

def _tool_uses(obj):
    msg = obj.get("message") or {}
    content = msg.get("content") if isinstance(msg, dict) else None
    return [c for c in content if isinstance(c, dict) and c.get("type") == "tool_use"] if isinstance(content, list) else []

def update_stats(name, additive_hits=None):
    """Bump usage from new transcripts (+ optional additive hits from codex, Task 7). Advance cursor."""
    stats = read_json(stats_path(name), {}) or {}
    skills = list_skills(name)
    for s in skills:
        stats.setdefault(s, {"created_at": now_iso(), "source": "learned",
                             "times_triggered": 0, "last_used_at": None, "runs_since_used": 0})
    paths, line_count = new_session_transcripts(name)
    used_this_run = {}
    for p in paths:
        for s, n in skill_hits_in_transcript(p, set(skills)).items():
            used_this_run[s] = used_this_run.get(s, 0) + n
    for s, n in (additive_hits or {}).items():
        if s in stats: used_this_run[s] = used_this_run.get(s, 0) + n
    for s in skills:
        if used_this_run.get(s):
            stats[s]["times_triggered"] += used_this_run[s]
            stats[s]["last_used_at"] = now_iso()
            stats[s]["runs_since_used"] = 0
        else:
            stats[s]["runs_since_used"] += 1   # NOTE: local-codex non-use must NOT call this (Task 7)
    write_atomic(stats_path(name), json.dumps(stats, indent=2))
    cur = read_json(cp.curator_dir(name) / ".cursors.json", {}) or {}
    cur["sessions_lines"] = line_count
    write_atomic(cp.curator_dir(name) / ".cursors.json", json.dumps(cur, indent=2))
    return stats

PRUNE_THRESHOLD = int(os.environ.get("CURATOR_PRUNE_THRESHOLD", "100"))

def prune_nominations(stats):
    return [s for s, v in stats.items()
            if v.get("times_triggered", 0) == 0 and v.get("runs_since_used", 0) >= PRUNE_THRESHOLD]
```

Wire into `run_profile` **before** `synthesize`: `stats = update_stats(name)` and pass `stats` + `prune_nominations(stats)` into the payload (extend `synthesize`/`build_prompt` to accept and include `"prune_nominations"`).

- [ ] **Step 4: Run test + suite** — `bash tests/curator_stats_test.sh && bash tests/run.sh`; Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/curator.py tests/curator_stats_test.sh tests/run.sh
git commit -m "feat(B.1): skill usage stats from transcripts + prune nomination"
```

---

## Task 7 — Codex-execution feed + backend-aware asymmetry (§5.9)

**Files:**
- Modify: `codex_dispatch.sh` (`cmd_land` drops a `codex_run` candidate)
- Modify: `bin/curator.py` (gather codex logs; reduce to tool events; additive-only local stats; tag mined candidates)
- Test: `tests/curator_codexfeed_test.sh` (add to `run.sh`)

- [ ] **Step 1: Add the inbox drop to `codex_dispatch.sh:cmd_land`** — after the merge+worktree-removal succeeds (near the end of `cmd_land`, before the final success echo), append:

```sh
  # B.2 feed: queue this accepted dispatch's execution log for the curator.
  local _prof _inbox _log _task _backend _ts
  _prof="$(resolve_active_profile)"
  _inbox="$(profile_dir "$_prof")/curator/inbox"
  _log="$(d_sidecar_dir)/$id.codexlog.jsonl"
  _task="$(d_sc_get "$id" '.task')"
  _backend="$(d_sc_get "$id" '.backend')"; [ -n "$_backend" ] || _backend="codex"
  _ts="$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -f "$_log" ]; then
    mkdir -p "$_inbox"
    jq -nc --arg ts "$_ts" --arg prof "$_prof" --arg id "$id" --arg log "$_log" \
           --arg task "$_task" --arg be "$_backend" \
      '{kind:"codex_run", captured_at:$ts, profile:$prof, dispatch_id:$id,
        log_path:$log, task:$task, backend:$be}' \
      > "$_inbox/${_ts}-codex-${id}.json" 2>/dev/null || true
  fi
```
(`resolve_active_profile`/`profile_dir` come from the already-sourced `lib/paths.sh`; confirm it's sourced in `codex_dispatch.sh` — if not, `source` it near the top.)

- [ ] **Step 2: Write the failing test** — `tests/curator_codexfeed_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox" "$CC_PROFILE_ROOT/skills/use-rg"
echo "# use rg" > "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"

# a LOCAL-backend codex log that USED skill use-rg (additive: should bump times_triggered)
logdir="$PS_SANDBOX/logs"; mkdir -p "$logdir"
cat > "$logdir/d1.codexlog.jsonl" <<'EOF'
{"type":"item.completed","item":{"type":"tool_use","name":"Skill","input":{"skill":"use-rg"}}}
{"type":"item.completed","item":{"type":"command_execution","command":"rg foo"}}
EOF
cat > "$CC_PROFILE_ROOT/curator/inbox/codex1.json" <<EOF
{"kind":"codex_run","profile":"default","dispatch_id":"d1","log_path":"$logdir/d1.codexlog.jsonl","task":"x","backend":"local"}
EOF

# fake claude: echoes back nothing to create, but mines a candidate tagged local
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"decisions":[],"new_skill_candidates":[{"title":"do X","rationale":"repeated","source_backend":"local"}]}'
EOF
chmod +x "$fakebin/claude"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1
stats="$CC_PROFILE_ROOT/curator/skill-stats.json"
assert_eq "$(jq -r '."use-rg".times_triggered' "$stats")" "1" "local run additive: usage counted"

# A locally-mined candidate re-enters inbox tagged as a flag with local provenance
mined="$(grep -l 'do X' "$CC_PROFILE_ROOT"/curator/inbox/*.json 2>/dev/null | head -1)"
assert_file "$mined" "mined candidate re-queued"
assert_eq "$(jq -r '.kind' "$mined")" "flag" "mined candidate is a flag"
assert_eq "$(jq -r '.source_backend' "$mined")" "local" "mined candidate tagged local provenance"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 3: Run it, verify it fails** — Run: `bash tests/curator_codexfeed_test.sh`; Expected: FAIL (no codex-log gather/analysis).

- [ ] **Step 4: Implement in `bin/curator.py`**

```python
def gather_codex_logs(name):
    """Return [(inbox_file, candidate)] for unprocessed codex_run candidates."""
    return [(f, c) for f, c in gather_candidates(name) if c.get("kind") == "codex_run"]

def reduce_codex_log(log_path, skill_names):
    """Bounded extraction: skill/tool-use events only. Returns (skills_used:{name:n}, events:[...])."""
    used, events = {}, []
    try: text = Path(log_path).read_text()
    except Exception: return used, events
    for ln in text.splitlines()[:5000]:   # bound
        try: obj = json.loads(ln)
        except Exception: continue
        item = obj.get("item") or obj
        if item.get("type") == "tool_use" and item.get("name") == "Skill":
            s = (item.get("input") or {}).get("skill")
            if s in skill_names: used[s] = used.get(s, 0) + 1
        if item.get("type") in ("tool_use", "command_execution"):
            events.append({"name": item.get("name") or item.get("command"), "type": item.get("type")})
    return used, events[:200]
```

In `run_profile`, after splitting candidates into flags vs codex_runs:
1. For each `codex_run`: `used, events = reduce_codex_log(c["log_path"], set(list_skills(name)))`.
   - **Additive-only:** accumulate `used` into `additive_hits` passed to `update_stats(name, additive_hits=...)`. Local non-use contributes nothing (it never touches `runs_since_used`).
   - Include `events` (bounded) + `backend` in the synthesis payload so Sonnet can mine patterns.
2. Mark the codex log id in `.cursors.json` `processed_logs` and remove the inbox candidate.
3. After synthesis, for each `new_skill_candidates` entry: write a new `flag` candidate into the inbox via the same JSON shape `bin/learn-flag` uses, carrying `source_backend`. (Two-pass per MC5.)

```python
def requeue_mined(name, candidate):
    inbox = cp.curator_dir(name) / "inbox"
    f = inbox / f"{now_iso()}-mined-{abs(hash(candidate.get('title',''))) % 10000}.json"
    write_atomic(f, json.dumps({
        "kind": "flag", "captured_at": now_iso(), "profile": name, "session_id": "curator",
        "type": "skill", "title": candidate.get("title", "untitled"),
        "body": candidate.get("rationale", ""), "context": "mined from codex run",
        "source_backend": candidate.get("source_backend", "codex"),
    }, indent=2))
```

- [ ] **Step 5: Run test + suite** — `bash tests/curator_codexfeed_test.sh && bash tests/run.sh`; Expected: PASS. **Re-run the C land test** to confirm the inbox-drop didn't break landing.

- [ ] **Step 6: Commit**

```bash
git add codex_dispatch.sh bin/curator.py tests/curator_codexfeed_test.sh tests/run.sh
git commit -m "feat(B.2): codex-execution feed with backend-aware asymmetry (additive-only local)"
```

---

## Task 8 — INDEX.md regeneration + MEMORY roll-up + persona seed (§5.10)

**Files:**
- Modify: `bin/curator.py` (`regen_index`, `update_memory_index`)
- Modify: `templates/persona.md` (seed `@curator/INDEX.md`)
- Test: `tests/curator_index_test.sh` (add to `run.sh`)

- [ ] **Step 1: Write the failing test** — `tests/curator_index_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox" "$CC_PROFILE_ROOT/skills/use-rg" \
         "$CC_PROFILE_ROOT/projects/acme/memory"
printf -- '---\nname: use-rg\ndescription: use ripgrep for code search\n---\n' > "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md"
echo "# Memory Index" > "$CC_PROFILE_ROOT/projects/acme/memory/MEMORY.md"
printf '# default\n@curator/INDEX.md\n' > "$CC_PROFILE_ROOT/CLAUDE.md"
before="$(cat "$CC_PROFILE_ROOT/CLAUDE.md")"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
echo '#!/usr/bin/env bash'$'\n''echo '"'"'{"decisions":[],"new_skill_candidates":[]}'"'"'' > "$fakebin/claude"; chmod +x "$fakebin/claude"
echo '{"kind":"flag","type":"auto","title":"t","body":"b","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c1.json"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1

idx="$CC_PROFILE_ROOT/curator/INDEX.md"
assert_file "$idx" "INDEX.md generated"
assert_contains "$(cat "$idx")" "use-rg" "INDEX lists learned skill"
assert_contains "$(cat "$idx")" "ripgrep" "INDEX shows use-when from description"
assert_contains "$(cat "$idx")" "projects/acme/memory/MEMORY.md" "INDEX rolls up memory store"
assert_eq "$before" "$(cat "$CC_PROFILE_ROOT/CLAUDE.md")" "CLAUDE.md byte-unchanged"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it, verify it fails** — Run: `bash tests/curator_index_test.sh`; Expected: FAIL (stub `regen_index` is a no-op).

- [ ] **Step 3: Implement in `bin/curator.py`** (replace Task-4 stubs)

```python
def _skill_use_when(skill_md_path):
    try:
        for ln in Path(skill_md_path).read_text().splitlines():
            s = ln.strip()
            if s.startswith("description:"): return s.split(":", 1)[1].strip()
    except Exception: pass
    return ""

def regen_index(name):
    pdir = cp.profile_dir(name)
    lines = ["<!-- generated by curator; do not edit by hand -->", "", "## Learned skills"]
    sk = pdir / "skills"
    skills = sorted([d for d in sk.iterdir() if (d / "SKILL.md").is_file()]) if sk.is_dir() else []
    if skills:
        for d in skills:
            uw = _skill_use_when(d / "SKILL.md")
            lines.append(f"- {d.name} — {uw}  →  skills/{d.name}/")
    else:
        lines.append("- (none yet)")
    lines += ["", "## Memory"]
    proj = pdir / "projects"
    mem_indexes = sorted(proj.glob("*/memory/MEMORY.md")) if proj.is_dir() else []
    if mem_indexes:
        for m in mem_indexes:
            rel = m.relative_to(pdir)
            lines.append(f"- {m.parent.parent.name} → {rel}")
    else:
        lines.append("- (none yet)")
    write_atomic(cp.curator_dir(name) / "INDEX.md", "\n".join(lines) + "\n")

def update_memory_index(name):
    """Ensure each projects/<slug>/memory has a MEMORY.md header listing its memory files."""
    proj = cp.profile_dir(name) / "projects"
    if not proj.is_dir(): return
    for memdir in proj.glob("*/memory"):
        files = sorted(p.name for p in memdir.glob("*.md") if p.name != "MEMORY.md")
        idx = memdir / "MEMORY.md"
        header = "# Memory Index\n\n"
        body = "".join(f"- [{f}]({f})\n" for f in files) or "- (none)\n"
        # only (re)write if our files aren't all already referenced (cheap idempotence)
        existing = idx.read_text() if idx.is_file() else ""
        if not all(f in existing for f in files) or not existing.startswith("# Memory Index"):
            write_atomic(idx, header + body)
```

- [ ] **Step 4: Seed the import in `templates/persona.md`** — ensure the template's top contains:

```markdown
# {{PROFILE_NAME}} Profile

@curator/INDEX.md
```
(Keep whatever persona guidance already exists below; just guarantee the `@curator/INDEX.md` line is present near the top.)

- [ ] **Step 5: Run test + suite** — `bash tests/curator_index_test.sh && bash tests/run.sh`; Expected: PASS. (Profile-create tests still pass; the seeded import is additive.)

- [ ] **Step 6: Commit**

```bash
git add bin/curator.py templates/persona.md tests/curator_index_test.sh tests/run.sh
git commit -m "feat(B.0): regenerate curator INDEX.md + MEMORY roll-up; seed CLAUDE.md import"
```

---

## Task 9 — Wakeup notification block (§5.11 passive surface)

**Files:**
- Modify: `hooks/profile-wakeup.sh` (append `CURATOR UPDATE` from `notifications/`, move to `shown/`)
- Test: `tests/wakeup_test.sh` (extend existing)

- [ ] **Step 1: Extend `tests/wakeup_test.sh`** with a notification case

```bash
# --- curator notification surfaced + consumed ---
mkdir -p "$CC_PROFILE_ROOT/curator/notifications"
cat > "$CC_PROFILE_ROOT/curator/notifications/20260601T000000Z.json" <<'EOF'
{"run_at":"20260601T000000Z","created":["skill:use-rg"],"updated":[],"pruned":["skill:stale"],"merged":[],"summary":"1 created, 1 pruned"}
EOF
ctx="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/hooks/profile-wakeup.sh" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "CURATOR UPDATE" "curator update block present"
assert_contains "$ctx" "use-rg" "created skill shown"
assert_contains "$ctx" "stale" "pruned skill shown"
# consumed: moved to shown/
moved="$(find "$CC_PROFILE_ROOT/curator/notifications/shown" -type f -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$moved" "1" "notification moved to shown/"
remain="$(find "$CC_PROFILE_ROOT/curator/notifications" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$remain" "0" "notification consumed from queue"
```

- [ ] **Step 2: Run it, verify it fails** — Run: `bash tests/wakeup_test.sh`; Expected: FAIL (no block).

- [ ] **Step 3: Implement in `hooks/profile-wakeup.sh`** — before building the final `ctx`, gather notifications:

```sh
# --- curator notifications (B): summarize unseen, then mark shown ---
curator_block=""
notif_dir="$pdir/curator/notifications"
if [ -d "$notif_dir" ]; then
  shopt -s nullglob
  files=( "$notif_dir"/*.json )
  if [ "${#files[@]}" -gt 0 ]; then
    mkdir -p "$notif_dir/shown"
    lines=""
    for nf in "${files[@]}"; do
      sum="$(jq -r '.summary // ""' "$nf" 2>/dev/null)"
      created="$(jq -r '(.created // []) | join(", ")' "$nf" 2>/dev/null)"
      pruned="$(jq -r '(.pruned // []) | join(", ")' "$nf" 2>/dev/null)"
      [ -n "$created" ] && lines="$lines
  created: $created"
      [ -n "$pruned" ] && lines="$lines
  pruned:  $pruned"
      mv "$nf" "$notif_dir/shown/" 2>/dev/null || true
    done
    curator_block="===== CURATOR UPDATE =====${lines}
=========================="
  fi
fi
```
Then include `$curator_block` in the emitted `ctx` (append after the existing PROFILE WAKEUP block when non-empty).

- [ ] **Step 4: Run test + suite** — `bash tests/wakeup_test.sh && bash tests/run.sh`; Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hooks/profile-wakeup.sh tests/wakeup_test.sh
git commit -m "feat(B.0): surface curator notifications in SessionStart wakeup"
```

---

## Task 10 — `/curator` operator CLI (§5.11 active surface)

**Files:**
- Create: `bin/curator`, `commands/curator.md`
- Modify: `bin/curator.py` (add `status|log|stats|pending|restore|pause|resume` subcommands; `run` already exists)
- Test: `tests/curator_cli_test.sh` (add to `run.sh`)

- [ ] **Step 1: Write the failing test** — `tests/curator_cli_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CLI="$PS_REPO_ROOT/bin/curator"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/curator/archive/20260601T000000Z-old.md"
echo "archived body" > "$CC_PROFILE_ROOT/curator/archive/20260601T000000Z-old.md/old.md" 2>/dev/null || true

# pause / resume toggle .curator_state
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$CLI" pause default >/dev/null 2>&1
assert_eq "$(jq -r '.paused' "$CC_PROFILE_ROOT/.curator_state")" "true" "pause sets flag"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$CLI" resume default >/dev/null 2>&1
assert_eq "$(jq -r '.paused' "$CC_PROFILE_ROOT/.curator_state")" "false" "resume clears flag"

# status prints headline metrics
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$CLI" status default 2>&1)"
assert_contains "$out" "run_count" "status shows metrics"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it, verify it fails** — Run: `bash tests/curator_cli_test.sh`; Expected: FAIL (no `bin/curator`).

- [ ] **Step 3: Implement `bin/curator`** (thin bash wrapper → `curator.py`)

```bash
#!/usr/bin/env bash
# /curator CLI — thin wrapper over bin/curator.py
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/curator.py" "$@"
```

- [ ] **Step 4: Add subcommands to `bin/curator.py:main`**

```python
def cmd_status(name):
    s = load_state(name)
    pending = len(list((cp.curator_dir(name) / "inbox").glob("*.json"))) if (cp.curator_dir(name)/"inbox").is_dir() else 0
    print(json.dumps({"profile": name, "pending_candidates": pending, **s}, indent=2))

def cmd_pause(name, val):
    s = load_state(name); s["paused"] = val; save_state(name, s)
    print(f"curator: {name} {'paused' if val else 'resumed'}")

def cmd_stats(name):
    print(json.dumps(read_json(stats_path(name), {}) or {}, indent=2))

def cmd_pending(name):
    nd = cp.curator_dir(name) / "notifications"
    items = [read_json(f) for f in sorted(nd.glob("*.json"))] if nd.is_dir() else []
    print(json.dumps(items, indent=2))

def cmd_log(name, n):
    f = cp.curator_dir(name) / "curator.log"
    if f.is_file():
        for ln in f.read_text().splitlines()[-n:]: print(ln)

def cmd_restore(name, artifact):
    adir = cp.curator_dir(name) / "archive"
    matches = sorted(adir.glob(f"*-{artifact}*")) if adir.is_dir() else []
    if not matches: print(f"curator: no archived '{artifact}'", file=sys.stderr); sys.exit(1)
    src = matches[-1]
    print(f"curator: restore candidate {src} — re-file manually into skills/ or memory/ (reversible by design)")
```

Extend `main` to route `status|pause|resume|stats|pending|log|restore` (with an optional profile arg defaulting to the active profile via an env/`resolve` shim or `"default"`).

- [ ] **Step 5: Create `commands/curator.md`**

```markdown
---
name: curator
description: Inspect and control the background learning curator — status, recent decisions, skill usage stats, pending notifications, restore archived artifacts, pause/resume, or force a run.
---

# /curator — operator surface for subsystem B

Run the curator CLI:

```bash
~/.claude/profile-system/bin/curator <subcommand> [profile]
```

Subcommands:
- `status [profile]` — last run, pending candidates, paused state, metrics
- `log [-n N]` — recent run log lines
- `stats` — per-skill usage table (prune candidates have times_triggered 0 and high runs_since_used)
- `pending` — notifications not yet surfaced at a session start
- `restore <name>` — locate an archived skill/memory to recover
- `pause` | `resume [profile]` — toggle curation
- `run [profile]` — force a foreground curation run now

Profile defaults to `default` when omitted.
```

- [ ] **Step 6: Run test + suite** — `bash tests/curator_cli_test.sh && bash tests/run.sh`; Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add bin/curator bin/curator.py commands/curator.md tests/curator_cli_test.sh tests/run.sh
git commit -m "feat(B.0): /curator operator CLI (status/log/stats/pending/restore/pause/resume/run)"
```

---

## Task 11 — launchd install (§5.12)

**Files:**
- Create: `templates/curator.plist`
- Modify: `install.sh` (write plist when absent; ensure default CLAUDE.md has the import)
- Test: `tests/install_curator_test.sh` (add to `run.sh`)

- [ ] **Step 1: Create `templates/curator.plist`** (a template with `__CURATOR_PY__` / `__INTERVAL__` placeholders the installer substitutes)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.profile-system.curator</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>__CURATOR_PY__</string><string>run</string></array>
  <key>RunAtLoad</key><false/>
  <key>StartInterval</key><integer>__INTERVAL__</integer>
  <key>StandardErrorPath</key><string>__LOGDIR__/curator.launchd.log</string>
  <key>StandardOutPath</key><string>__LOGDIR__/curator.launchd.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the failing test** — `tests/install_curator_test.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
INSTALL="$PS_REPO_ROOT/install.sh"
export LAUNCH_AGENTS_DIR="$PS_SANDBOX/LaunchAgents"   # installer must honor this override in tests

CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS_DIR" \
  bash "$INSTALL" >/dev/null 2>&1
plist="$LAUNCH_AGENTS_DIR/com.profile-system.curator.plist"
assert_file "$plist" "curator plist installed"
assert_contains "$(cat "$plist")" "com.profile-system.curator" "plist label correct"
assert_contains "$(cat "$plist")" "curator.py" "plist points at daemon"

# idempotent + non-clobbering: hand-edit, re-run, edit preserved
echo "HANDEDIT" >> "$plist"
CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS_DIR" \
  bash "$INSTALL" >/dev/null 2>&1
assert_contains "$(cat "$plist")" "HANDEDIT" "existing plist left untouched"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 3: Run it, verify it fails** — Run: `bash tests/install_curator_test.sh`; Expected: FAIL (installer doesn't write a plist).

- [ ] **Step 4: Implement in `install.sh`** — add a step (after the existing skill/command symlink step), honoring a `LAUNCH_AGENTS_DIR` override for tests:

```sh
# 6. launchd curator job (subsystem B) — write only if absent (never clobber).
LA_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
mkdir -p "$LA_DIR"
plist="$LA_DIR/com.profile-system.curator.plist"
if [ ! -f "$plist" ]; then
  interval="${CURATOR_INTERVAL_SECONDS:-1800}"
  logdir="$ROOT"
  sed -e "s#__CURATOR_PY__#$SRC/bin/curator.py#g" \
      -e "s#__INTERVAL__#$interval#g" \
      -e "s#__LOGDIR__#$logdir#g" \
      "$SHARED/templates/curator.plist" > "$plist"
  echo "  Installed launchd curator job -> $plist"
  echo "  Load it with:  launchctl load $plist"
else
  echo "  launchd curator job exists; leaving untouched: $plist"
fi
```

- [ ] **Step 5: Run test + suite** — `bash tests/install_curator_test.sh && bash tests/run.sh`; Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add templates/curator.plist install.sh tests/install_curator_test.sh tests/run.sh
git commit -m "feat(B.0): install launchd curator job (idempotent, non-clobbering)"
```

---

## Task 12 — e2e wiring test + manual smoke checklist

**Files:**
- Create: `tests/curator_e2e_test.sh` (add to `run.sh`), `docs/smoke/2026-06-01-subsystem-b-smoke.md`

- [ ] **Step 1: Write `tests/curator_e2e_test.sh`** — full path from `/learn` → run → INDEX → wakeup, in one sandbox.

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/skills"; printf '# default\n@curator/INDEX.md\n' > "$CC_PROFILE_ROOT/CLAUDE.md"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity" 2>/dev/null || { mkdir -p "$CC_PROFILE_ROOT/curator"; echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"; }

# 1. flag via bin/learn-flag
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/bin/learn-flag" \
  --type skill --title "use rg" --body "prefer ripgrep" --context "search" >/dev/null 2>&1

# 2. run with a fake claude that creates the skill
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"decisions":[{"action":"create","kind":"skill","name":"use-rg","path":"skills/use-rg/SKILL.md","content":"---\nname: use-rg\ndescription: use ripgrep\n---\n# use rg","use_when":"searching","reason":"flagged"}],"new_skill_candidates":[]}'
EOF
chmod +x "$fakebin/claude"
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$PS_REPO_ROOT/bin/curator.py" run default >/dev/null 2>&1

# 3. assert end-state
assert_file "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md" "skill filed"
assert_contains "$(cat "$CC_PROFILE_ROOT/curator/INDEX.md")" "use-rg" "INDEX updated"
ctx="$(echo '{}' | CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$PS_REPO_ROOT/hooks/profile-wakeup.sh" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ctx" "CURATOR UPDATE" "wakeup shows the new skill"

ps_teardown_sandbox
ps_report; exit $?
```

- [ ] **Step 2: Run it + full suite** — `bash tests/curator_e2e_test.sh && bash tests/run.sh`; Expected: PASS, **20+/all green**.

- [ ] **Step 3: Write `docs/smoke/2026-06-01-subsystem-b-smoke.md`** — manual checklist for the real path:

```markdown
# Subsystem B — manual smoke checklist

The suite uses a **fake `claude`**, proving orchestration, not real Sonnet curation
quality or real launchd timing. Run this once against the REAL `claude -p` and launchd.

- [ ] `bin/learn-flag --type auto --title … --body …` → a candidate appears in
      `<active profile>/curator/inbox/`.
- [ ] `bin/curator run default` with the real `claude` (`CURATOR_CLAUDE_BIN` unset) →
      drains the inbox, files a real skill or memory, regenerates `curator/INDEX.md`,
      writes a `notifications/` entry, bumps `.curator_state`.
- [ ] Start a new session → the `CURATOR UPDATE` block lists what changed; the entry
      moves to `notifications/shown/`; `@curator/INDEX.md` shows the new skill.
- [ ] Dispatch + `land` a codex task → a `codex_run` candidate lands in the inbox; next
      curator run bumps `skill-stats.json` for any skill codex used and may mine a
      `new_skill_candidate` (tagged `source_backend` for local runs).
- [ ] Force a prune: set a learned skill's `runs_since_used` past 100 in `skill-stats.json`,
      run → it is **archived** (not deleted) under `curator/archive/`, with a notification.
- [ ] `bin/curator restore <name>` locates the archived artifact.
- [ ] `launchctl load ~/Library/LaunchAgents/com.profile-system.curator.plist` → after the
      interval (or `launchctl start com.profile-system.curator`), a run happens unattended.
- [ ] `bin/curator pause` → a run is skipped; `resume` re-enables.

## Notes
- The daemon only writes agent-created artifacts (skills/, projects/*/memory/, curator/);
  confirm `CLAUDE.md`, `settings.json`, and the persona are untouched after a run.
- Backend asymmetry: a `--backend local` dispatch's non-use of a skill must NOT advance its
  `runs_since_used`; verify on a local-backed run.
```

- [ ] **Step 4: Commit**

```bash
git add tests/curator_e2e_test.sh tests/run.sh docs/smoke/2026-06-01-subsystem-b-smoke.md
git commit -m "test(B): e2e wiring test + manual smoke checklist"
```

---

## Self-review notes (plan author)

- **Spec coverage:** B.0 daemon (T4–T5, T9–T11) · `/learn` (T3) · Stop-hook repurpose (T2) · B.1 stats+prune (T6) · B.2 codex feed + C log change + backend asymmetry (T1, T7) · INDEX/MEMORY/CLAUDE.md import (T8) · operator surface passive+active (T9, T10) · launchd (T11) · allowlist invariant (T4) · metrics (T4) · e2e+smoke (T12). All §-sections map to a task.
- **Cross-task signatures pinned:** `d_codex_exec(id, wt, lastmsg, prompt)` / `d_codex_resume(id, wt, session, prompt)` (T1, used T7); `curator_paths.is_writable/profile_dir/all_profiles/curator_dir` (T4, used everywhere); `update_stats(name, additive_hits=None)` (T6, called additive in T7); `regen_index`/`update_memory_index`/`build_prompt`/`extract_json`/`validate_decisions` stubbed in T4, implemented T5/T8; decision schema (§5.8) is the contract between the fake `claude` in tests and `apply_decision`.
- **Known follow-ups (out of scope, by design):** B.3 skill-sharing Claude↔codex; B.4 local-Qwen curation routing.

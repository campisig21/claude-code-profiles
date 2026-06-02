#!/usr/bin/env python3
"""Curator daemon (subsystem B). Lean orchestrator: gather -> synthesize -> apply -> record.
Intelligence lives in `claude -p`; this file only shuttles JSON and applies decisions."""
import os, sys, json, fcntl, subprocess, datetime, re
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import curator_paths as cp

IDLE = int(os.environ.get("CURATOR_IDLE_THRESHOLD_SECONDS", "600"))
CLAUDE = os.environ.get("CURATOR_CLAUDE_BIN", "claude")
MODEL = os.environ.get("CURATOR_MODEL", "sonnet")
MAX_INPUT_CHARS = 150_000  # backpressure budget (chars, well under the model window)

def now_iso(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
def epoch(): return int(datetime.datetime.now(datetime.timezone.utc).timestamp())

def read_json(p, default=None):
    try: return json.loads(Path(p).read_text())
    except Exception: return default

def write_atomic(p, text):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(text); tmp.replace(p)

def state_path(name): return cp.profile_dir(name) / ".curator_state"
def load_state(name): return read_json(state_path(name), {}) or {}
def save_state(name, s): write_atomic(state_path(name), json.dumps(s, indent=2))

def log(name, msg):
    cdir = cp.curator_dir(name); cdir.mkdir(parents=True, exist_ok=True)
    with open(cdir / "curator.log", "a") as f: f.write(f"{now_iso()} {msg}\n")

def gather_candidates(name):
    inbox = cp.curator_dir(name) / "inbox"; items = []
    if inbox.is_dir():
        for f in sorted(inbox.glob("*.json")):
            c = read_json(f)
            if c is not None: items.append((f, c))
    return items

def skills_digest(name):
    sk = cp.profile_dir(name) / "skills"; out = []
    if sk.is_dir():
        for d in sorted(sk.iterdir()):
            f = d / "SKILL.md"
            if f.is_file(): out.append({"name": d.name, "head": f.read_text()[:200]})
    return out

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

def stats_path(name): return cp.curator_dir(name) / "skill-stats.json"

def list_skills(name):
    sk = cp.profile_dir(name) / "skills"
    return [d.name for d in sk.iterdir() if (d / "SKILL.md").is_file()] if sk.is_dir() else []

def new_session_transcripts(name):
    """Transcript paths from sessions.jsonl lines past the stored cursor; returns (paths, total_lines)."""
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

def _tool_uses(obj):
    msg = obj.get("message") or {}
    content = msg.get("content") if isinstance(msg, dict) else None
    return [c for c in content if isinstance(c, dict) and c.get("type") == "tool_use"] if isinstance(content, list) else []

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

def update_stats(name, additive_hits=None):
    """Bump usage from new transcripts (+ optional additive hits). Advance the sessions cursor."""
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
            stats[s]["runs_since_used"] += 1
    write_atomic(stats_path(name), json.dumps(stats, indent=2))
    cur = read_json(cp.curator_dir(name) / ".cursors.json", {}) or {}
    cur["sessions_lines"] = line_count
    write_atomic(cp.curator_dir(name) / ".cursors.json", json.dumps(cur, indent=2))
    return stats

PRUNE_THRESHOLD = int(os.environ.get("CURATOR_PRUNE_THRESHOLD", "100"))

def prune_nominations(stats):
    return [s for s, v in stats.items()
            if v.get("times_triggered", 0) == 0 and v.get("runs_since_used", 0) >= PRUNE_THRESHOLD]

def synthesize(name, candidates, prune_noms=None, codex_events=None):
    selected, size = [], 0
    for item in candidates:
        s = len(json.dumps(item[1]))
        if selected and size + s > MAX_INPUT_CHARS: break
        selected.append(item); size += s
    payload = {
        "candidates": [c for _, c in selected],
        "existing_digest": skills_digest(name),
        "skill_stats": read_json(cp.curator_dir(name) / "skill-stats.json", {}) or {},
        "prune_nominations": prune_noms or [],
        "codex_events": codex_events or [],
    }
    prompt = build_prompt(payload)
    selected_files = [f for f, _ in selected]
    try:
        out = subprocess.run([CLAUDE, "-p", "--model", MODEL, prompt],
                             capture_output=True, text=True, timeout=300)
        if out.returncode != 0: return None, []
        return validate_decisions(json.loads(extract_json(out.stdout))), selected_files
    except Exception:
        return None, []

def reduce_codex_log(log_path, skill_names):
    """Bounded extraction: skill/tool-use events only. Returns (skills_used:{name:n}, events:[...])."""
    used, events = {}, []
    try: text = Path(log_path).read_text()
    except Exception: return used, events
    for ln in text.splitlines()[:5000]:
        try: obj = json.loads(ln)
        except Exception: continue
        item = obj.get("item") or obj
        if item.get("type") == "tool_use" and item.get("name") == "Skill":
            s = (item.get("input") or {}).get("skill")
            if s in skill_names: used[s] = used.get(s, 0) + 1
        if item.get("type") in ("tool_use", "command_execution"):
            events.append({"name": item.get("name") or item.get("command"), "type": item.get("type")})
    return used, events[:200]

def requeue_mined(name, candidate):
    inbox = cp.curator_dir(name) / "inbox"
    f = inbox / f"{now_iso()}-mined-{abs(hash(candidate.get('title',''))) % 10000}.json"
    write_atomic(f, json.dumps({
        "kind": "flag", "captured_at": now_iso(), "profile": name, "session_id": "curator",
        "type": "skill", "title": candidate.get("title", "untitled"),
        "body": candidate.get("rationale", ""), "context": "mined from codex run",
        "source_backend": candidate.get("source_backend", "codex"),
    }, indent=2))

def default_path(name, kind, nm):
    p = cp.profile_dir(name)
    return p / "skills" / nm / "SKILL.md" if kind == "skill" else p / "projects" / "_profile" / "memory" / f"{nm}.md"

def src_path(name, kind, nm): return default_path(name, kind, nm)

def archive(name, target):
    target = Path(target)
    if not target.exists(): return
    dest = cp.curator_dir(name) / "archive" / f"{now_iso()}-{target.name}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file():
        dest.write_bytes(target.read_bytes()); target.unlink()
    else:
        import shutil; shutil.move(str(target), str(dest))

def apply_decision(name, d, state, notif):
    action = d.get("action"); kind = d.get("kind")
    pdir = cp.profile_dir(name)
    if action in ("create", "update", "merge"):
        target = pdir / d["path"] if d.get("path") else default_path(name, kind, d.get("name", "unnamed"))
        if not cp.is_writable(name, target):
            state["rejected_total"] += 1; log(name, f"REJECT (allowlist): {target}"); return
        if action in ("update", "merge") or Path(target).exists():
            archive(name, target)
        if action == "merge":
            for s in d.get("from", []): archive(name, src_path(name, kind, s))
        write_atomic(target, d.get("content", ""))
        state["accepted_total"] += 1
        notif["created" if action == "create" else "updated"].append(f"{kind}:{d.get('name')}")
        if action == "merge":
            notif["merged"].append({"into": d.get("into"), "from": d.get("from")}); state["merged_total"] += 1
    elif action == "prune":
        target = src_path(name, kind, d["name"])
        if not cp.is_writable(name, target):
            state["rejected_total"] += 1; return
        if Path(target).exists():
            archive(name, target); state["pruned_total"] += 1; notif["pruned"].append(f"{kind}:{d.get('name')}")

def read_activity(p):
    try: return int(Path(p).read_text().strip())
    except Exception: return None

def summarize(n):
    return f"{len(n['created'])} created, {len(n['updated'])} updated, {len(n['pruned'])} pruned, {len(n['merged'])} merged"

def run_profile(name):
    cdir = cp.curator_dir(name); cdir.mkdir(parents=True, exist_ok=True)
    lock = open(cdir / ".curator.lock", "w")
    try:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError: log(name, "skip: lock held"); return
        state = load_state(name)
        if state.get("paused"): log(name, "skip: paused"); return
        la = read_activity(cdir / "last_activity")
        if la is not None and (epoch() - la) < IDLE: log(name, "skip: recent activity"); return
        candidates = gather_candidates(name)
        if not candidates: return
        t0 = epoch()
        # B.2: reduce codex_run logs to additive usage + bounded events (backend-aware)
        skill_names = set(list_skills(name))
        additive_hits, codex_events = {}, []
        for f, c in candidates:
            if c.get("kind") != "codex_run": continue
            used, events = reduce_codex_log(c.get("log_path", ""), skill_names)
            for s, n in used.items(): additive_hits[s] = additive_hits.get(s, 0) + n
            codex_events.append({"dispatch_id": c.get("dispatch_id"),
                                 "backend": c.get("backend", "codex"), "events": events})
        stats = update_stats(name, additive_hits=additive_hits)
        decisions, selected_files = synthesize(name, candidates, prune_nominations(stats), codex_events)
        if decisions is None:
            state["failures_total"] = state.get("failures_total", 0) + 1
            save_state(name, state); log(name, "synthesize failed; candidates retained"); return
        notif = {"run_at": now_iso(), "created": [], "updated": [], "pruned": [], "merged": []}
        for d in decisions.get("decisions", []):
            apply_decision(name, d, state, notif)
        for f in selected_files:
            try: f.unlink()
            except FileNotFoundError: pass
        # two-pass: re-queue mined skill candidates as flags for a future run
        for cand in decisions.get("new_skill_candidates", []):
            requeue_mined(name, cand)
        regen_index(name)
        update_memory_index(name)
        state["run_count"] = state.get("run_count", 0) + 1
        state["last_run_at"] = now_iso()
        state["last_run_duration_seconds"] = epoch() - t0
        state["last_run_summary"] = summarize(notif)
        save_state(name, state)
        if any(notif[k] for k in ("created", "updated", "pruned", "merged")):
            write_atomic(cdir / "notifications" / f"{now_iso()}.json", json.dumps(notif, indent=2))
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN); lock.close()

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
        existing = idx.read_text() if idx.is_file() else ""
        if not all(f in existing for f in files) or not existing.startswith("# Memory Index"):
            write_atomic(idx, header + body)

def cmd_status(name):
    s = load_state(name)
    inbox = cp.curator_dir(name) / "inbox"
    pending = len(list(inbox.glob("*.json"))) if inbox.is_dir() else 0
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

def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "run"
    def prof(idx=1): return args[idx] if len(args) > idx else "default"
    if cmd == "run":
        targets = [args[1]] if len(args) > 1 else cp.all_profiles()
        for name in targets: run_profile(name)
    elif cmd == "status":  cmd_status(prof())
    elif cmd == "pause":   cmd_pause(prof(), True)
    elif cmd == "resume":  cmd_pause(prof(), False)
    elif cmd == "stats":   cmd_stats(prof())
    elif cmd == "pending": cmd_pending(prof())
    elif cmd == "log":
        n = 50
        if "-n" in args:
            try: n = int(args[args.index("-n") + 1])
            except Exception: n = 50
        p = "default"
        for a in args[1:]:
            if a.startswith("-"): break
            p = a; break
        cmd_log(p, n)
    elif cmd == "restore":
        if len(args) < 2:
            sys.stderr.write("curator.py: restore <name> [profile]\n"); sys.exit(2)
        cmd_restore(prof(2), args[1])
    else:
        sys.stderr.write(f"curator.py: unknown command {cmd}\n"); sys.exit(2)

if __name__ == "__main__":
    main()

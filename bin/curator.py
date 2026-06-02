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

def synthesize(name, candidates):
    payload = {
        "candidates": [c for _, c in candidates],
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
        decisions = synthesize(name, candidates)
        if decisions is None:
            state["failures_total"] = state.get("failures_total", 0) + 1
            save_state(name, state); log(name, "synthesize failed; candidates retained"); return
        notif = {"run_at": now_iso(), "created": [], "updated": [], "pruned": [], "merged": []}
        for d in decisions.get("decisions", []):
            apply_decision(name, d, state, notif)
        for f, _ in candidates:
            try: f.unlink()
            except FileNotFoundError: pass
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

# --- stubs replaced in later tasks (T5 synthesis, T8 index/memory) ---
def regen_index(name): pass
def update_memory_index(name): pass
def build_prompt(payload): return json.dumps(payload)
def extract_json(s): return s
def validate_decisions(d): return d if isinstance(d, dict) and "decisions" in d else None

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

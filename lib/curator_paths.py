"""Path + profile helpers for the curator daemon. Honors CC_PROFILE_ROOT (tests)."""
import os
from pathlib import Path

def cc_root() -> Path:
    return Path(os.environ.get("CC_PROFILE_ROOT", str(Path.home() / ".claude")))

def profiles_dir() -> Path:
    return cc_root() / "profiles"

def profile_dir(name: str) -> Path:
    return cc_root() if name == "default" else profiles_dir() / name

def all_profiles() -> list:
    names = ["default"]
    pd = profiles_dir()
    if pd.is_dir():
        for d in sorted(pd.iterdir()):
            if d.is_dir() and d.name != "_shared" and not d.name.startswith("."):
                names.append(d.name)
    return names

def curator_dir(name: str) -> Path:
    return profile_dir(name) / "curator"

# Writable-path allowlist. Returns True iff `target` is under an allowed root.
def is_writable(name: str, target) -> bool:
    p = profile_dir(name).resolve()
    t = Path(target).resolve()
    allowed = [p / "skills", p / "curator"]
    try:
        rel = t.relative_to(p)
        parts = rel.parts
        if len(parts) >= 3 and parts[0] == "projects" and parts[2] == "memory":
            return True
    except ValueError:
        return False
    return any(str(t).startswith(str(a.resolve()) + os.sep) or t == a for a in allowed)

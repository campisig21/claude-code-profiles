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

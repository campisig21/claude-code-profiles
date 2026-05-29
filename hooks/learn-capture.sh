#!/usr/bin/env bash
# Stop hook (subsystem B feed). Drops a lightweight breadcrumb describing the
# just-finished turn into the active profile's curator/inbox/. The daemon (B)
# consumes these. MUST never fail the session: always exits 0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/paths.sh"

input="$(cat 2>/dev/null || true)"
name="$(resolve_active_profile)"
inbox="$(profile_dir "$name")/curator/inbox"
mkdir -p "$inbox" 2>/dev/null || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo "")"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
fname="$inbox/${ts}-${session_id}-$$.json"

jq -n --arg ts "$ts" --arg sid "$session_id" --arg tp "$transcript" \
      --arg cwd "$cwd" --arg prof "$name" \
  '{kind:"turn", captured_at:$ts, profile:$prof, session_id:$sid, transcript_path:$tp, cwd:$cwd}' \
  > "$fname" 2>/dev/null || true

exit 0

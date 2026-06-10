# daemon-macos.sh — install the background curator (subsystem B) as a launchd
# user agent. Sourced by install.sh on Darwin. Expects $SRC and $ROOT in scope.
# Idempotent + non-clobbering: writes the plist only if absent, never auto-loads
# (mirrors the print-the-command UX so the user opts in explicitly).

LA_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
mkdir -p "$LA_DIR"
plist="$LA_DIR/com.profile-system.curator.plist"
if [ ! -f "$plist" ]; then
  interval="${CURATOR_INTERVAL_SECONDS:-1800}"
  logdir="$ROOT"
  claude_bin="$(command -v claude 2>/dev/null || echo claude)"
  claude_dir="$(dirname "$claude_bin")"
  daemon_path="$claude_dir:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  sed -e "s#__CURATOR_PY__#$SRC/bin/curator.py#g" \
      -e "s#__INTERVAL__#$interval#g" \
      -e "s#__LOGDIR__#$logdir#g" \
      -e "s#__CLAUDE_BIN__#$claude_bin#g" \
      -e "s#__PATH__#$daemon_path#g" \
      "$SRC/templates/curator.plist" > "$plist"
  echo "  Installed launchd curator job -> $plist"
  echo "  Load it with:  launchctl load $plist"
else
  echo "  launchd curator job exists; leaving untouched: $plist"
fi

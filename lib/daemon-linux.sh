# daemon-linux.sh — install the background curator (subsystem B) as a systemd
# *user* service + timer. Sourced by install.sh on Linux. Expects $SRC and $ROOT
# in scope. Idempotent + non-clobbering: writes each unit only if absent and
# never auto-enables (prints the enable command so the user opts in explicitly,
# mirroring the macOS launchd module).
#
# Honors SYSTEMD_USER_DIR (default ~/.config/systemd/user) and
# CURATOR_INTERVAL_SECONDS, so tests can run hermetically on any host.

SYSTEMD_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
mkdir -p "$SYSTEMD_DIR"
service="$SYSTEMD_DIR/profile-system-curator.service"
timer="$SYSTEMD_DIR/profile-system-curator.timer"

interval="${CURATOR_INTERVAL_SECONDS:-1800}"
logdir="$ROOT"
claude_bin="$(command -v claude 2>/dev/null || echo claude)"
claude_dir="$(dirname "$claude_bin")"
python_bin="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
# systemd user services start with a minimal PATH; pin the dirs the curator needs
# (claude, homebrew/usr binaries, and ~/.local/bin where ccp/claude may live).
daemon_path="$claude_dir:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"

if [ ! -f "$service" ]; then
  sed -e "s#__CURATOR_PY__#$SRC/bin/curator.py#g" \
      -e "s#__PYTHON__#$python_bin#g" \
      -e "s#__LOGDIR__#$logdir#g" \
      -e "s#__CLAUDE_BIN__#$claude_bin#g" \
      -e "s#__PATH__#$daemon_path#g" \
      "$SRC/templates/curator.service" > "$service"
  echo "  Installed systemd curator service -> $service"
else
  echo "  systemd curator service exists; leaving untouched: $service"
fi

if [ ! -f "$timer" ]; then
  sed -e "s#__INTERVAL__#$interval#g" \
      "$SRC/templates/curator.timer" > "$timer"
  echo "  Installed systemd curator timer -> $timer"
else
  echo "  systemd curator timer exists; leaving untouched: $timer"
fi

echo "  Enable it with:  systemctl --user enable --now profile-system-curator.timer"
echo "  Headless host?   loginctl enable-linger \"$USER\"  (so the timer runs without an active login)"

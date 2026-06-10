#!/usr/bin/env bash
# install.sh — wire this repo into the live Claude Code config and adopt the
# default profile (~/.claude) into the profile structure, additively.
#
# One auto-detecting entry point for both macOS and Linux:
#   - the cross-platform core lives in lib/install-common.sh
#   - the background-curator daemon is OS-specific:
#       macOS -> lib/daemon-macos.sh  (launchd user agent)
#       Linux -> lib/daemon-linux.sh  (systemd user service + timer)
#
# Idempotent + non-destructive. Honors CC_PROFILE_ROOT (tests),
# CCP_SKIP_PATH (skip PATH symlink), and PS_OS=macos|linux to force the daemon
# path (auto-detected from `uname -s` otherwise — handy for WSL/containers/tests).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SRC/lib/paths.sh"
source "$SRC/lib/jsonutil.sh"

ROOT="$(cc_root)"
SHARED="$(shared_dir)"

# Cross-platform core: symlinks, settings hooks, ccp, codex config.
source "$SRC/lib/install-common.sh"

# Background curator daemon (subsystem B) — pick the platform path.
OS="${PS_OS:-}"
if [ -z "$OS" ]; then
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    *)      OS="unknown" ;;
  esac
fi
case "$OS" in
  macos) source "$SRC/lib/daemon-macos.sh" ;;
  linux) source "$SRC/lib/daemon-linux.sh" ;;
  *)
    echo "  Unrecognized OS '$(uname -s)'; skipping background curator daemon."
    echo "  Force a path with:  PS_OS=macos|linux bash install.sh"
    ;;
esac

echo "Done. Default profile adopted. Create more with: /profile create <name>  (interview; or scaffold directly with  $SRC/profile_mgmt.sh provision <name>)"

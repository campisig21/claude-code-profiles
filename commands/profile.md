---
description: Manage Claude Code profiles (list, show, status, create, archive, switch, doctor)
argument-hint: <subcommand> [name]
allowed-tools: Bash
---

Run the profile-system management script and present its output to the user verbatim,
then add a one-line interpretation if helpful.

Execute:

!`bash ~/.claude/profile-system/profile_mgmt.sh $ARGUMENTS`

If `$ARGUMENTS` is empty, run `list`. For `switch`, remember mid-session switching
is impossible — surface the printed `ccp <name>` command so the user can relaunch.

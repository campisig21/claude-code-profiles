# ADR-0005: The ADR / docs-decisions standard is provisioned into every profile

- **Status:** Accepted
- **Date:** 2026-06-21
- **Canonical source:** `rules/adr-decisions.md` (the rule text), seeded into each
  profile's `rules/` by `lib/install-common.sh` (default profile) and
  `profile_mgmt.sh` `provision` (every new profile).
- **Supersedes / Superseded by:** builds on [ADR-0001](0001-record-architecture-decisions.md); supersedes none.

## Context

[ADR-0001](0001-record-architecture-decisions.md) adopted the `docs/decisions/`
ADR convention, but only for *this* repo. The profile system exists to run many
isolated Claude Code configs (profiles), each working across many repos. Nothing
carried the drift-resistant practice into those profiles or the repos they touch
— a new profile started with no standard at all, so the same prose-drift problem
ADR-0001 solved would simply recur everywhere else.

The request: make the ADR standard the default for **all future projects and
repos**, applied at **profile creation** so it is automatic rather than
remembered.

## Decision

Treat the ADR standard as **shared machinery**, like skills/commands/hooks. One
canonical rule file, `rules/adr-decisions.md`, is symlinked `repo/rules ->
_shared/rules` and then fanned into each profile's `rules/`:

- the adopted **default** profile by the installer (`lib/install-common.sh`);
- every **new** profile by `profile_mgmt.sh provision`.

Claude Code natively loads `$CLAUDE_CONFIG_DIR/rules/*.md` as global instructions,
so whichever profile is active picks up the standard in every session and every
repo. The rule is **self-contained** (it does not depend on this repo being
present) so it works in any checkout.

## Consequences

- Every new profile, and the in-place-adopted default, carry the standard with
  no manual step.
- Symlink (not copy) means one canonical edit propagates to all profiles — this
  honors rule #2 (*link, don't copy*) rather than scattering N copies that drift.
- The standard lives in `rules/`, not the persona, so the `/profile create`
  authoring flow can rewrite `CLAUDE.md` without ever clobbering it.
- `rules/` becomes a first-class shared-machinery directory alongside
  `skills/`, `commands/`, and `hooks/`.

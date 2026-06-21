# Architecture decisions → `docs/decisions/` ADRs

When you make a decision of architectural significance in **any** repo — or the
user asks you to record one — capture it as a numbered Architecture Decision
Record (ADR) under `docs/decisions/`. This is the default for every project
worked on under this profile. It exists to kill prose drift: one fact (an
endpoint, a default, a CLI contract) restated across specs, memory, and READMEs
inevitably falls out of sync.

## What counts as architecturally significant

Record an ADR when a choice is hard to reverse or shapes how the system is
built: a default (model, port, framework), a contract (env var, endpoint, CLI
flag), a structural pattern, a dependency or boundary, a process rule. Skip it
for routine, easily-reversed edits — don't manufacture ADRs for trivia.

## The four rules (what makes this drift-resistant)

1. **One decision, one ADR.** Each decision lives in exactly one numbered file.
2. **Link, don't copy.** Other docs reference an ADR by number; they never
   restate its content. A second copy is a future inconsistency.
3. **Contracts live in code, not prose.** Operational contracts (env vars,
   endpoints, flags) are owned by their executable/config. The ADR records the
   *decision* and points at the canonical artifact — it does not inline the bytes.
   When the contract changes, change the artifact; the ADR still points at it.
4. **Append, supersede — never silently edit.** A changed decision gets a new
   ADR that supersedes the old one (status `Superseded`, with a link). The record
   of *why we changed* is itself valuable.

Status values: `Proposed` → `Accepted` → `Superseded` (or `Rejected`).

## Bootstrapping a repo that has no `docs/decisions/` yet

Don't pre-create empty scaffolding. The first time an architectural decision
arises in a repo that lacks the directory, create it:

1. `docs/decisions/README.md` — a short statement of the four rules plus an index
   table: `| ADR | Title | Status | Canonical source |`.
2. `docs/decisions/0000-template.md` — the template below.
3. `docs/decisions/0001-record-architecture-decisions.md` — Accepted; establishes
   the practice in this repo.

Then add the actual decision as `0002-…` and a row in the index.

## ADR template

```
# ADR-NNNN: <title>

- **Status:** Proposed | Accepted | Superseded by ADR-XXXX | Rejected
- **Date:** YYYY-MM-DD
- **Canonical source:** <the executable/config/spec that owns the contract this
  decision governs — where the live truth lives. "n/a" for pure decisions.>
- **Supersedes / Superseded by:** <ADR links, or none>

## Context
<The forces at play: problem, constraints, evidence. Why a decision is needed now.>

## Decision
<What we decided, stated plainly.>

## Consequences
<What follows — good and bad. In particular, which other docs must now LINK here
instead of restating the fact.>
```

Reference implementation: the `claude-code-profiles` repo's own `docs/decisions/`
is the origin of this standard.

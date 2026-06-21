# Architecture Decision Records (ADRs)

This directory is the **single source of truth for architectural decisions** in
this repo. It exists to kill prose drift: the same fact (an endpoint, a default
model, a command's env contract) used to be restated across specs, memory, and
READMEs, and the copies fell out of sync (see [ADR-0001](0001-record-architecture-decisions.md)).

## The rules (what makes this drift-resistant)

1. **One decision, one ADR.** Each decision lives in exactly one numbered file.
2. **Link, don't copy.** Other docs reference an ADR by number; they do not
   re-state its content. A second copy is a future inconsistency.
3. **Contracts live in code, not prose.** Operational contracts (env vars,
   endpoints, CLI flags) are owned by their executable/config. The ADR records
   *the decision and points at the canonical artifact* — it does not inline the
   bytes. When the contract changes, change the artifact; the ADR still points
   at it.
4. **Append, supersede — never silently edit.** A decision that changes gets a
   new ADR that supersedes the old one (status `Superseded`, with a link). The
   record of *why we changed* is itself valuable.

Dated design docs in `docs/specs/` and `docs/superpowers/` stay point-in-time
snapshots; this log is the durable, indexed record of *decisions* and the
pointer to each contract's canonical artifact.

## Status values

`Proposed` → `Accepted` → `Superseded` (or `Rejected`).

## Index

| ADR | Title | Status | Canonical source of the contract it governs |
|---|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions as ADRs | Accepted | this directory |
| [0002](0002-local-serving-single-llama-jinja-no-proxy.md) | Local serving = one llama-jinja server, no proxy | Accepted | `station/llama-jinja/` + `llama-control.sh` |
| [0003](0003-default-local-dispatch-model.md) | Default local dispatch model = qwen3-coder-30b | Accepted | `station/llama-jinja/` active `.env` |
| [0004](0004-claude-local-dispatch-transport.md) | claude-on-station as a first-class dispatch transport | Proposed | `bin/claude-run` (forthcoming) |

## Adding an ADR

Copy [`0000-template.md`](0000-template.md) to the next number, fill it in, set
the status, and add a row to the index above. Keep it short — context, decision,
consequences, and the pointer to the canonical artifact.

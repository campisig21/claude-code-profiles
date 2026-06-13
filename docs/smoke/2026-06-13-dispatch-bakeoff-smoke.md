# Manual smoke checklist — dispatch bake-off (Subsystem E, Phase 2)

The bake-off orchestrator (`workflows/dispatch-bakeoff.js`) is JavaScript run by the
Claude Code harness, **not** by the bash test suite. The automated tests cover the
library spine (land-one/abandon-rest) and the static contracts; this checklist covers
what only a real run can prove. Run it on this machine after any change to the workflow,
the command, or the cell contract.

## Prerequisites
- [ ] `codex` is installed and authenticated (cloud `gpt-5.5` reachable).
- [ ] (Optional, for the local contestant) the ollama backend is configured and a model
      server is ready (`dispatch doctor` shows the local backend), so `qwen2.5` can run.
- [ ] A throwaway git repo with a small, real task and a real check command
      (e.g. `npm test`, `pytest`, or `bash check.sh`).

## 1. Fan-out + live surfacing
- [ ] Run: `/dispatch-bakeoff --models gpt-5.5,qwen2.5 --check '<your check>' "<your task>"`.
- [ ] Confirm **two contestant cells** appear in the `/workflows` live view, each progressing
      through the `Bake-off` phase, then a single `Judge` agent.
- [ ] Confirm the same dispatches appear in `dispatch console` with
      `id · harness · backend · model · status · last-activity`, `harness=workflow`.
- [ ] `dispatch attach <id>` on one contestant live-tails its event log (codex `--json`
      progress for the gpt/qwen cells).

## 2. Concurrent worktree safety (the gap the bash test does NOT cover)
- [ ] The automated `dispatch_bakeoff_id_test.sh` proves collision-free ids for **sequential**
      begins only. Here, both `begin` calls fire under **true parallelism** — the contestant
      cells run concurrent `git worktree add` against the same repo. Confirm both contestants
      created **distinct worktrees with no `git worktree add` lock error** in the cell logs.
- [ ] If you see a worktree/lock error: that is the R5 contention case. Fallback (a Phase-2.x
      follow-up, NOT a seam change made blind): add a short lock-retry around `git worktree add`
      in `d_begin`. File it; do not patch the seam without a paired review.

## 3. Verdicts + judge
- [ ] Each contestant returns a **schema-valid verdict** (the workflow does not error on
      structured output; `id/backend/model/status/checks_passed/touches_tests` present).
- [ ] With ≥2 survivors, the judge returns a `recommendation` with `winner_id`, `why`,
      `ranking`, and — if any contestant weakened tests — populated `test_integrity_flags`.
- [ ] To exercise the integrity path on purpose, give one model a task it is tempted to "pass"
      by editing the test; confirm the judge flags it and you can see it in
      `recommendation.test_integrity_flags`.

## 4. Land exactly one / abandon the rest (the orchestrator's job — E9)
- [ ] Review the winner: `dispatch show <winner_id> --diff` (actually read it).
- [ ] `dispatch land <winner_id>` → confirm it merges onto HEAD, removes the worktree,
      and sets status `landed`.
- [ ] `dispatch abandon <id>` for each other contestant → worktrees removed, status `abandoned`,
      their changes absent from the base branch.
- [ ] Confirm the **workflow itself landed/abandoned nothing** — all of it was your decision.

## 5. Direct-Claude contestant
- [ ] Run a bake-off whose contestant set includes `claude`. Confirm the `(—, claude)` cell
      **edits files directly in its worktree** (no `codex-run`) and produces a landable diff.
- [ ] If the contestant cannot edit files (the default Workflow subagent lacks editing tools):
      note it. Fallback: set `agentType` on that `agent()` call to a coding-capable agent. This
      is a workflow-script tweak only — it does not touch the seam.

## 6. Back-compat unaffected (E8)
- [ ] `/codex-implement "<task>"` still drives the original `harness=codex` autonomous loop
      end-to-end. The bake-off must not have disturbed it.

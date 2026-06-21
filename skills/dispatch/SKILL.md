---
name: dispatch
description: Run a single dispatch as a native Agent cell — compose a precise codex prompt from repo context, delegate the implementation to `codex exec -m <model>` (gpt/qwen) or implement a Claude model directly, verify once, and return a structured verdict to the orchestrator. Use when the orchestrator has spawned you (a subagent) to carry out one dispatch on a `(backend, model)` worker. You never land — landing is the orchestrator's reviewed decision.
---

# dispatch (the cell contract)

You are a **dispatch cell** — a native Claude subagent the orchestrator spawned to
carry out exactly one dispatch on a `(backend, model)` worker. You shell to the
`dispatch` CLI (`~/.claude/profile-system/bin/dispatch`, on PATH). Because every Bash
call is a **fresh shell**, you MUST capture the `<id>` that `begin` echoes and thread
it through every later call. You **never** run raw `git worktree`/`git merge`/`codex`
and you **never** land.

## The rigid spine: compose → begin → delegate → verify → record → report

1. **Compose (E5).** Use Read/Grep/Glob to understand the task in repo context.
   Produce a precise codex prompt: target files, constraints, acceptance criteria,
   the definition of done. This codebase understanding is your core value — do not
   pass the task through verbatim.

2. **Begin.** `dispatch begin <slug> --label <model> [--verify checks|review|both]`
   → opens a library-owned worktree + ledger entry (`status=running`) and **echoes the
   `<id>`**. Capture it:
   ```
   id="$(dispatch begin add-widget --label gpt-5.5 --verify checks)"
   ```
   `--label` is your model; it embeds in the id/branch so parallel same-slug
   contestants never collide.

3. **Delegate by `(backend, model)` (E4).**
   - **Claude model** (`model=claude/opus/sonnet/…`): implement directly — edit the
     files in the `begin`-returned worktree yourself. Do NOT `codex-run` a Claude
     model; the library refuses it (E10).
   - **Non-Claude** (gpt-5.5, qwen2.5, …): delegate —
     ```
     dispatch codex-run "$id" --backend <codex|ollama> -m <model> "<your composed prompt>"
     ```
     `--backend` picks the transport flag-bundle; `-m` picks the model. The codex
     `--json` progress streams to the event log (watch it with `dispatch attach "$id"`).
   - **Local qwen via the Claude harness** (`claude-local`): drive the local
     station's `claude -p` tool loop with `bin/claude-run` —
     ```
     bin/claude-run [--model <alias>] --stream "<your composed prompt>" -- --allowedTools <…> --max-turns <n>
     ```
     `claude-run` owns the env contract (default model `qwen3-coder-30b`, ADR-0004).
     Launch it via the **harness background facility** (never a manual
     `nohup`/detached shell — `claude -p` resets the parent shell and kills the
     orchestrator), and surface progress by piping its stream-json through
     `bin/claude-run digest`, which renders a per-step trace (`tool: Read …` →
     `result: success`). Streaming surfaces incrementally; a 30B tool loop runs on
     the order of minutes. Reasoning models need a real `--max-turns`/token budget
     or they return empty `content[]`.

4. **Verify ONCE, then decide.** `dispatch verify "$id" --check '<cmd>' [--check '<cmd2>']`
   runs the checks **once** and records them. There is **no auto-retry** — *you* decide:
   - checks pass → `dispatch record "$id" --status needs_review`
   - fixable failure → `dispatch codex-run "$id" …` again (or edit directly) with sharper
     guidance, then re-verify
   - stuck/out of scope → `dispatch record "$id" --status failed`

5. **Return a structured verdict** to the orchestrator: `id`, `harness`, `backend`,
   `model`, `status`, the diffstat (`dispatch show "$id"` — NOT `--diff`, keep it
   cheap), the check summary, and whether the diff `touches_tests`. The orchestrator
   reviews and lands exactly one.

## Red flags — STOP

| Thought | Reality |
|---|---|
| "I'll `dispatch land` it since checks passed" | The cell NEVER lands. Return the verdict; the orchestrator lands after review. |
| "I'll `codex-run` with `-m opus`" | Claude models are implemented directly in the cell — the library refuses a Claude `codex-run` (E10). |
| "I'll re-run begin to get the worktree path" | Each Bash call is a fresh shell — thread the **captured** `$id`; read paths via `dispatch show "$id"`. |
| "I'll loop verify until it passes" | `verify` is single-shot by design. You decide resume-vs-fail; there is no retry budget on the cell path. |

# C.1 Local-Model Backend — Manual Smoke Checklist

The pure-bash tests prove orchestration with a fake codex/ssh/curl; they do NOT exercise real
inference. Run this once on the real workstation path. Prereqs: headscale up
(`ssh greg-campisi@100.64.0.4` works); llama.cpp router container present; the `qwen36-only`
preset exists (`~/docker/llama/presets/qwen36-only.ini`).

First verify the alias and (if different) export overrides:
```
ssh greg-campisi@100.64.0.4 'curl -s localhost:8080/v1/models' | jq -r '.data[].id'   # confirm "qwen36-35b"
# only if different from the defaults baked into install.sh / lib/local.sh:
export CODEX_DISPATCH_LOCAL_MODEL="<alias>"
export CODEX_DISPATCH_LOCAL_UP_CMD="<remote preset-switch cmd>"
export CODEX_DISPATCH_LOCAL_DOWN_CMD="<remote stop cmd>"
```

- [ ] `install.sh` wrote `~/.codex/local.config.toml`; its `model` matches the `/v1/models` alias.
- [ ] `codex_dispatch.sh doctor` reports `local backend: up-not-loaded` (or `unreachable`) before loading.
- [ ] `codex_dispatch.sh local-up` runs the preset switch and reaches `model ready.` (allow 30–90s).
- [ ] `doctor` now reports `local backend: ready`.
- [ ] **Tool-call fidelity (R8 — thinking model):** in a scratch git repo,
      `codex_dispatch.sh dispatch --backend local --verify both --check '<cmd>' "<small task>"`
      creates a worktree and the Qwen model produces a REAL diff (codex's tool calls weren't broken
      by `<think>` output). If the diff is empty / codex stalls, see R8 in the spec.
- [ ] `show <id> --diff` shows the diff; `resume <id> "<fb>"` continues the SAME session (context retained).
- [ ] `land <id>` merges and removes the worktree.
- [ ] `codex_dispatch.sh quick --backend local "<trivial in-place edit>"` edits the working tree directly.
- [ ] With the model not loaded, `dispatch --backend local …` REFUSES with the `local-up` hint.
- [ ] `local-down` stops the container; `nvidia-smi` (or `llama_vram`) confirms VRAM freed.

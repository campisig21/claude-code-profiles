---
name: learn
description: Use when you (the main session) have learned something worth keeping — a reusable technique, a project fact, or a correction — and want the background curator to file it as a skill or memory. Flags a learning candidate; the curator validates, dedupes, and writes it.
---

# /learn — flag a learning candidate

When something in this session is worth remembering for future sessions, call the
helper below. You supply *what* was learned; the background curator (headless Sonnet)
decides how to file it (skill vs memory), dedupes against existing artifacts, and writes it.

Run:

```bash
~/.claude/profile-system/bin/learn-flag \
  --type auto \
  --title "<short title>" \
  --body "<the substance — the technique/fact/correction, in enough detail to act on>" \
  --context "<why/when it came up — helps write a good 'use-when'>"
```

- `--type`: `skill` (reusable how-to), `memory` (a fact about the user/project), or
  `auto` (let the curator decide — the usual choice).
- Keep `--body` self-contained; the curator has no access to this conversation.
- This only *queues* the candidate. It is filed on the next curator run and you'll see
  a `CURATOR UPDATE` note at a future session start.

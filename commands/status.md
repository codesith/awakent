---
description: Show awakent status: wake assertion, live sessions, time to release
---

Run exactly this command and nothing else:

```
"${CLAUDE_PLUGIN_ROOT}/hooks/awakent.sh" status
```

Render its output as one compact plain-text block for the user:

- `assertion: held (caffeinate pid N)` → "Wake assertion: HELD (caffeinate pid N)"; `assertion: released` → "Wake assertion: released. The Mac may sleep normally."
- `session:` lines → a "Live sessions (N):" list showing each session id and minutes since activity. List any `(stale)` entries separately as "Stale (awaiting cleanup):" (these do not hold the machine awake).
- `release-in: Nm` → "Releases in ~N minutes if no further activity." (`release-in: -` means nothing is held.)
- `config:` → one line with ttl_minutes, lid_closed_mode, debug. If a `config-warning:` line appears, mention the invalid keys fell back to defaults.
- `log:` (present only with debug on) → "Debug log: <path>".

Do not run any other commands. Do not read or modify anything under `~/.claude/awakent/`.

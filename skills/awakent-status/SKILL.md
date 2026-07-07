---
name: awakent-status
description: Show awakent wake-lock status - whether the caffeinate assertion is held, live agent sessions across all hosts, minutes until TTL release, and the config in effect. Use when the user asks about awakent, the wake lock, caffeinate, or why the Mac is or is not allowed to sleep.
---

# awakent status

Resolve the awakent engine path; first match wins:

1. `$AWAKENT_ENGINE`, if that environment variable is set
2. `~/.claude/hooks/awakent.sh`
3. `hooks/awakent.sh` inside the awakent plugin directory, if this skill was installed as part of a plugin

Run exactly this command and nothing else (it is strictly read-only):

```
bash <engine-path> status
```

Render its output as one compact plain-text block for the user:

- `assertion: held (caffeinate pid N)` → "Wake assertion: HELD (caffeinate pid N)"; `assertion: released` → "Wake assertion: released. The Mac may sleep normally."; `assertion: unsupported` → this machine has no `caffeinate` (not macOS) and awakent is inert here.
- `session:` lines → a "Live sessions (N):" list showing each session id, its agent (`host=claude|codex|cursor|copilot|pi` - display it as the agent name; a line without a `host=` token was written by an older engine, show its agent as "unknown"), and minutes since activity. A `(ttl-only)` suffix means that host exposes no PID, so the session is tracked by activity age alone. List any `(stale)` entries separately as "Stale (awaiting cleanup):" (these do not hold the machine awake).
- `release-in: Nm` → "Releases in ~N minutes if no further activity." (`release-in: -` means nothing is held.)
- `config:` → one line with ttl_minutes, lid_closed_mode, debug. If a `config-warning:` line appears, mention the invalid keys fell back to defaults.
- `log:` (present only with debug on) → "Debug log: <path>".

Do not run any other commands. Do not read or modify anything under `~/.claude/awakent/`.

# awakent status

Show the awakent wake-lock status. Run exactly this command and nothing else (it is strictly read-only):

```
bash ~/.claude/hooks/awakent.sh status
```

Render its output as one compact plain-text block:

- `assertion: held (caffeinate pid N)` → "Wake assertion: HELD (caffeinate pid N)"; `assertion: released` → "Wake assertion: released. The Mac may sleep normally."
- `session:` lines → a "Live sessions (N):" list with each session id, its agent (`host=claude|codex|cursor|copilot|pi`; a line without a `host=` token was written by an older engine - show "unknown"), and minutes since activity. A `(ttl-only)` suffix means the session is tracked by activity age alone (Cursor sessions show this - Cursor exposes no PID to hooks). List `(stale)` entries separately; they do not hold the machine awake.
- `release-in: Nm` → "Releases in ~N minutes if no further activity." (`-` means nothing is held.)
- `config:` → one line with ttl_minutes, lid_closed_mode, debug; mention any `config-warning:` keys fell back to defaults.

Do not run any other commands. Do not read or modify anything under `~/.claude/awakent/`.

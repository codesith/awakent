---
description: Set awakent config: ttl_minutes, lid_closed_mode, debug
---

The user wants to view or change awakent's configuration. Their input (may be empty): $ARGUMENTS

awakent's config lives in the file `~/.claude/awakent/config` (`key=value` lines, parsed as data, never executed). That file is the single source of truth; this command is only a guided editor for it. One config governs every supported host (Claude Code, Codex, Cursor, Copilot, pi). Exactly three keys exist:

| Key | Default | Valid values | Meaning |
| --- | --- | --- | --- |
| `ttl_minutes` | `60` | integer 5-1440 | Release the wake assertion this long after the last activity |
| `lid_closed_mode` | `0` | `0`, `1`, `true`, `false` | `1`/`true`: also hold the display awake (`caffeinate -is`) so lid-closed on AC survives |
| `debug` | `0` | `0`, `1`, `true`, `false` | `1`/`true`: log events (session ids only) to `~/.claude/awakent/awakent.log` |

**If the input is empty:** run exactly `"${CLAUDE_PLUGIN_ROOT}/hooks/awakent.sh" status`, show the user the `config:` line (and any `config-warning:` line, explaining that invalid keys fell back to defaults), then show the table above. Write nothing.

**If the input contains `key=value` pairs:** validate every pair against the table first: `ttl_minutes` must be an integer from 5 to 1440; `lid_closed_mode` and `debug` accept only `0`, `1`, `true`, `false`; any key not in the table is unknown. If ANY pair is invalid or unknown, refuse the entire request: show what was wrong and the table above, and do not modify the file at all. Only when every pair is valid:

1. Create the directory and file if needed (`mkdir -p ~/.claude/awakent`; empty file is fine).
2. Edit `~/.claude/awakent/config`: for each given key, replace its existing `key=value` line if one exists, otherwise append the line. Preserve every other line exactly as-is: comments, blank lines, even lines you consider invalid. Never reorder or rewrite lines you were not asked to change.
3. Run exactly `"${CLAUDE_PLUGIN_ROOT}/hooks/awakent.sh" status` and show the user the resulting `config:` line as confirmation.
4. If `ttl_minutes` changed, tell the user: the running caffeinate timer picks up the new TTL at the next restart event, at most one refresh interval away (TTL/4, minimum 60s); it is not instant.

Strict limits: run no command other than the two `awakent.sh status` invocations above. Read or write no file other than `~/.claude/awakent/config`. Never source, execute, or evaluate the config file's contents; it is data.

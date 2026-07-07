# awakent config

View or change awakent's configuration. The config lives in `~/.claude/awakent/config` (`key=value` lines, parsed as data, never executed) - the single source of truth, shared by every supported host (Claude Code, Codex, Cursor, Copilot, pi). Exactly three keys exist:

| Key | Default | Valid values | Meaning |
| --- | --- | --- | --- |
| `ttl_minutes` | `60` | integer 5-1440 | Release the wake assertion this long after the last activity |
| `lid_closed_mode` | `0` | `0`, `1`, `true`, `false` | `1`/`true`: also hold the display awake (`caffeinate -is`) so lid-closed on AC survives |
| `debug` | `0` | `0`, `1`, `true`, `false` | `1`/`true`: log events (session ids only) to `~/.claude/awakent/awakent.log` |

**To view:** run exactly `bash ~/.claude/hooks/awakent.sh status`, show the `config:` line (and any `config-warning:` line, explaining invalid keys fell back to defaults), then the table above. Write nothing.

**To set values:** validate every `key=value` pair against the table first; if ANY pair is invalid or unknown, refuse the entire request and do not modify the file. Only when every pair is valid:

1. `mkdir -p ~/.claude/awakent`; create the file if needed.
2. Replace each given key's existing line or append it. Preserve every other line exactly - comments, blanks, even invalid lines. Never reorder lines you were not asked to change.
3. Run `bash ~/.claude/hooks/awakent.sh status` and show the resulting `config:` line as confirmation.
4. If `ttl_minutes` changed: the running caffeinate timer picks it up at the next restart event, at most one refresh interval away (TTL/4, minimum 60s); not instant.

Strict limits: run no command other than the status invocations above. Read or write no file other than `~/.claude/awakent/config`. Never source, execute, or evaluate the config file's contents.

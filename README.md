# awakent

[![CI](https://github.com/codesith/awakent/actions/workflows/ci.yml/badge.svg)](https://github.com/codesith/awakent/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Keep your Mac awake **exactly while Claude Code sessions are active**, and let it sleep when they're not. Pure shell, zero dependencies, bounded by TTL in every failure direction.

*awake + agent. (Urban Dictionary also defines "awakent" as awake-n't. This plugin makes sure your Mac never is, while it matters.)*

## Why

Agentic coding sessions die when macOS sleeps. That includes Remote Control sessions, which time out after about 10 minutes of unreachability and kill the approve-from-your-phone workflow. Running `caffeinate` by hand is forgettable in both directions, and existing automations either mistrack parallel sessions or require downloaded runtimes that locked-down environments can't approve.

**awakent's slot:** multi-session correctness in pure shell. Nothing to download but this repo; nothing runs but `/bin/bash` and the OS's own `caffeinate`.

- **Exact:** one wake assertion while at least one session is active. Parallel terminals, VS Code, and staggered starts and ends are all tracked per-session.
- **Bounded:** activity-refreshed TTL (default 60 min). A forgotten session holds the Mac at most one TTL past its last activity, and even if awakent itself is killed, `caffeinate -t` self-expires.
- **Auditable:** two shell files. No binaries, no network, no data collection, no privileges. `pmset -g assertions` shows exactly what holds the wake lock.

## Alternatives

| | multi-session | zero runtime | auto (hooks) | bounded failure |
| --- | --- | --- | --- | --- |
| raw `caffeinate` | no | ✅ | ❌ manual both ways | ❌ if forgotten |
| cc-caffeine | ✅ | ❌ npx + Electron | ✅ | ✅ |
| jul-sh/claude-caffeinate | simple | ✅ | ✅ | partial |
| **awakent** | ✅ | ✅ | ✅ | ✅ TTL + `-t` cap |

Both predate awakent and informed its design. They're solid choices if their trade-offs fit your setup.

## Install (plugin)

Works in every Claude Code flavor (terminal, VS Code extension, desktop) via the CLI:

```
claude plugin marketplace add https://github.com/codesith/awakent.git
claude plugin install awakent@awakent
```

(From a local clone, use `claude plugin marketplace add /path/to/awakent` instead of the URL. In terminal Claude Code you can equivalently use the interactive `/plugin` command; the VS Code extension does not expose `/plugin`, so use the CLI form above.)

Then start a new session. That's the whole install: the plugin wires five hooks (SessionStart, SessionEnd, UserPromptSubmit, PostToolUse, Stop) to `awakent.sh` and adds the `/awakent:status` and `/awakent:config` commands. No `settings.json` edits, and your existing hooks are untouched: plugin hooks are additive.

## Manual install (paranoid mode)

For environments where installing a plugin from a third-party repo is not acceptable, awakent works as two auditable files you place yourself. This path is functionally identical to the plugin, minus the slash commands.

1. Read `hooks/awakent.sh` (that's the entire engine), then copy it:

```
mkdir -p ~/.claude/hooks
cp hooks/awakent.sh ~/.claude/hooks/awakent.sh
chmod 755 ~/.claude/hooks/awakent.sh
```

2. **Merge** the following into `~/.claude/settings.json`. ⚠️ If the file already exists, especially if it already has a `hooks` key, merge these entries into it; do not paste over your existing settings.

```json
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "\"$HOME/.claude/hooks/awakent.sh\" register", "timeout": 10}]}
    ],
    "SessionEnd": [
      {"hooks": [{"type": "command", "command": "\"$HOME/.claude/hooks/awakent.sh\" unregister", "timeout": 10}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "\"$HOME/.claude/hooks/awakent.sh\" touch", "timeout": 10}]}
    ],
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": "\"$HOME/.claude/hooks/awakent.sh\" touch", "timeout": 10}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "\"$HOME/.claude/hooks/awakent.sh\" touch", "timeout": 10}]}
    ]
  }
}
```

3. Status on this path (slash commands aren't available without the plugin):

```
bash ~/.claude/hooks/awakent.sh status
```

## Status

With the plugin installed, run `/awakent:status` in Claude Code. It reports: whether the wake assertion is held, live sessions with minutes since activity, minutes until TTL release, and the config in effect. `pmset -g assertions` is the OS's own ground truth if you want to double-check.

## Configuration

With the plugin installed, the easy way is the guided command:

```
/awakent:config                    # show current settings + key reference
/awakent:config ttl_minutes=10    # set one or more key=value pairs
```

It validates input (for example, `ttl_minutes` must be 5-1440), edits the config file for you, and confirms what took effect. The file below remains the single source of truth. The command is optional convenience, and editing the file directly (the only option in paranoid mode) is fully equivalent.

Optional file `~/.claude/awakent/config` (`key=value` lines, parsed as data, never executed):

| Key | Default | Meaning |
| --- | --- | --- |
| `ttl_minutes` | `60` | Release the wake assertion this long after the last activity (bounds 5-1440) |
| `lid_closed_mode` | `0` | `1`/`true`: also prevent display sleep (`caffeinate -is`) so lid-closed on AC survives |
| `debug` | `0` | `1`/`true`: log events (session ids only) to `~/.claude/awakent/awakent.log`, 1MB cap |

**Why doesn't it release on Stop?** End-of-turn is exactly when a Remote Control permission prompt may be waiting for your phone. Releasing then would let the Mac sleep while it's waiting on you. The TTL governs instead: the machine stays reachable for `ttl_minutes` after the last activity, then sleeps.

## Power behavior

| Scenario | Behavior | Status |
| --- | --- | --- |
| Default (`-i`), display | Display sleeps normally (black screen is the point); system stays awake | designed |
| Default (`-i`), system | System stays awake while sessions active + TTL window | verified live (see `pmset -g assertions`) |
| `lid_closed_mode` (`-is`), lid closed on AC | Survives; the display assertion prevents clamshell sleep | designed |
| Any mode, lid closed on battery | Sleeps. macOS clamshell-on-battery policy wins; a documented limitation, not fought | designed (OS policy) |
| awakent killed / uninstalled mid-hold | Assertion self-expires within one `ttl_minutes` (`caffeinate -t` hard cap) | designed + covered by tests |

"designed" means it follows documented `caffeinate` semantics; independently verify on your hardware if it matters to your workflow.

## Auditing this project (for IT and the skeptical)

1. The runtime is two files: `hooks/awakent.sh` and the command markdown. Read them; about 400 lines total.
2. `grep -rE 'curl|wget|nc |/dev/tcp' hooks/ commands/` finds nothing. CI fails if a network primitive ever appears.
3. While running: `pmset -g assertions` names the exact `caffeinate` process holding the wake lock.
4. State lives only in `~/.claude/awakent/` (mode 700/600). Config is parsed, never executed.
5. Removal is total: uninstall the plugin, then `rm -rf ~/.claude/awakent` (see below).

## Uninstall

1. `claude plugin uninstall awakent@awakent` (or disable the plugin). Hooks stop firing for new sessions.
2. A wake assertion held at that moment is **self-expiring**: `caffeinate` runs with `-t`, so the worst case is one `ttl_minutes` (default 60 min) before the Mac can sleep. Nothing needs to be killed for correctness.
3. Impatient? `pkill caffeinate` releases it immediately.
4. Complete state removal, the only thing awakent ever writes outside the plugin directory:

```
rm -rf ~/.claude/awakent
```

Note: the plugin format currently provides no uninstall hook, so awakent cannot clean up at the moment of uninstall. The `-t` self-expiry above is the designed bound, not a workaround.

## Known limitations

- macOS only (the value *is* `caffeinate`/IOPMAssertion); Linux/Windows out of scope.
- Clamshell-on-battery sleep is OS policy; awakent documents it rather than fighting it.
- Plugin slash commands are namespaced (`/awakent:status`); Claude Code doesn't allow bare plugin command names.

## Contributing

PRs welcome within the project's hard constraints: bash 3.2, zero dependencies, no network (see [CONTRIBUTING.md](CONTRIBUTING.md)). DCO sign-off required (`git commit -s`). Security reports: [SECURITY.md](SECURITY.md). Conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Changes: [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 John Xiao

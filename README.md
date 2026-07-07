# awakent

[![CI](https://github.com/codesith/awakent/actions/workflows/ci.yml/badge.svg)](https://github.com/codesith/awakent/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Keep your Mac awake **exactly while agent sessions are active**, and let it sleep when they're not. Built for Claude Code; also works with Codex CLI, Cursor, GitHub Copilot, and pi ([see below](#other-agents-codex-cursor-copilot-pi)). Pure shell, zero dependencies, bounded by TTL in every failure direction.

*awake + agent. (Urban Dictionary also defines "awakent" as awake-n't. This plugin makes sure your Mac never is, while it matters.)*

**Jump to your agent:** [Claude Code](#install-claude-code-plugin) · [Codex CLI](#codex-cli) · [Cursor](#cursor) · [GitHub Copilot](#github-copilot) · [pi](#pi) - [Status](#status), [Configuration](#configuration), and [Uninstall](#uninstall) are shared by all hosts.

## Why

Agentic coding sessions die when macOS sleeps. That includes Remote Control sessions, which time out after about 10 minutes of unreachability and kill the approve-from-your-phone workflow. Running `caffeinate` by hand is forgettable in both directions, and existing automations either mistrack parallel sessions or require downloaded runtimes that locked-down environments can't approve.

**awakent's slot:** multi-session correctness in pure shell. Nothing to download but this repo; nothing runs but `/bin/bash` and the OS's own `caffeinate`.

- **Exact:** one wake assertion while at least one session is active. Parallel terminals, VS Code, staggered starts and ends, even different agents at once (Claude Code + Copilot + Codex) are all tracked per-session in one shared registry.
- **Bounded:** activity-refreshed TTL (default 60 min). A forgotten session holds the Mac at most one TTL past its last activity, and even if awakent itself is killed, `caffeinate -t` self-expires.
- **Auditable:** two shell files (other-agent adapters add only declarative wiring). No binaries, no network, no data collection, no privileges. `pmset -g assertions` shows exactly what holds the wake lock.

## Alternatives

| | multi-session | multi-agent | zero runtime | auto (hooks) | bounded failure |
| --- | --- | --- | --- | --- | --- |
| raw `caffeinate` | no | any agent, by hand | ✅ | ❌ manual both ways | ❌ if forgotten |
| cc-caffeine | ✅ | ❌ Claude Code only | ❌ npx + Electron | ✅ | ✅ |
| jul-sh/claude-caffeinate | ❌ one global PID file | ❌ Claude Code only | ✅ | ✅ | partial |
| vibe-caffeine | n/a (file-watching) | ✅ claude/codex/opencode | ❌ menu-bar app | ❌ FS-activity heuristic | idle heuristic |
| **awakent** | ✅ | ✅ 5 agents, one assertion | ✅ | ✅ | ✅ TTL + `-t` cap |

cc-caffeine and claude-caffeinate predate awakent and informed its design; vibe-caffeine covers multiple agents by watching file activity rather than integrating with each agent's hooks. All are solid choices if their trade-offs fit your setup. (Claims verified against each project as of 2026-07-07.)

## Install (Claude Code plugin)

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

## Other agents (Codex, Cursor, Copilot, pi)

The engine is host-agnostic: any agent that can run a shell command on lifecycle events can register sessions. All hosts share one registry (`~/.claude/awakent/`) and **exactly one** caffeinate - a Codex session ending while a Claude session runs releases nothing, and vice versa.

| Host | Install | Session end signal | Liveness guard | Status |
| --- | --- | --- | --- | --- |
| Claude Code | plugin (above) or paranoid mode | SessionEnd hook | PID + name check | verified live |
| Codex CLI | `adapters/codex/` plugin hooks | none exists upstream - TTL + dead-PID reap | PID + name check | designed |
| Cursor (IDE + CLI) | `adapters/cursor/hooks.json` → `~/.cursor/hooks.json` | sessionEnd hook | **TTL only** (Cursor passes no PID to hooks) | designed |
| GitHub Copilot CLI | `adapters/copilot/awakent.json` → `~/.copilot/hooks/` | sessionEnd hook | PID + name check | verified live (CLI 1.0.68) |
| VS Code Copilot agent mode | same file as Copilot CLI; set `chat.hooks.enabled` (Preview) | none - TTL bound | PID + name check | designed |
| pi | `adapters/pi/awakent.ts` → `~/.pi/agent/extensions/` | session_shutdown event | PID + name check | designed |

"designed" means built against the host's documented hook interface but not yet exercised against a live install (same vocabulary as the power table below); every adapter degrades toward early release, never a stuck wake lock, if a host behaves differently than documented.

The Cursor, Copilot, and pi adapters shell out to the engine at its manual-install location - place it first (the Codex plugin is self-contained and skips this step):

```
git clone https://github.com/codesith/awakent.git && cd awakent
mkdir -p ~/.claude/hooks
cp hooks/awakent.sh ~/.claude/hooks/awakent.sh
chmod 755 ~/.claude/hooks/awakent.sh
```

### Codex CLI

The repo doubles as a Codex plugin (`.codex-plugin/` manifest wiring `adapters/codex/hooks.json`):

```
codex plugin marketplace add https://github.com/codesith/awakent.git
codex plugin install awakent
```

Codex prompts you to trust hooks on first use. It has no SessionEnd event, so release after the last session is TTL-bounded - identical to awakent's crash path. The plugin also ships the `awakent-status` and `awakent-config` skills - ask Codex "show awakent status".

*Remove:* `codex plugin uninstall awakent`.

### Cursor

Copy the hook wiring (⚠️ **merge**, don't overwrite, if `~/.cursor/hooks.json` already exists):

```
cp adapters/cursor/hooks.json ~/.cursor/hooks.json
mkdir -p ~/.cursor/commands
cp adapters/cursor/commands/*.md ~/.cursor/commands/
```

The second copy adds `/awakent-status` and `/awakent-config` as Cursor slash commands. Works in the Cursor IDE and CLI (Cursor ≥ 2.4). Cursor exposes no PID to hooks, so these sessions run in **ttl-only** mode: the wake hold expires `ttl_minutes` after the last activity, with no early release if Cursor is quit and no hook fires. Keep `ttl_minutes` modest if you use this.

*Remove:* delete the awakent entries from `~/.cursor/hooks.json` and `rm ~/.cursor/commands/awakent-*.md`.

### GitHub Copilot

```
mkdir -p ~/.copilot/hooks ~/.copilot/skills
cp adapters/copilot/awakent.json ~/.copilot/hooks/awakent.json
cp -R skills/awakent-status skills/awakent-config ~/.copilot/skills/
```

Works with the Copilot CLI as-is - verified live: register on sessionStart, adoption of an already-running caffeinate, release on sessionEnd, and the skills answer "show awakent status" with the cross-host session list. VS Code's agent mode reads the same hooks file, but its hooks are Preview and lack a session-end event (TTL governs); enable the `chat.hooks.enabled` setting there.

*Remove:* `rm ~/.copilot/hooks/awakent.json && rm -r ~/.copilot/skills/awakent-status ~/.copilot/skills/awakent-config`.

### pi

```
cp adapters/pi/awakent.ts ~/.pi/agent/extensions/awakent.ts
mkdir -p ~/.pi/agent/skills
cp -R skills/awakent-status skills/awakent-config ~/.pi/agent/skills/
```

pi loads TypeScript extensions directly (no build step); the file has zero npm dependencies and only shells out to the engine above. The copied skills give pi the same `awakent-status` / `awakent-config` guidance; the shell fallback below always works too.

*Remove:* `rm ~/.pi/agent/extensions/awakent.ts && rm -r ~/.pi/agent/skills/awakent-status ~/.pi/agent/skills/awakent-config`.

---

Non-macOS note: these hosts run on Linux/Windows too, where the same hooks config may fire. awakent detects a missing `caffeinate` and exits silently writing nothing - safe to ship one dotfiles config everywhere.

The zero-install invariant holds for Codex/Cursor/Copilot (JSON config + the same audited shell script). The pi adapter is one TypeScript file executed by pi's own runtime - no new runtime, but strictly speaking that host's bridge is not pure shell.

## Status

Every host has a status surface, all reading the same registry:

| Host | Status |
| --- | --- |
| Claude Code (plugin) | `/awakent:status` |
| Codex CLI (plugin) | `awakent-status` skill ships with the plugin - ask "show awakent status" |
| Cursor | `/awakent-status` (command files installed above) |
| GitHub Copilot | `awakent-status` skill - ask "show awakent status" (verified live) |
| pi | `awakent-status` skill (folders copied above), or the shell fallback |
| Any terminal / paranoid mode | `bash ~/.claude/hooks/awakent.sh status` |

It reports: whether the wake assertion is held, live sessions with minutes since activity, minutes until TTL release, and the config in effect. Sessions from **all** hosts appear in one list, each labeled with its agent (`host=claude`, `host=copilot`, …); Cursor sessions additionally show `(ttl-only)`. `pmset -g assertions` is the OS's own ground truth if you want to double-check.

## Configuration

Guided editing exists on every host: `/awakent:config` in Claude Code, the `awakent-config` skill in Codex/Copilot/pi ("set awakent ttl to 10 minutes"), `/awakent-config` in Cursor. In Claude Code:

```
/awakent:config                    # show current settings + key reference
/awakent:config ttl_minutes=10    # set one or more key=value pairs
```

Each surface validates input (for example, `ttl_minutes` must be 5-1440), edits the config file for you, and confirms what took effect. The file below remains the single source of truth. The commands are optional convenience, and editing the file directly (the only option in paranoid mode) is fully equivalent.

Optional file `~/.claude/awakent/config` (`key=value` lines, parsed as data, never executed). One config governs every host - the TTL below applies to Claude, Codex, Cursor, Copilot, and pi sessions alike:

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

1. The runtime is two files: `hooks/awakent.sh` and the command markdown. Read them; about 550 lines total. Other-agent adapters add only declarative JSON hook wiring and markdown skill instructions, plus one readable TypeScript file for pi - nothing else executes.
2. `grep -rE 'curl|wget|nc |/dev/tcp' hooks/ commands/ adapters/ skills/` finds nothing. CI fails if a network primitive ever appears.
3. While running: `pmset -g assertions` names the exact `caffeinate` process holding the wake lock.
4. State lives only in `~/.claude/awakent/` (mode 700/600). Config is parsed, never executed.
5. Removal is total: uninstall the plugin, then `rm -rf ~/.claude/awakent` (see below).

## Uninstall

1. Remove whichever pieces you installed (each is independent; skip what you don't have):
   - Claude Code plugin: `claude plugin uninstall awakent@awakent` (or disable it)
   - Claude Code paranoid mode: delete the awakent entries you merged into `~/.claude/settings.json`
   - Codex: `codex plugin uninstall awakent` (or remove the marketplace entry)
   - Cursor: delete the awakent entries from `~/.cursor/hooks.json`; `rm ~/.cursor/commands/awakent-*.md`
   - Copilot: `rm ~/.copilot/hooks/awakent.json`; `rm -r ~/.copilot/skills/awakent-status ~/.copilot/skills/awakent-config`
   - pi: `rm ~/.pi/agent/extensions/awakent.ts` (or `pi remove` if installed as a package); `rm -r ~/.pi/agent/skills/awakent-status ~/.pi/agent/skills/awakent-config`
   - The shared engine copy, once no host uses it: `rm ~/.claude/hooks/awakent.sh`
2. A wake assertion held at that moment is **self-expiring**: `caffeinate` runs with `-t`, so the worst case is one `ttl_minutes` (default 60 min) before the Mac can sleep. Nothing needs to be killed for correctness.
3. Impatient? `pkill caffeinate` releases it immediately.
4. Complete state removal, the only thing awakent ever writes outside the locations above:

```
rm -rf ~/.claude/awakent
```

Note: every host's plugin format currently provides no uninstall hook, so awakent cannot clean up at the moment of uninstall. The `-t` self-expiry above is the designed bound, not a workaround.

## Known limitations

- macOS only (the value *is* `caffeinate`/IOPMAssertion); Linux/Windows out of scope. On those systems the same hooks config no-ops silently.
- Clamshell-on-battery sleep is OS policy; awakent documents it rather than fighting it.
- Plugin slash commands are namespaced (`/awakent:status`); Claude Code doesn't allow bare plugin command names.
- Per-host caveats (Codex has no session-end event; Cursor sessions are TTL-only; VS Code Copilot hooks are Preview) are detailed in [Other agents](#other-agents-codex-cursor-copilot-pi).
- Hosts can hold sessions open without hook activity for long stretches (a single very long agent turn). If that exceeds `ttl_minutes`, the session file is reaped and re-registered on the next event; on hosts with PID tracking the assertion still drops only if no other session is live and no event fires for a full TTL.

## Contributing

PRs welcome within the project's hard constraints: bash 3.2, zero dependencies, no network (see [CONTRIBUTING.md](CONTRIBUTING.md)). DCO sign-off required (`git commit -s`). Security reports: [SECURITY.md](SECURITY.md). Conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Changes: [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 John Xiao

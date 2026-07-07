# Changelog

All notable changes to awakent. Format follows [Keep a Changelog](https://keepachangelog.com/); versioning is semver.

## [Unreleased]

## [0.3.0] - 2026-07-07

Multi-agent support: the same engine now covers OpenAI Codex CLI, Cursor, GitHub Copilot (CLI + VS Code agent mode), and pi, sharing one registry and exactly one caffeinate across all hosts.

### Added
- Host-tagged session files: adapters set `AWAKENT_HOST=<host>`; non-Claude sessions register as `sessions/<host>-<session_id>` (Claude files stay bare - no migration).
- Per-session process pattern (session file line 2): the reaper judges each session by the pattern recorded at its own registration, so a reap triggered from one host can never misjudge another host's PIDs. Legacy one-line files fall back to the global pattern. For the default host the observed parent-process name is recorded, so Claude-hooks-compatible hosts work correctly even without `AWAKENT_HOST`.
- TTL-only sentinel mode (`AWAKENT_SESSION_PID=0`) for hosts that expose no PID to hooks (Cursor): no liveness check, TTL expiry alone governs. Invalid `AWAKENT_SESSION_PID` fails closed to the sentinel.
- Session-id extraction fallbacks: `conversation_id` (Cursor) and `sessionId` (Copilot CLI) accepted after `session_id`.
- Adapters under `adapters/`: Codex plugin hooks (`.codex-plugin/` + `adapters/codex/hooks.json`), Cursor `hooks.json` template, Copilot `awakent.json` (verified live against Copilot CLI 1.0.68), pi TypeScript extension (`adapters/pi/`).
- Full no-op when `caffeinate` is absent: on non-macOS machines sharing a cross-platform hooks config, awakent exits silently and writes zero state.
- Status/config command surfaces for every host: canonical `skills/awakent-status` + `skills/awakent-config` (SKILL.md format; wired into the Codex plugin manifest, copied for Copilot - verified live - and pi), Cursor slash commands (`adapters/cursor/commands/`), with `bash ~/.claude/hooks/awakent.sh status` as the universal shell fallback. Claude Code keeps its native `/awakent:status` and `/awakent:config`.

### Changed
- `status` labels every session with its agent (`host=claude|codex|cursor|copilot|pi`, recorded at registration) and marks sentinel sessions with `(ttl-only)`.

### Fixed
- Registration now writes the session file under the mutex, closing a race where a concurrent reaper could read a session file mid-truncation.
- `pid_name_matches` passes patterns with `grep -E -e`, so a pattern starting with `-` can never be parsed as a grep flag.
- The engine exports `LC_ALL=C` so glob and regex ranges are bytewise everywhere: under en_US.UTF-8 collation, `[a-z]` admits uppercase, which let invalid host tags through on machines with that locale.

## [0.2.0] - 2026-07-06

First public release.

### Added
- `/awakent:config`, a guided config editor: view current settings, set `ttl_minutes` / `lid_closed_mode` / `debug` with validation; the config file remains the single source of truth.

## [0.1.1] - 2026-07-05

### Changed
- Status command renamed to `/awakent:status` (plugin commands are always namespaced as `plugin:command`; the previous name doubled up).

## [0.1.0] - 2026-07-05

### Added
- Core engine: session registry (file-per-session, mtime as activity clock), dead-PID reaper with name-verification recycling guard, TTL expiry with clock-step tolerance, mkdir-mutex concurrency control, caffeinate lifecycle (spawn/adopt/kill, exactly one instance, self-expiring `-t` cap).
- Five-hook wiring (SessionStart, SessionEnd, UserPromptSubmit, PostToolUse, Stop) via the plugin manifest.
- `/awakent:status` command; opt-in debug log (session ids only, 1MB cap); `key=value` config (parsed, never executed).
- Manual-install "paranoid mode" path; test suite + scenario harness; CI gates (shellcheck, bash 3.2 execution, no-network grep, manifest validation).

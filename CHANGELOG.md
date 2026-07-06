# Changelog

All notable changes to awakent. Format follows [Keep a Changelog](https://keepachangelog.com/); versioning is semver.

## [Unreleased]

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

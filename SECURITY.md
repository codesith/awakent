# Security Policy

## What awakent is (threat-model summary)

awakent is two auditable shell files invoking the OS's own `caffeinate`. It makes **no network calls**, collects **no data**, needs **no elevated privileges**, and writes only under `~/.claude/awakent/`. Its config file is parsed as data, never executed. You can verify each claim by reading `hooks/awakent.sh` and grepping the repo. CI enforces the no-network property on every commit.

The security-relevant surfaces are small and deliberate:

- The reaper sends signals only to PIDs it has verified by process name to be `caffeinate`, and never to anything else.
- Hook stdin is parsed with a constrained extractor (one key, restricted charset); malformed input is ignored.
- State files are created mode 600 in a mode 700 directory.

## Supported versions

The latest release. There is no backporting; the project is small enough that upgrading is the fix.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** on this repository (Security tab → "Report a vulnerability"), or email **codesith@gmail.com**. Give a description and reproduction; you'll get an acknowledgment within a few days. Please don't open public issues for suspected vulnerabilities before a fix exists.

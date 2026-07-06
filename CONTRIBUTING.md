# Contributing to awakent

Thanks for your interest! awakent is deliberately tiny (one shell script, two command files, a test suite), and contributions are judged against the constraint that makes it useful: **zero dependencies beyond macOS built-ins, bash 3.2 only**.

## Ground rules

- **bash 3.2** (`/bin/bash` on macOS): no associative arrays, no `${var,,}`, no `mapfile`, no `flock`. CI executes the suite under `/bin/bash`, so 4.x-isms fail the build.
- **shellcheck-clean** at `--severity=warning`. CI enforces it.
- **No network primitives** in `hooks/` or `commands/`. CI greps for them and fails on any hit. This is the project's core trust promise; it is not negotiable.
- **Hooks stay silent:** nothing in a hook path may write to stdout or exit non-zero (`status` output is the sole exception). A broken awakent must never break Claude Code.
- **Config is data:** the config file is parsed, never sourced or eval'd.
- Every behavior change comes with tests. Run the suite before opening a PR:

```
/bin/bash tests/run.sh
```

## Developer Certificate of Origin (DCO)

Contributions require a DCO sign-off: certify you have the right to submit the code by adding a `Signed-off-by` line:

```
git commit -s
```

By signing off you agree to the [Developer Certificate of Origin](https://developercertificate.org/). Unsigned commits can't be merged.

## Versioning

Semver: **patch** = fixes; **minor** = new config keys or behavior; **major** = changes to the hook set or the on-disk state protocol.

## Scope

awakent is macOS-only and Claude Code-only by design, and will never grow a UI, a runtime dependency, or a network call. PRs adding those will be declined kindly; it's the point of the project, not an oversight.

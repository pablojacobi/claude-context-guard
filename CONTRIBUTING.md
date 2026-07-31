# Contributing

Thanks for looking. This project is small on purpose: a settings key, four hooks, and the
evidence that they behave. Bug reports and host/OS compatibility reports are as valuable as
code — see the [issue templates](.github/ISSUE_TEMPLATE/).

## Run the suite

Everything runs locally, in a throwaway sandbox. No network, no daemons, and it never touches
your real `logs/`, `state/` or `night/`:

```sh
tests/run-tests.sh        # simulated hook events, throwaway CG_HOME + throwaway git repo
tests/threshold-math.sh   # canary on the autoCompactWindow formula
shellcheck -S warning -x install.sh uninstall.sh bin/*.sh tests/*.sh
```

`run-tests.sh` prints one line per assertion and a final tally; a non-zero exit means at least
one assertion failed. Both suites need `jq` (`brew install jq` / `apt install jq`) and `bash`.
CI runs exactly these three commands, so a green local run is a good predictor.

If you change installer behaviour, also exercise `install.sh` against a fake `HOME` — CI does
this in the *clone-anywhere install smoke* step, and it is the only step that writes a
`settings.json`. Never test the installer against your own `~/.claude/settings.json`.

## Script style

- `#!/usr/bin/env bash`, then `set -uo pipefail`. **Not** `set -e`: a hook that aborts
  mid-way is worse than one that degrades, and the suite relies on non-zero commands not
  killing the run.
- **Hooks fail open, always.** Anything under `bin/` that Claude Code invokes must exit `0`
  even when `jq` is missing, the payload is malformed, or a path does not exist. Instrumentation
  must never block a compaction, stall a turn, or corrupt a session. Helpers in
  [`bin/lib.sh`](bin/lib.sh) follow the same rule: return 0, degrade to an empty value.
- **`bin/pre-compact.sh` stdout is the compaction's custom instructions.** Only the preservation
  contract goes there — a stray `echo` contaminates what the summariser receives. All logging
  goes to the log file.
- Quote expansions, prefer `[ ]` over `[[ ]]`, and keep `CG_HOME` / `CG_JQ` overridable so the
  suite can run against a sandbox.
- Keep it POSIX-ish and portable: it has to run on macOS bash 3.2 *and* Linux bash 5.x. No
  GNU-only flags (`sed -i` without a suffix, `date -d`, `readlink -f`).
- shellcheck at `-S warning` must be clean. If a warning is genuinely wrong, disable it inline
  with a one-line reason, as the existing code does.
- New behaviour comes with an assertion in `tests/run-tests.sh`. A test that cannot fail without
  the fix is not a test — check it goes red before you make it green.

## Pull requests

`main` is protected. Every change — including docs — goes through a PR with CI green:

1. Branch from `main`, one topic per branch.
2. Run the three commands above locally.
3. Open the PR with a short description of the behaviour change and how you verified it.
   Numbers (token counts, deviations, assertion counts) should say where they came from.
4. All three CI checks must pass: `lint`, `test (ubuntu-latest)`, `test (macos-latest)`.

Commit messages follow the existing log: `type(scope): imperative summary` (`fix(velador): …`,
`docs: …`). Update `CHANGELOG.md` when the change is user-visible, and keep
[`README.es.md`](README.es.md) in sync when you edit [`README.md`](README.md) — the English one
is canonical.
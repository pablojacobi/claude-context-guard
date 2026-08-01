# Changelog

## Unreleased

- Velador status updated after its first live run: 50+ sustained re-injections on a real
  merge campaign, session-bound claim holding, clean model-driven close. Budget/stall cuts
  remain test-suite-only.
- Documented that the skill trigger is best-effort (verify via `night/request.md`) and that
  irreversible-action bans belong in `permissions.deny`, not prose (#5).
- Dropped `README.es.md`: a single canonical English README beats a translation that drifts.

## v0.0.2 — 2026-07-31

- **Fix: bind autonomous-run requests to their session.** The velador request
  now carries the owner's `CLAUDE_CODE_SESSION_ID` and the `Stop` hook claims
  it only on an exact session match — the cwd fallback remains for hand-written
  requests. Found live on day one: two sessions sharing a checkout are
  indistinguishable by cwd, and a bystander session claimed the premiere run's
  request at its own turn end.
- Test suite: 49 → 51 assertions (bystander-cannot-claim + owner-claims).

## v0.0.1 — 2026-07-31

Initial public release. Extracted from a private install after live validation:

- `autoCompactWindow: 473000` calibrated against **measured** production behavior
  (the reactive `window − 33,000` term rules, not the binary's `× 0.8` formula):
  12 automatic compactions landed at 435,080–440,004 tokens (target 440K).
- Preservation contract via `PreCompact` stdout, applied in 18/19 real summaries.
- JSONL evidence log with per-session isolation.
- Always-on deterministic handoffs + stall detection (git + filesystem signals).
- `velador` skill for autonomous runs — **experimental**, not yet validated live.
- 49-assertion test suite over simulated events; formula canary; install/uninstall
  round-trip proven byte-identical.
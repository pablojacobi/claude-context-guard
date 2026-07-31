# Changelog

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
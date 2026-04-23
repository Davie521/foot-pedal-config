# Progress Log

## 2026-04-23 — Diagnosis session

### 00:5x — Initial report & context gathering
- User: "踩下去之后，一秒钟就断连了" (pedal disconnects after ~1s).
- Verified Hammerspoon running (pid 961), Karabiner daemons running, eventtap `isEnabled() == true`.
- No errors in `hs.console`, no `WATCHDOG` or `LIFECYCLE` events.
- Confirmed installed `~/.hammerspoon/init.lua` matches the repo's `init.lua` exactly (diff empty).

### 00:52 — Instrumented debug logging
- Added `[DEBUG]` prints to `keyDown` / `keyUp` handlers and to `sendMouseDown` in `~/.hammerspoon/init.lua`.
- Called `hs.reload()`.

### 00:54 — Re-test with debug logging
- User held pedal ~4s. PTT stayed active the whole time. 8 `sendMouseDown` keepalives fired at 0.5s cadence.
- Pedal firmware behavior confirmed normal: `keyDown (repeat=0)` → many `keyDown (repeat=1)` autorepeats → exactly one `keyUp` on release.

### 00:56 — Initial (wrong) analysis
- Hypothesized sleep/wake lifecycle gap not covered by `F19SleepWatcher`.
- User asked for deeper analysis.

### 00:57 — Corrected analysis
- Re-read console buffer. System uptime only 20 min. No lifecycle events. Hypothesis rejected.
- Spotted `"Loading extension: mouse"` line at 00:48:17 — right when user first tested.
- New hypothesis: lazy-load of `hs.mouse` during first `sendMouseDown` delayed the keepalive past Wispr Flow's tolerance window.
- Documented in `findings.md`.

### 00:58 — Plan drafted
- Created `task_plan.md` with 3 phases: primary eager-load fix, optional health-check watchdog, cleanup/verify.
- Awaiting user approval before implementing.

### 01:00 — All three phases shipped
- User approved Phase 1 + Phase 2, and asked to keep debug logging behind a flag.
- Rewrote `init.lua` with:
  - `local DEBUG = false` flag and `dbg(...)` no-op wrapper.
  - `require("hs.mouse")` + other extensions eager-loaded at config top; `hs.mouse.absolutePosition()` called once to force any first-call work.
  - Two new module-level vars: `lastKeepaliveTs`, `keepaliveCount`; `sendMouseDown` now timestamps every fire.
  - `F19Watchdog` extended: if `pttActive` is true and `now - lastKeepaliveTs > 1.0s`, log and `hs.reload()`.
- Copied to `~/.hammerspoon/init.lua`, ran `hs.reload()`.
- Verified in `hs.console`: `"Loading extension: mouse"` now appears at **01:00:39 during config load**, not on first press — confirms eager-load is effective.
- `F19Tap:isEnabled() == true`.

### Next steps
- User to run the P3.3 manual verification (cold restart + 5s hold).
- Optionally update `README.md` / `docs/` to mention eager-load and keepalive watchdog (P3.4).

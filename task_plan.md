# Task Plan — Prevent 1-second PTT disconnect on first pedal press

**Goal:** Make sure the "first press after Hammerspoon startup drops after 1s" bug cannot recur.
**Root cause (per findings.md):** Lazy-load of `hs.mouse` extension happens synchronously inside the first `sendMouseDown`, delaying the first keepalive past Wispr Flow's tolerance window.

---

## Phase 1 — Primary fix: eliminate lazy-load stutter

**Status:** ✅ Done (2026-04-23 01:00).

### P1.1 — Eager-load `hs.mouse` at config top
Add `hs.mouse.absolutePosition()` (or `require("hs.mouse")`) near the top of `init.lua`, before any eventtap or timer setup. Forces the dyld/init/compile to happen during Hammerspoon startup, not during the first PTT activation.

Optionally also eager-load:
- `hs.eventtap` (already used at top level, probably already warm)
- `hs.timer` (same)
- `hs.caffeinate.watcher` (same)

**Rationale:** One-line change, zero runtime cost at press time, removes the entire class of "first-use latency" bugs.

### P1.2 — Cache the event template (optional micro-optimization)
`sendMouseDown` currently re-allocates an `hs.eventtap.event.newMouseEvent(...)` every call. For keepalive we could cache the event and re-post, but `otherMouseDown` events need fresh click-state and modern macOS may not accept re-posting the exact same CGEvent. **Skip unless we see further latency.**

---

## Phase 2 — Defense in depth: keepalive health check

**Status:** ✅ Done (2026-04-23 01:00). Watchdog now also reloads on keepalive stall >1s.

### P2.1 — Record last keepalive fire time
Have `sendMouseDown` write `lastKeepaliveTs = hs.timer.secondsSinceEpoch()`.

### P2.2 — Extend `F19Watchdog` to verify keepalive
Every 5s (existing cadence), if `pttActive` is true AND `hs.timer.secondsSinceEpoch() - lastKeepaliveTs > 1.0`, log a warning and force `hs.reload()`. This catches *any* future cause of keepalive starvation, not just lazy-load.

**Rationale:** Layered defense. If some unknown future failure mode kills the timer again (GC, OS throttling, unforeseen lifecycle event), the watchdog self-heals within one watchdog tick.

**Trade-off:** `hs.reload()` mid-press would drop the in-flight PTT. That's the same UX as the current bug, so net-positive. If user wants gentler recovery, we can attempt to re-arm `pttKeepAlive` first and only reload if that fails.

---

## Phase 3 — Cleanup & verify

**Status:** Pending Phase 1/2 decisions.

### P3.1 — Debug logging behind a flag
✅ Done. `local DEBUG = false` at top of `init.lua`. All `[DEBUG]` prints now go through `dbg(...)` which is a no-op when DEBUG is false. To diagnose in the future: set `DEBUG = true`, `hs -c 'hs.reload()'`, tail `hs.console`.

### P3.2 — Sync repo ↔ installed
✅ Done. `cp` + `hs -c 'hs.reload()'` applied. Console confirms `"Loading extension: mouse"` now happens at 01:00:39 during config load (eager), not on first press.

### P3.3 — Manual verification protocol
1. Quit Hammerspoon entirely (so `hs.mouse` is truly unloaded).
2. Relaunch Hammerspoon.
3. Wait 10 minutes (mimic the idle window that preceded the original failure).
4. Hold pedal for 5 seconds. Should stay active for the full 5s.
5. Release, tap once (Enter). Should type a newline.
6. Hold again. Should still work.

### P3.4 — Update docs
`README.md` / `docs/` mention first-press reliability. Add a one-line note about eager-loading extensions being a requirement for reliable keepalive.

---

## Decisions log

- **2026-04-23 — Ruled out sleep/wake as root cause.** Earlier in this session I blamed stale state after a lifecycle event. Console log shows no lifecycle events, uptime only 20 min. Revised to lazy-load hypothesis.
- **2026-04-23 — Ruled out generic high system load.** Successful run happened under equally high load.
- **Pending — Phase 2 scope.** Whether to add keepalive health check or rely solely on Phase 1 eager-load fix.

---

## Resolved decisions

1. **Phase 1 (eager-load):** Approved + shipped.
2. **Phase 2 (health-check watchdog):** Approved + shipped.
3. **Debug logging:** Kept behind `local DEBUG = false` flag, default off.

## Remaining

- **P3.3 manual verification.** User should:
  1. Fully quit Hammerspoon (right-click menu bar icon → Quit).
  2. Relaunch it.
  3. Wait ≥1 minute idle.
  4. Hold pedal 5 seconds → PTT should stay on for the full 5s.
  5. Tap pedal → should type a newline.
- **P3.4 update docs.** Note in README/docs that the config now eager-loads `hs.mouse` and watchdog monitors keepalive liveness.

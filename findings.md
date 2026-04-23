# Findings — 1-second PTT disconnect on first pedal press

## Timeline reconstructed from `hs.console` buffer

| Time | Event |
|------|-------|
| 00:37 (~) | System boot (`uptime` 20 min at 00:57) |
| 00:38:10 | Hammerspoon loads `init.lua`; extensions loaded: `eventtap`, `timer`, `caffeinate`, `alert`. **`hs.mouse` NOT loaded yet** (lazy loading enabled). |
| ~00:38 – 00:48 | Idle. No pedal use, no LIFECYCLE events, no WATCHDOG events. |
| 00:48:17 | **First pedal hold.** `hs.mouse` extension loads here — this is triggered by the very first call to `hs.mouse.absolutePosition()` inside `sendMouseDown`. User reports PTT "disconnected after ~1 second" around this time. |
| 00:52:13 | `hs.console` extension loads (triggered by my `hs -c 'return hs.console…'` query). |
| 00:52:48 | I call `hs.reload()` after adding debug logging. This wipes and re-creates all timers, eventtaps, and closures. |
| 00:54:23 – 00:54:27 | Second pedal hold, ~4s, **no disconnect.** 8 `sendMouseDown` keepalives fire at 0.5s cadence exactly as designed. `keyDown (repeat=1)` autorepeats arrive ~6/sec from pedal firmware. |

## What was ruled out

- **Sleep/wake / lifecycle state drift.** Zero `LIFECYCLE` log lines; system uptime only 20 min; `F19SleepWatcher` never fired. The caffeinate coverage hypothesis from the prior answer does **not** fit the evidence.
- **Eventtap disabled by macOS.** `F19Tap:isEnabled()` was `true`; no `WATCHDOG: eventtap restarted` lines.
- **Pedal firmware misbehavior.** The post-reload log shows clean behavior: one `keyDown (repeat=0)` → many `keyDown (repeat=1)` autorepeats → exactly one `keyUp` on release. Pedal is healthy.
- **Keepalive logic wrong.** Post-reload log proves the 0.5s cadence works perfectly; 8 fires across 4s.

## Most likely root cause: **lazy-load stutter on first PTT activation**

Hammerspoon has "Lazy extension loading enabled" (visible in the console on boot). `hs.mouse` is not in the top-level `init.lua`, so it is only loaded the **first time** any `hs.mouse.*` function is called. The first such call was inside `sendMouseDown()` at `00:48:17`.

Lazy-loading a Hammerspoon extension is **synchronous on the Lua main thread**. While it's loading, all other Lua callbacks (including already-scheduled `hs.timer` callbacks) are blocked. In `init.lua:35-38`:

```lua
local function pressPTT()
    sendMouseDown()                                       -- (A) first call triggers hs.mouse lazy load
    pttKeepAlive = hs.timer.doEvery(PTT_KEEPALIVE, sendMouseDown)  -- (B) scheduled after (A) returns
end
```

On first activation:
1. `sendMouseDown()` is called. Inside, `hs.mouse.absolutePosition()` runs — **but the `hs.mouse` module must be loaded first**. This is a synchronous disk I/O + Lua compile + init. Under the heavy load this machine was seeing (`load averages: 24 / 65 / 83`), this could easily take several hundred ms or more.
2. After the load completes, `sendMouseDown` finishes posting the first `otherMouseDown`.
3. `hs.timer.doEvery(0.5, ...)` schedules the next fire **0.5s after step 2 completes**.

The total gap between the user physically passing the hold threshold and the *second* mouseDown can easily exceed 1 second if the lazy load is slow. Wispr Flow's PTT detector only sees the original synthetic `otherMouseDown`; if it doesn't get a refresh within its internal debounce window (apparently ~1s), it treats the button as released.

Supporting evidence:
- The `"-- Loading extension: mouse"` console line at `00:48:17` is synchronous and coincides exactly with the reported failure.
- After the `hs.reload()` at `00:52:48`, `hs.mouse` stayed loaded through the reload (extension lifetime ≠ config lifetime). At `00:54:23` the extension reload line appears again (Hammerspoon re-logs it on reload), but the actual dyld/native work was already done, so the latency was negligible — and that run worked flawlessly.
- The symptom "exactly after about 1 second" matches the expected ~0.5s keepalive interval + Wispr Flow's tolerance window, with the first keepalive delayed.

## Alternative hypotheses (lower probability)

- **H2: High system load starved the timer on first fire.** Plausible, but the successful run also happened under the same high load (load averages barely changed between 00:48 and 00:54). If it were generic load-induced jitter, the second test would have failed too. *Rejected as primary.*
- **H3: Wispr Flow treats the very first synthetic click differently from subsequent ones.** Possible, but we'd see it on every cold start, not just the first press after Hammerspoon boot. *Cannot rule out, low probability.*
- **H4: Lua GC of `pttKeepAlive` timer reference.** The timer is held as an upvalue in the module chunk, which is reachable via the `F19Tap` global closure. Not a GC risk under normal Lua semantics. *Rejected.*

## Secondary issue observed

The `F19Watchdog` only checks `F19Tap:isEnabled()`. It has no visibility into whether the keepalive timer is healthy or whether downstream event delivery is working. This is a general weakness — if any future bug makes PTT fail *without* disabling the tap, the watchdog won't help.

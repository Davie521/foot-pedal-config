require("hs.ipc") -- enables `hs` CLI for remote reload

-------------------------------------------------------
-- F19 foot pedal: tap → Enter, hold → Mouse Button 4
-- (for Wispr Flow Push-to-Talk)
--
-- Synthetic otherMouseDown doesn't update persistent
-- system button state, so we re-send periodically
-- (keep-alive) to maintain the "button held" illusion.
--
-- ALL persistent objects MUST be global to prevent
-- Lua garbage collection from silently destroying them.
-------------------------------------------------------
local DEBUG = false          -- flip to true to log every press/keepalive to hs.console
local HOLD_THRESHOLD = 0.225 -- seconds before activating PTT
local MAX_HOLD = 120         -- seconds: safety auto-release
local F19_KEYCODE = 80       -- macOS virtual keycode for F19
local MOUSE_BUTTON = 3       -- 0-indexed: button4
local PTT_KEEPALIVE = 0.5    -- seconds: re-send interval
local KEEPALIVE_STALL = 1.0  -- seconds: treat as stalled if no fire within this window

-- Eager-load lazy extensions. Without this, the very first sendMouseDown call
-- triggers a synchronous dyld+init of hs.mouse on the Lua main thread, which
-- can delay the first keepalive past Wispr Flow's ~1s tolerance and cause the
-- first PTT press after Hammerspoon startup to drop.
require("hs.mouse")
require("hs.eventtap")
require("hs.timer")
require("hs.caffeinate")
hs.mouse.absolutePosition() -- force any JIT/first-call work to happen now

local f19Down = false
local pttActive = false
local holdTimer = nil
local safetyTimer = nil
local pttKeepAlive = nil
local lastKeepaliveTs = 0
local keepaliveCount = 0

local function dbg(fmt, ...)
    if DEBUG then hs.printf("[DEBUG] " .. fmt, ...) end
end

local function sendMouseDown()
    keepaliveCount = keepaliveCount + 1
    lastKeepaliveTs = hs.timer.secondsSinceEpoch()
    dbg("sendMouseDown #%d", keepaliveCount)
    local pos = hs.mouse.absolutePosition()
    local e = hs.eventtap.event.newMouseEvent(
        hs.eventtap.event.types.otherMouseDown, pos)
    e:setProperty(hs.eventtap.event.properties.mouseEventButtonNumber, MOUSE_BUTTON)
    e:setProperty(hs.eventtap.event.properties.mouseEventClickState, 1)
    e:post()
end

local function pressPTT()
    sendMouseDown()
    pttKeepAlive = hs.timer.doEvery(PTT_KEEPALIVE, sendMouseDown)
end

local function releasePTT()
    if pttKeepAlive then
        pttKeepAlive:stop()
        pttKeepAlive = nil
    end
    local pos = hs.mouse.absolutePosition()
    local e = hs.eventtap.event.newMouseEvent(
        hs.eventtap.event.types.otherMouseUp, pos)
    e:setProperty(hs.eventtap.event.properties.mouseEventButtonNumber, MOUSE_BUTTON)
    e:post()
end

local function cancelTimers()
    if holdTimer then holdTimer:stop(); holdTimer = nil end
    if safetyTimer then safetyTimer:stop(); safetyTimer = nil end
    if pttKeepAlive then pttKeepAlive:stop(); pttKeepAlive = nil end
end

local function cleanup()
    cancelTimers()
    if pttActive then releasePTT(); pttActive = false end
    f19Down = false
end

-- GLOBAL: prevents garbage collection
F19Tap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
    function(event)
        if event:getKeyCode() ~= F19_KEYCODE then return false end

        if event:getType() == hs.eventtap.event.types.keyDown then
            dbg("F19 keyDown (repeat=%s)", tostring(event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)))
            if f19Down then return true end
            f19Down = true

            holdTimer = hs.timer.doAfter(HOLD_THRESHOLD, function()
                holdTimer = nil
                pttActive = true
                dbg("PTT activated")
                pressPTT()
                safetyTimer = hs.timer.doAfter(MAX_HOLD, function()
                    safetyTimer = nil
                    if pttActive then cleanup() end
                end)
            end)

            return true

        elseif event:getType() == hs.eventtap.event.types.keyUp then
            dbg("F19 keyUp (pttActive=%s)", tostring(pttActive))
            if not f19Down then return true end
            f19Down = false
            cancelTimers()

            if pttActive then
                releasePTT()
                pttActive = false
            else
                hs.eventtap.event.newKeyEvent({}, "return", true):post()
                hs.timer.usleep(1000)
                hs.eventtap.event.newKeyEvent({}, "return", false):post()
            end

            return true
        end

        return false
    end
):start()

-- GLOBAL watchdog: every 5s verify
--   (1) the eventtap hasn't been disabled by macOS, and
--   (2) if PTT is active, the keepalive timer actually fired recently.
-- Catches both the classic "eventtap auto-disable" case and any future
-- failure mode (GC, lifecycle event, lazy-load stall) that silently stops
-- the keepalive while leaving the tap enabled.
F19Watchdog = hs.timer.doEvery(5, function()
    if F19Tap and not F19Tap:isEnabled() then
        F19Tap:stop():start()
        hs.printf("WATCHDOG: eventtap restarted")
    end
    if pttActive and (hs.timer.secondsSinceEpoch() - lastKeepaliveTs) > KEEPALIVE_STALL then
        hs.printf("WATCHDOG: keepalive stalled (last fire %.2fs ago) — reloading",
            hs.timer.secondsSinceEpoch() - lastKeepaliveTs)
        cleanup()
        hs.reload()
    end
end)

-- GLOBAL: full reload on system state changes that can zombify eventtaps/timers.
-- Covers: system sleep, display sleep, screen lock, fast user switching.
-- Multiple rapid events naturally debounce: first hs.reload() destroys all
-- pending timers, so only one reload actually happens.
F19SleepWatcher = hs.caffeinate.watcher.new(function(event)
    local reloadEvents = {
        [hs.caffeinate.watcher.systemDidWake]          = "systemDidWake",
        [hs.caffeinate.watcher.screensDidWake]         = "screensDidWake",
        [hs.caffeinate.watcher.sessionDidBecomeActive] = "sessionDidBecomeActive",
        [hs.caffeinate.watcher.screensDidUnlock]       = "screensDidUnlock",
    }
    local name = reloadEvents[event]
    if name then
        hs.printf("LIFECYCLE [%s]: scheduling reload in 2s", name)
        hs.timer.doAfter(2, function()
            cleanup()
            hs.reload()
        end)
    end
end):start()

hs.shutdownCallback = function()
    cleanup()
    if F19Watchdog then F19Watchdog:stop() end
    if F19SleepWatcher then F19SleepWatcher:stop() end
end

hs.alert.show("Foot pedal ready")

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
local HOLD_THRESHOLD = 0.225 -- seconds before activating PTT
local MAX_HOLD = 120         -- seconds: safety auto-release
local F19_KEYCODE = 80       -- macOS virtual keycode for F19
local MOUSE_BUTTON = 3       -- 0-indexed: button4
local PTT_KEEPALIVE = 0.5    -- seconds: re-send interval

local f19Down = false
local pttActive = false
local holdTimer = nil
local safetyTimer = nil
local pttKeepAlive = nil

local function sendMouseDown()
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
            if f19Down then return true end
            f19Down = true

            holdTimer = hs.timer.doAfter(HOLD_THRESHOLD, function()
                holdTimer = nil
                pttActive = true
                pressPTT()
                safetyTimer = hs.timer.doAfter(MAX_HOLD, function()
                    safetyTimer = nil
                    if pttActive then cleanup() end
                end)
            end)

            return true

        elseif event:getType() == hs.eventtap.event.types.keyUp then
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

-- GLOBAL watchdog: restart eventtap if macOS disables it
F19Watchdog = hs.timer.doEvery(5, function()
    if F19Tap and not F19Tap:isEnabled() then
        F19Tap:stop():start()
        hs.printf("WATCHDOG: eventtap restarted")
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

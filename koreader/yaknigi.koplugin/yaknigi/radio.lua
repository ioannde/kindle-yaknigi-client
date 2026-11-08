-- Airplane mode and Wi-Fi, as the Kindle's own panel has them. Airplane mode is the system's
-- switch of all radios; Wi-Fi is one of them. KOReader turns Wi-Fi off with the main switch
-- as well, so after it the main switch is turned back on, and only Wi-Fi stays off.
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Radio = {}

-- Without the Kindle's lipc (the emulator, tests) the switch is only remembered.
local pretend_off = false

local function with_lipc(work)
    local ok, lipc = pcall(require, "liblipclua")
    if not ok or not lipc then return nil, false end
    local handle = lipc.init("com.github.koreader.yaknigi")
    if not handle then return nil, false end
    local done, result = pcall(work, handle)
    handle:close()
    if not done then logger.warn("yaknigi: lipc:", result) end
    return done and result, true
end

local function set_radios(on)
    local _, has = with_lipc(function(handle)
        handle:set_int_property("com.lab126.cmd", "wirelessEnable", on and 1 or 0)
    end)
    if not has then pretend_off = not on end
end

function Radio.airplane()
    local value, has = with_lipc(function(handle)
        return handle:get_int_property("com.lab126.cmd", "wirelessEnable")
    end)
    if not has then return pretend_off end
    return value == 0
end

function Radio.wifi()
    return NetworkMgr:isWifiOn() and true or false
end

--- done() once the change has gone through, or as far as can be seen.
function Radio.setWifi(on, done)
    if on then
        set_radios(true)
        NetworkMgr:toggleWifiOn(done, nil, true)
    else
        NetworkMgr:toggleWifiOff(function()
            set_radios(true)
            if done then done() end
        end)
    end
end

function Radio.setAirplane(on, done)
    if not on then
        Radio.setWifi(true, done)
    elseif Radio.wifi() then
        NetworkMgr:toggleWifiOff(function()
            set_radios(false)
            if done then done() end
        end)
    else
        set_radios(false)
        if done then UIManager:nextTick(done) end
    end
end

return Radio

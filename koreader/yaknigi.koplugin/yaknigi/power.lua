-- The way out, from the top of the settings: leave the app (in someone's own KOReader, the
-- library), put the device to sleep, or turn it off. Neither of the last two is KOReader's on a Kindle: it has no way to power off there.
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")

local Kit = require("yaknigi/kit")

local Power = {}


--- The button for a corner of the header: the drawing stands as far from the edge as the text.
function Power.button(height, callback)
    local icon = Kit.px(30)
    return Kit.button(Kit.icon("power", icon),
        icon + 2 * Kit.px(16), height, callback)
end

--- Saves what there is to save and turns the device off, the picture of the book left on it.
function Power.off()
    if Device:supportsScreensaver() then
        local Screensaver = require("ui/screensaver")
        Screensaver:setup("poweroff")
        Screensaver:show()
        UIManager:forceRePaint()
    end
    UIManager:broadcastEvent(Event:new("Close", { keep_screensaver = true }))
    G_reader_settings:flush()
    os.execute("sync; shutdown -P now || poweroff")
    -- The system is on its way down. Ending now would start the Kindle's own screens meanwhile;
    -- should it fail to go down at all, this is the wait before it comes back to them.
    os.execute("sleep 30")
    UIManager:quit()
end

--- all: also what this device has no use for. app: the app, not someone's own KOReader, which
-- has a way out of its own and turns the device off itself. Returns the dialog.
function Power.show(on_close_app, all, app)
    local dialog
    local function item(id, text, action)
        return { {
            id = id,
            text = text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(action)
            end,
        } }
    end
    local buttons = { item("exit", app and "Выйти из приложения" or "Вернуться в KOReader", on_close_app) }
    if all or Device:canSuspend() then
        buttons[#buttons + 1] = item("sleep", "Сон", function() UIManager:suspend() end)
    end
    if all or app and Device:isKindle() then
        buttons[#buttons + 1] = item("off", "Выключить устройство", function() Power.off() end)
    end
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
    return dialog
end

return Power

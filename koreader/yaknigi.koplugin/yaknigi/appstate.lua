-- What must outlive a new version of KOReader's settings seed: run.sh replaces those wholesale,
-- and neither an acceptance of the terms nor an opt-out of updates may go with them.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

return LuaSettings:open(DataStorage:getSettingsDir() .. "/yaknigi_app.lua")

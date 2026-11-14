-- The launcher's files travel with the plugin, so that an update brings them too: a release puts
-- its copies into the plugin's launcher folder, and a start puts any that differ in place.
-- What changed in them works from the next start from KUAL or the scriptlet.
local Launcher = {}

-- In this order, and none after one that failed: a new seed with the run.sh before 0.9.10 would
-- replace the reader's settings, where the new run.sh only brings in what the seed changed.
Launcher.FILES = { "seed.lua", "apply-update.sh", "run.sh", "settings.reader.lua" }

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/yaknigi/[^/]*$") or "."
Launcher.SOURCE = HERE .. "/launcher"

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

--- Puts each file of from that differs into to, whole or not at all. Returns the names put.
function Launcher.install(from, to)
    local put = {}
    for _, name in ipairs(Launcher.FILES) do
        local text = read(from .. "/" .. name)
        if text and text ~= "" and text ~= read(to .. "/" .. name) then
            local path = to .. "/" .. name
            local f = io.open(path .. ".new", "wb")
            local ok = f and f:write(text) and f:close()
            -- A rename never leaves half a file, even of the run.sh that started this.
            if ok and os.rename(path .. ".new", path) then
                put[#put + 1] = name
            else
                if f then pcall(f.close, f) end
                os.remove(path .. ".new")
                break
            end
        end
    end
    if #put > 0 then os.execute("sync") end
    return put
end

return Launcher

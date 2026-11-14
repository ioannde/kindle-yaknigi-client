-- Brings a new version of the settings seed into KOReader's settings: only what the seed itself
-- changed since the version before, so that nothing the reader has chosen goes with it.
-- luajit seed.lua <new seed> <seed before, may be missing> <KOReader's settings>
local new_path, old_path, settings_path = arg[1], arg[2], arg[3]

local function load(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local chunk = loadstring(text)
    if not chunk then return nil end
    setfenv(chunk, {})
    local ok, value = pcall(chunk)
    return ok and type(value) == "table" and value or nil
end

local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

--- What changed between old and new goes into settings; inside a table, key by key.
local function merge(settings, new, old)
    for k, v in pairs(new) do
        local was = old and old[k]
        if not same(v, was) then
            if type(v) == "table" and type(was) == "table" and type(settings[k]) == "table" then
                merge(settings[k], v, was)
            else
                settings[k] = copy(v)
            end
        end
    end
end

local function key_text(k)
    if type(k) == "string" then return ("[%q]"):format(k) end
    return "[" .. tostring(k) .. "]"
end

local function value_text(v, indent)
    local kind = type(v)
    if kind == "string" then return ("%q"):format(v) end
    if kind == "number" then
        return v == math.floor(v) and v < 2^53 and v > -2^53 and ("%d"):format(v) or ("%.17g"):format(v)
    end
    if kind == "boolean" then return tostring(v) end
    if kind ~= "table" then error("cannot keep a " .. kind) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local inner = indent .. "    "
    local lines = { "{" }
    for _, k in ipairs(keys) do
        lines[#lines + 1] = inner .. key_text(k) .. " = " .. value_text(v[k], inner) .. ","
    end
    lines[#lines + 1] = indent .. "}"
    return table.concat(lines, "\n")
end

local new = load(new_path)
if not new then os.exit(1) end
local settings = load(settings_path)
if settings then
    merge(settings, new, load(old_path))
else
    settings = new
end

local f = assert(io.open(settings_path .. ".new", "wb"))
assert(f:write("-- ", settings_path, "\nreturn ", value_text(settings, ""), "\n"))
assert(f:close())
assert(os.rename(settings_path .. ".new", settings_path))

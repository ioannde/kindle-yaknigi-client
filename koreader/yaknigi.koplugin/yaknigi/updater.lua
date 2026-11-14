-- New versions of the plugin, from the project's releases on GitHub.
--
-- The check and, once the user agrees, the download run in forked processes and only prepare
-- update/pending. The launcher's apply-update.sh puts it in place at a start, and takes it back
-- if that start fails.
local Http = require("yaknigi/http")

local Updater = {}

Updater.RELEASES = os.getenv("YB_UPDATE_URL")
    or "https://github.com/ioannde/kindle-yaknigi-client/releases/latest/download"
Updater.ARCHIVE = "yaknigi-update.tar"
Updater.DAY = 24 * 60 * 60
local MAX_REDIRECTS = 5
-- Where GitHub sends a download. Nothing else is asked for code to run.
local HOST_SUFFIXES = { "github.com", "githubusercontent.com" }

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."

local function read_line(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    text = text:gsub("%s+$", "")
    return text ~= "" and text or nil
end
Updater.read_line = read_line

--- The build's version; written by the release build, and "dev" in any other.
function Updater.version()
    return os.getenv("YB_VERSION") or read_line(HERE .. "/VERSION") or "dev"
end

--- What a new version needs from outside the plugin: the KOReader it came with. (The launcher's
-- files come with the plugin since 0.9.11; before that their digest was a part of it.)
function Updater.base()
    return os.getenv("YB_BASE") or read_line(HERE .. "/BASE") or "dev"
end

--- A build from a branch has no place among the releases, and only the launcher can install.
function Updater.enabled()
    return Updater.version():match("^%d+%.%d+%.%d+$") ~= nil and os.getenv("YAKNIGI_DIR") ~= nil
end

--- A release put into someone's own KOReader: it can only say that a new one is out.
function Updater.notify_only()
    return Updater.version():match("^%d+%.%d+%.%d+$") ~= nil and os.getenv("YAKNIGI_DIR") == nil
end

--- Whether new versions are looked for at all.
function Updater.checks()
    return Updater.enabled() or Updater.notify_only()
end

--- Whether version a is later than version b.
function Updater.newer(a, b)
    local x, y = {}, {}
    for n in tostring(a):gmatch("%d+") do x[#x + 1] = tonumber(n) end
    for n in tostring(b):gmatch("%d+") do y[#y + 1] = tonumber(n) end
    for i = 1, 3 do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

--- The manifest of a release, if it is one.
function Updater.valid_manifest(m)
    return type(m) == "table"
        and type(m.version) == "string" and m.version:match("^%d+%.%d+%.%d+$") ~= nil
        and type(m.base) == "string"
        and type(m.sha256) == "string" and m.sha256:match("^%x+$") ~= nil and #m.sha256 == 64
end

--- What to do about a release: "none", "manual" (it needs a new install) or "download".
-- A release says its KOReader in koreader; base is what the versions before 0.9.11 compare.
function Updater.decide(manifest, version, base, bad)
    if not Updater.newer(manifest.version, version) then return "none" end
    if manifest.version == bad then return "none" end -- it did not start here
    local needs = type(manifest.koreader) == "string" and manifest.koreader or manifest.base
    if needs ~= base then return "manual" end
    return "download"
end

--- Whether a redirect may be followed: never to plain HTTP, and only to GitHub or the same host.
function Updater.redirect_allowed(from, to)
    local a, b = Http.parse_url(from), Http.parse_url(to)
    if not a or not b or a.tls ~= b.tls then return false end
    if a.host == b.host and a.port == b.port then return true end
    if not b.tls then return false end
    for _, suffix in ipairs(HOST_SUFFIXES) do
        if b.host == suffix or b.host:sub(-#suffix - 1) == "." .. suffix then return true end
    end
    return false
end

--- Whether it is time to ask again.
function Updater.due(checked_at, now)
    return not checked_at or now - checked_at >= Updater.DAY or now < checked_at
end

--- Returns the body; or nil and "not_found" or "network".
function Updater.get(http, url)
    for _ = 0, MAX_REDIRECTS do
        local status, body, headers = http:request("GET", url, { ["User-Agent"] = Http.USER_AGENT })
        if not status then return nil, "network" end
        if status == 200 then return body end
        if status == 404 then return nil, "not_found" end
        local location = headers and headers.location
        if status < 300 or status >= 400 or not location
            or not Updater.redirect_allowed(url, location) then
            return nil, "network"
        end
        url = location
    end
    return nil, "network"
end

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- The version waiting to be installed, if any.
function Updater.pending(dir)
    return read_line(dir .. "/pending/ready")
end

--- Called when a start went well: this version stays. Returns it if it is new.
function Updater.confirm(dir)
    local version = read_line(dir .. "/trial")
    if version then os.remove(dir .. "/trial") end
    return version
end

local function unpack_archive(dir, archive, manifest)
    local staging = dir .. "/staging"
    os.execute("rm -rf " .. shell_quote(staging) .. " && mkdir -p " .. shell_quote(staging))
    -- Run as root on a FAT-like volume: owners cannot be set there, and tar must not mind.
    local flags = "--no-same-owner --no-same-permissions -xf " .. shell_quote(archive) .. " -C " .. shell_quote(staging)
    -- Its exit status says nothing in a forked process, where children may be reaped for us.
    -- What was unpacked is what counts: the version that was asked for, whole enough to start.
    os.execute("./tar " .. flags .. " 2>/dev/null || tar " .. flags)
    local plugin = staging .. "/yaknigi.koplugin"
    if read_line(plugin .. "/yaknigi/VERSION") ~= manifest.version then return false, "unpack" end
    if not loadfile(plugin .. "/main.lua") or not loadfile(plugin .. "/_meta.lua") then return false, "load" end
    os.execute("rm -rf " .. shell_quote(dir .. "/pending"))
    if not os.rename(staging, dir .. "/pending") then return false, "rename" end
    local f = io.open(dir .. "/pending/ready", "wb")
    if not f then return false, "ready" end
    f:write(manifest.version)
    f:close()
    return true
end

--- Whether there is anything new, for a forked process. Returns kind ("none", "manual",
-- "available", "network" or "broken"), and the manifest when there is one.
function Updater.check(dir)
    local json = require("rapidjson")
    local Net = require("yaknigi/net")
    local http = Http.new(Net.connect)
    local body, err = Updater.get(http, Updater.RELEASES .. "/manifest.json")
    http:close()
    -- No release is out, which is not a failure of anything.
    if not body then return err == "not_found" and "none" or "network" end
    local ok, manifest = pcall(json.decode, body)
    if not ok or not Updater.valid_manifest(manifest) then return "broken" end
    local decision = Updater.decide(manifest, Updater.version(), Updater.base(), read_line(dir .. "/bad"))
    if decision == "none" then return "none" end
    return decision == "download" and "available" or decision, manifest
end

--- Fetches what the user agreed to, for a forked process. Returns "ready", "network" or
-- "broken", and what broke.
function Updater.download(dir, manifest)
    if Updater.pending(dir) == manifest.version then return "ready" end
    local sha2 = require("ffi/sha2")
    local Net = require("yaknigi/net")
    os.execute("mkdir -p " .. shell_quote(dir))
    local http = Http.new(Net.connect)
    local body = Updater.get(http, Updater.RELEASES .. "/" .. Updater.ARCHIVE)
    http:close()
    if not body then return "network" end
    if sha2.sha256(body):lower() ~= manifest.sha256:lower() then return "broken", "digest" end
    local archive = dir .. "/" .. Updater.ARCHIVE
    local f = io.open(archive, "wb")
    if not f then return "broken", "write" end
    f:write(body)
    f:close()
    local unpacked, why = unpack_archive(dir, archive, manifest)
    os.remove(archive)
    return unpacked and "ready" or "broken", why
end

--- Puts what waits in place. The caller then restarts.
function Updater.apply()
    return os.execute("sh " .. shell_quote(os.getenv("YAKNIGI_DIR") .. "/apply-update.sh"))
end

return Updater

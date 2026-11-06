-- Yandex Books and OAuth requests.
local Crypt = require("yaknigi/crypt")
local Http = require("yaknigi/http")
local Net = require("yaknigi/net")
local json = require("rapidjson")

local API_BASE = os.getenv("YB_API_BASE") or "https://api.bookmate.yandex.net/api/v5"
local GRAPHQL_URL = os.getenv("YB_GRAPHQL_URL") or "https://api-gateway.bookmate.yandex.net/graphql"
local OAUTH_BASE = os.getenv("YB_OAUTH_BASE") or "https://oauth.yandex.ru"
local CLIENT_ID = "CLIENT_ID_REMOVED" -- public; PKCE needs no secret
local REDIRECT = "https://oauth.yandex.ru/verification_code"

local Api = {}
Api.__index = Api

--- Each Api owns one connection; a forked subprocess must create its own.
function Api.new(token)
    return setmetatable({ token = token, http = Http.new(Net.connect) }, Api)
end

function Api:close()
    self.http:close()
end

local function encode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

function Api:headers(content_type)
    return {
        ["Auth-Token"] = self.token,
        ["App-Platform"] = "android",
        ["App-Language"] = "ru",
        ["App-Locale"] = "ru",
        ["Device-Os"] = "Android",
        ["Bookmate-Version"] = "20200305",
        ["User-Agent"] = "okhttp/4.12.0",
        ["Content-Type"] = content_type,
    }
end

function Api:get(url)
    local status, body = self.http:request("GET", url, self:headers())
    if not status then return nil, "network", body end
    if status == 401 or status == 403 then return nil, "auth" end
    if status == 404 then return nil, "not_found" end
    if status ~= 200 then return nil, "http", tostring(status) end
    return body
end

function Api:get_json(url)
    local body, kind, detail = self:get(url)
    if not body then return nil, kind, detail end
    local data, err = json.decode(body)
    if data == nil then return nil, "http", err end
    return data
end

-- JSON null decodes to a truthy value; absent is what the rest of the code expects.
local function drop_nulls(node)
    for k, v in pairs(node) do
        if v == json.null then
            node[k] = nil
        elseif type(v) == "table" then
            drop_nulls(v)
        end
    end
    return node
end

local function status_error(status, detail)
    if not status then return nil, "network", detail end
    if status == 401 or status == 403 then return nil, "auth" end
    if status == 404 then return nil, "not_found" end
    return nil, "http", tostring(status)
end

local PROGRESS_UPDATED = "mutation ProgressUpdated($textbookProgresses: [TextbookProgressUpdatedInput!]) "
    .. "{ progressUpdated(textbookProgresses: $textbookProgresses) { value } }"

--- Tells Yandex where the book is being read. Takes two requests, as in the phone app:
-- ProgressUpdated moves the position that other devices see; the library card holds the
-- percentage and the time of reading, and ignores the position it is sent.
function Api:send_position(p)
    local status, body = self.http:request("POST", GRAPHQL_URL, self:headers("application/json"), json.encode({
        operationName = "ProgressUpdated",
        query = PROGRESS_UPDATED,
        variables = { textbookProgresses = { {
            cfi = { start = p.start, ["end"] = p.finish },
            consumptionType = "CONSUMPTION",
            documentUuid = p.document,
            uuid = p.book,
            readAt = p.read_at,
            sessionId = p.session,
            timespent = p.timespent,
            timezoneId = "UTC",
        } } },
    }))
    if status ~= 200 then return status_error(status, body) end
    local answer = json.decode(body)
    -- GraphQL says what went wrong in a successful response.
    if type(answer) ~= "table" or (answer.errors and answer.errors ~= json.null) then
        return nil, "http", "graphql"
    end

    local form = {
        "lc[progress]=" .. p.progress,
        "lc[cfi]=" .. encode(p.range),
    }
    if p.state then form[#form + 1] = "lc[state]=" .. encode(p.state) end
    for i, field in ipairs(form) do
        form[i] = field:gsub("%[", "%%5B"):gsub("%]", "%%5D")
    end
    status, body = self.http:request("PUT", API_BASE .. "/profile/library_cards/" .. encode(p.card),
        self:headers("application/x-www-form-urlencoded"), table.concat(form, "&"))
    if status ~= 200 then return status_error(status, body) end
    return true
end

--- Returns one library card as it is now.
function Api:card(uuid)
    local data, kind, detail = self:get_json(API_BASE .. "/profile/library_cards/" .. encode(uuid))
    if not data then return nil, kind, detail end
    if type(data.library_card) ~= "table" then return nil, "http", "no card" end
    return drop_nulls(data.library_card)
end

--- Returns every library card, fetching all pages.
function Api:library()
    local cards = {}
    local page = 1
    while true do
        local data, kind, detail = self:get_json(API_BASE .. "/profile/library_cards?page=" .. page)
        if not data then return nil, kind, detail end
        local got = data.library_cards
        if type(got) ~= "table" or #got == 0 then break end
        for _, c in ipairs(got) do cards[#cards + 1] = drop_nulls(c) end
        page = page + 1
    end
    return cards
end

local function find_key(node)
    if type(node) == "string" then
        local ok, bin = pcall(Crypt.base64_decode, node)
        if ok and bin and #bin == 32 then return bin end
    elseif type(node) == "table" then
        for _, v in pairs(node) do
            local key = find_key(v)
            if key then return key end
        end
    end
end

local function bytes(arr)
    local parts = {}
    -- string.char takes limited arguments; go in slices.
    for i = 1, #arr, 4096 do
        parts[#parts + 1] = string.char(unpack(arr, i, math.min(i + 4095, #arr)))
    end
    return table.concat(parts)
end

--- Fetches the decrypted manifest of a book.
-- Returns { document_uuid=, container=, opf=, ncx= }.
function Api:manifest(book_uuid)
    local meta, kind, detail = self:get_json(API_BASE .. "/books/" .. encode(book_uuid) .. "/metadata/v4")
    if not meta then return nil, kind, detail end
    if type(meta.opf) ~= "table" or type(meta.document_uuid) ~= "string" then
        return nil, "http", "manifest without opf"
    end
    local secret
    secret, kind, detail = self:get_json(API_BASE .. "/metadata_secret")
    if not secret then return nil, kind, detail end
    local key = find_key(secret)
    if not key then return nil, "http", "no key" end

    local out = { document_uuid = meta.document_uuid }
    for _, name in ipairs { "container", "opf", "ncx" } do
        if type(meta[name]) == "table" and #meta[name] > 0 then
            out[name] = Crypt.aes256_cbc_ivprefix(key, bytes(meta[name]))
            if not out[name] then return nil, "http", "cannot decrypt " .. name end
        end
    end
    if not out.opf then return nil, "http", "manifest without opf" end
    return out
end

--- Fetches one file of a book, by its path in the book.
function Api:content(document_uuid, path)
    return self:get(API_BASE .. "/documents/" .. encode(document_uuid) .. "/content?path=" .. encode(path))
end

--- Returns the URL to sign in at, for the given PKCE verifier.
function Api.login_url(verifier)
    return OAUTH_BASE .. "/authorize?response_type=code&client_id=" .. CLIENT_ID
        .. "&redirect_uri=" .. encode(REDIRECT)
        .. "&code_challenge=" .. Crypt.pkce_challenge(verifier)
        .. "&code_challenge_method=S256"
end

--- Trades a confirmation code for a token. Returns the token, or nil and a kind:
-- "bad_code" when the code was refused, "network" or "http" otherwise.
function Api.exchange_code(code, verifier)
    local http = Http.new(Net.connect)
    local body = "grant_type=authorization_code&code=" .. encode(code)
        .. "&client_id=" .. CLIENT_ID .. "&code_verifier=" .. encode(verifier)
    local status, resp = http:request("POST", OAUTH_BASE .. "/token",
        { ["Content-Type"] = "application/x-www-form-urlencoded" }, body)
    http:close()
    if not status then return nil, "network" end
    if status == 400 then return nil, "bad_code" end
    if status ~= 200 then return nil, "http" end
    local data = json.decode(resp)
    if type(data) ~= "table" or type(data.access_token) ~= "string" then return nil, "http" end
    return data.access_token
end

return Api

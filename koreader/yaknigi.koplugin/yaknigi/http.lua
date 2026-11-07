-- A small HTTP/1.1 client that keeps its connection open.
--
-- LuaSocket's client opens a new connection for every request, and on the Kindle
-- each TLS handshake costs far more than downloading a chapter.
local Http = {}

-- How this client names itself to every server it asks.
Http.USER_AGENT = "yaknigi-koreader/1.0"
Http.__index = Http

--- connect(host, port, is_tls) returns an object with send/receive/close, as a
-- LuaSocket connection has, or nil and an error.
function Http.new(connect)
    return setmetatable({ connect = connect }, Http)
end

function Http:close()
    if self.sock then self.sock:close() end
    self.sock, self.key = nil, nil
end

local function parse_url(url)
    local scheme, host, port, path = url:match("^(https?)://([^/:]+):?(%d*)(.*)$")
    if not scheme then return nil end
    return {
        tls = scheme == "https",
        host = host,
        port = tonumber(port) or (scheme == "https" and 443 or 80),
        path = path ~= "" and path or "/",
    }
end
Http.parse_url = parse_url

local function read_headers(sock)
    local line, err = sock:receive("*l")
    if not line then return nil, err end
    local status = tonumber(line:match("^HTTP/%d%.%d%s+(%d+)"))
    if not status then return nil, "bad status line" end
    local headers = {}
    while true do
        line, err = sock:receive("*l")
        if not line then return nil, err end
        if line == "" or line == "\r" then break end
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k then headers[k:lower()] = v end
    end
    return status, headers
end

local function read_chunked(sock)
    local parts = {}
    while true do
        local line, err = sock:receive("*l")
        if not line then return nil, err end
        local size = tonumber(line:match("^%x+"), 16)
        if not size then return nil, "bad chunk size" end
        if size == 0 then
            -- Trailers end with an empty line.
            repeat
                line, err = sock:receive("*l")
                if not line then return nil, err end
            until line == "" or line == "\r"
            return table.concat(parts)
        end
        local data
        data, err = sock:receive(size)
        if not data then return nil, err end
        parts[#parts + 1] = data
        sock:receive("*l") -- the CRLF after the chunk
    end
end

function Http:attempt(u, method, headers, body)
    local key = u.host .. ":" .. u.port .. (u.tls and ":tls" or "")
    local reused = self.sock ~= nil and self.key == key
    if not reused then
        self:close()
        local sock, err = self.connect(u.host, u.port, u.tls)
        if not sock then return nil, err, false end
        self.sock, self.key = sock, key
    end
    local sock = self.sock

    local lines = { method .. " " .. u.path .. " HTTP/1.1", "Host: " .. u.host,
                    "Connection: keep-alive" }
    for k, v in pairs(headers or {}) do lines[#lines + 1] = k .. ": " .. v end
    if body then lines[#lines + 1] = "Content-Length: " .. #body end
    lines[#lines + 1] = "\r\n"
    local ok, err = sock:send(table.concat(lines, "\r\n") .. (body or ""))
    if not ok then return nil, err, reused end

    local status, resp = read_headers(sock)
    if not status then return nil, resp, reused end

    local data = ""
    local keep = (resp.connection or ""):lower() ~= "close"
    if status == 204 or status == 304 or method == "HEAD" then
        data = ""
    elseif (resp["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
        data, err = read_chunked(sock)
    elseif resp["content-length"] then
        local n = tonumber(resp["content-length"])
        if n and n > 0 then
            data, err = sock:receive(n)
        end
    else
        data, err = sock:receive("*a")
        keep = false
    end
    if not data then return nil, err, reused end
    if not keep then self:close() end
    return status, resp, data
end

--- Returns status, body, headers; or nil and an error message.
function Http:request(method, url, headers, body)
    local u = parse_url(url)
    if not u then return nil, "bad url" end
    local status, a, b = self:attempt(u, method, headers, body)
    if not status and b == true then
        -- The server may close an idle connection at any moment; that is not a
        -- failure of this request, so try once on a fresh one.
        self:close()
        status, a, b = self:attempt(u, method, headers, body)
    end
    if not status then
        self:close()
        return nil, tostring(a)
    end
    return status, b, a
end

return Http

-- Opens connections for Http: plain TCP, or TLS with the certificate checked.
-- KOReader's own https helper sets verify="none", which would hand the user's
-- token to anyone on the network path.
local socket = require("socket")
local ssl = require("ssl")

local Net = {}

local CA_FILE = "data/ca-bundle.crt"

local function name_matches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then return true end
    local suffix = pattern:match("^%*(%.[^*]+%.[^*]+)$")
    if not suffix then return false end
    local head = host:sub(1, #host - #suffix)
    return #head > 0 and not head:find(".", 1, true) and host:sub(-#suffix) == suffix
end
Net.name_matches = name_matches

local function host_verified(conn, host)
    local cert = conn:getpeercertificate()
    if not cert then return false end
    local san = cert:extensions()["2.5.29.17"]
    for _, name in ipairs(san and san.dNSName or {}) do
        if name_matches(name, host) then return true end
    end
    return false
end

function Net.connect(host, port, is_tls)
    local conn, err = socket.tcp()
    if not conn then return nil, err end
    conn:settimeout(30)
    local ok
    ok, err = conn:connect(host, port)
    if not ok then conn:close(); return nil, err end
    if not is_tls then return conn end

    local wrapped
    wrapped, err = ssl.wrap(conn, {
        mode = "client",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
        verify = "peer",
        cafile = CA_FILE,
    })
    if not wrapped then conn:close(); return nil, err end
    wrapped:settimeout(30)
    wrapped:sni(host)
    ok, err = wrapped:dohandshake()
    if not ok then wrapped:close(); return nil, "TLS: " .. tostring(err) end
    if not host_verified(wrapped, host) then
        wrapped:close()
        return nil, "TLS: certificate is not for " .. host
    end
    return wrapped
end

return Net

-- Checks certificate verification with KOReader's real ssl library and CA bundle.
-- Run with KOReader's luajit from its directory: ./luajit tls_check.lua PLUGIN_DIR
package.path = "common/?.lua;frontend/?.lua;" .. arg[1] .. "/?.lua;" .. package.path
package.cpath = "common/?.so;common/?.dylib;" .. package.cpath
require("setupkoenv")
local Net = require("yaknigi/net")
local failed = false
local function check(host, want_ok)
    local conn, err = Net.connect(host, 443, true)
    local ok = conn ~= nil
    print(host, ok and "connected" or ("refused: " .. tostring(err)))
    if conn then conn:close() end
    if ok ~= want_ok then
        print("WRONG RESULT for " .. host)
        failed = true
    end
end
check("api.bookmate.yandex.net", true)
check("oauth.yandex.ru", true)
check("wrong.host.badssl.com", false)
check("expired.badssl.com", false)
check("self-signed.badssl.com", false)
os.exit(failed and 1 or 0)

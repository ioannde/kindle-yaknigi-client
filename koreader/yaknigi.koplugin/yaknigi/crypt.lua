-- AES and PKCE. ffi/crypto exposes only ECB, so CBC is declared here.
local ffi = require("ffi")
require("ffi/crypto_h")
local sha2 = require("ffi/sha2")

ffi.cdef [[
const EVP_CIPHER *EVP_aes_256_cbc(void);
]]
local libcrypto = ffi.loadlib("crypto", "57")

local Crypt = {}

--- Decrypts AES-256-CBC data whose first 16 bytes are the IV. Returns nil on failure.
function Crypt.aes256_cbc_ivprefix(key, data)
    if #key ~= 32 or #data < 32 then return nil end
    local ctx = libcrypto.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil end
    local body = data:sub(17)
    local out = ffi.new("unsigned char[?]", #body + 32)
    local n = ffi.new("int[1]")
    local result
    if libcrypto.EVP_DecryptInit_ex(ctx, libcrypto.EVP_aes_256_cbc(), nil, key, data:sub(1, 16)) == 1
        and libcrypto.EVP_DecryptUpdate(ctx, out, n, body, #body) == 1 then
        local total = n[0]
        if libcrypto.EVP_DecryptFinal_ex(ctx, out + total, n) == 1 then
            result = ffi.string(out, total + n[0])
        end
    end
    libcrypto.EVP_CIPHER_CTX_free(ctx)
    return result
end

local function urlsafe(b64)
    return (b64:gsub("%+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

function Crypt.new_verifier()
    local f = assert(io.open("/dev/urandom", "rb"))
    local bytes = f:read(32)
    f:close()
    return urlsafe(sha2.bin2base64(bytes))
end

function Crypt.pkce_challenge(verifier)
    return urlsafe(sha2.bin2base64(sha2.hex2bin(sha2.sha256(verifier))))
end

function Crypt.base64_decode(s)
    return sha2.base642bin(s)
end

return Crypt

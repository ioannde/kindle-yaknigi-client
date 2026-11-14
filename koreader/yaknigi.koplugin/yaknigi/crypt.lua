-- AES and PKCE. KOReader on Android carries only the ECB ciphers of libcrypto, so CBC is made
-- here from ECB: each block deciphered alone, then XORed with the block before it.
local ffi = require("ffi")
require("ffi/crypto_h")
local sha2 = require("ffi/sha2")

local libcrypto = ffi.loadlib("crypto", "57")

local Crypt = {}

--- Decrypts AES-256-CBC data whose first 16 bytes are the IV. Returns nil on failure.
function Crypt.aes256_cbc_ivprefix(key, data)
    if #key ~= 32 or #data < 32 or #data % 16 ~= 0 then return nil end
    local ctx = libcrypto.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil end
    local body = data:sub(17)
    local out = ffi.new("unsigned char[?]", #body + 16)
    local n = ffi.new("int[1]")
    local plain
    if libcrypto.EVP_DecryptInit_ex(ctx, libcrypto.EVP_aes_256_ecb(), nil, key, nil) == 1
        and libcrypto.EVP_CIPHER_CTX_set_padding(ctx, 0) == 1
        and libcrypto.EVP_DecryptUpdate(ctx, out, n, body, #body) == 1 and n[0] == #body then
        local cipher = ffi.cast("const unsigned char *", data)
        for i = 0, #body - 1 do
            out[i] = bit.bxor(out[i], cipher[i]) -- the byte 16 back in data: the IV, then the blocks
        end
        local pad = out[#body - 1]
        if pad >= 1 and pad <= 16 then
            local good = true
            for i = #body - pad, #body - 1 do
                if out[i] ~= pad then good = false end
            end
            if good then plain = ffi.string(out, #body - pad) end
        end
    end
    libcrypto.EVP_CIPHER_CTX_free(ctx)
    return plain
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

local aes          = require "resty.aes"

local setmetatable = setmetatable
local tonumber     = tonumber
local hashes       = aes.hash
local ceil         = math.ceil
local var          = ngx.var
local sub          = string.sub
local rep          = string.rep

local CIPHER_MODES = {
    ecb    = "ecb",
    cbc    = "cbc",
    cfb1   = "cfb1",
    cfb8   = "cfb8",
    cfb128 = "cfb128",
    ofb    = "ofb",
    ctr    = "ctr",
}

local CIPHER_SIZES = {
    ["128"] = 128,
    ["192"] = 192,
    ["256"] = 256,
}

local defaults = {
    size   = CIPHER_SIZES[var.session_aes_size]   or 256,
    mode   = CIPHER_MODES[var.session_aes_mode]   or "cbc",
    hash   = hashes[var.session_aes_hash]         or "sha512",
    rounds = tonumber(var.session_aes_rounds, 10) or 1,
}

local function adjust_salt(salt)
    if salt then
        local z = #salt
        if z < 8 then
            return sub(rep(salt, ceil(8 / z)), 1, 8)
        end
        if z > 8 then
            return sub(salt, 1, 8)
        end
        return salt
    end
end

local cipher = {}

cipher.__index = cipher

function cipher.new(session)
    local config = session.aes or defaults
    return setmetatable({
        size   = CIPHER_SIZES[config.size or defaults.size]       or 256,
        mode   = CIPHER_MODES[config.mode or defaults.mode]       or "cbc",
        hash   = hashes[config.hash       or defaults.hash]       or hashes.sha512,
        rounds = tonumber(config.rounds   or defaults.rounds, 10) or 1
    }, cipher)
end

function cipher:encrypt(data, key, salt)
    local mode = aes.cipher(self.size, self.mode)
    return aes:new(key, adjust_salt(salt), mode, self.hash, self.rounds):encrypt(data)
end

function cipher:decrypt(data, key, salt)
    local mode = aes.cipher(self.size, self.mode)
    return aes:new(key, adjust_salt(salt), mode, self.hash, self.rounds):decrypt(data)
end

return cipher

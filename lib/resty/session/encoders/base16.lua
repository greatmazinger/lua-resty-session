local to_hex   = require "resty.string".to_hex

local tonumber = tonumber
local gsub     = string.gsub
local char     = string.char

local function chr(c)
    return char(tonumber(c, 16) or 0)
end

local base16 = {}

function base16.encode(v)
    return to_hex(v)
end

function base16.decode(v)
    return (gsub(v, "..", chr))
end

return base16

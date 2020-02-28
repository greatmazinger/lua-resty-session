local ngx       = ngx
local encode_base64 = ngx.encode_base64
local decode_base64 = ngx.decode_base64

local ENCODE_CHARS = {
    ["+"] = "-",
    ["/"] = "_",
    ["="] = "."
}

local DECODE_CHARS = {
    ["-"] = "+",
    ["_"] = "/",
    ["."] = "="
}

local base64 = {}

function base64.encode(value)
    return (encode_base64(value):gsub("[+/=]", ENCODE_CHARS))
end

function base64.decode(value)
    return decode_base64((value:gsub("[-_.]", DECODE_CHARS)))
end

return base64

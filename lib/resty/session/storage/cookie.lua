local cookie = {}

function cookie.new()
    return cookie
end

-- returns 4 decoded data elements from the cookie-string
-- @param value (string) the cookie string containing the encoded data.
-- @return id (string), expires(number), data (string), hash (string).
function cookie:open(cookie)
    return cookie.data
end

-- returns a cookie-string. Note that the cookie-storage does not store anything
-- server-side in this case.
-- @param id (string)
-- @param expires(number)
-- @param data (string)
-- @param hash (string)
-- @return encoded cookie-string value
function cookie:save()
    return true
end

return cookie

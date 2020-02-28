local type   = type
local concat = table.concat

local default = {}

-- save the session data to the underlying storage adapter.
-- @param session (table) the session object to store
-- @return result from `storage.save`.
function default.save(session, close)
  local id      = session.id
  local expires = session.expires
  local storage = session.storage
  local key     = session.hmac(session.secret, concat{ id, expires })
  local data    = session.serializer.serialize(session.data)
  local hash    = session.hmac(key, concat{ id, expires, data, session.key })

  local err
  data, err = session.cipher:encrypt(data, key, id, session.key)
  if not data then
    return nil, err
  end

  local ok
  ok, err = storage:save(id, expires, data, hash, close)
  if not ok then
    return nil, err
  end

  return true
end

-- Calls into the underlying storage adapter to load the cookie.
-- Validates the expiry-time and hash.
-- @param session (table) the session object to store the data in
-- @param cookie (string) the cookie string to open
-- @return `true` if ok, and will have set session properties; id, expires, data and present. Returns `nil` otherwise.
function default.open(session, cookie)
  local data, err = session.storage:open(cookie, session.cookie.lifetime)
  if not data then
    return nil, err or "cookie data could not be loaded"
  end

  local id      = cookie.id
  local expires = cookie.expires
  local hash    = cookie.hash

  local key = session.hmac(session.secret, concat{ id, expires })
  data, err = session.cipher:decrypt(data, key, id, session.key)
  if not data then
    return nil, err
  end

  local input = concat{ id, expires, data, session.key }
  if session.hmac(key, input) ~= hash then
    return nil
  end

  data = session.serializer.deserialize(data)

  session.id      = id
  session.expires = expires
  session.data    = type(data) == "table" and data or {}
  session.present = true

  return true
end

return default

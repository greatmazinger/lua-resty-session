local lock         = require "resty.lock"

local setmetatable = setmetatable
local tonumber     = tonumber
local concat       = table.concat
local now          = ngx.now
local var          = ngx.var
local shared       = ngx.shared

local function enabled(value)
    if value == nil then return nil end
    return value == true or (value == "1" or value == "true" or value == "on")
end

local defaults = {
    store      = var.session_shm_store or "sessions",
    uselocking = enabled(var.session_shm_uselocking or true),
    lock       = {
        exptime  = tonumber(var.session_shm_lock_exptime,  10) or 30,
        timeout  = tonumber(var.session_shm_lock_timeout,  10) or 5,
        step     = tonumber(var.session_shm_lock_step,     10) or 0.001,
        ratio    = tonumber(var.session_shm_lock_ratio,    10) or 2,
        max_step = tonumber(var.session_shm_lock_max_step, 10) or 0.5,
    }
}

local storage = {}

storage.__index = storage

function storage.new(session)
    local config = session.shm or defaults
    local store  = config.store or defaults.store

    local locking = enabled(config.uselocking)
    if locking == nil then
        locking = defaults.uselocking
    end

    local self = {
        store      = shared[store],
        encode     = session.encoder.encode,
        decode     = session.encoder.decode,
        uselocking = locking,
    }

    if locking then
        local lock_opts = config.lock or defaults.lock
        local opts = {
            exptime  = tonumber(lock_opts.exptime,  10) or defaults.exptime,
            timeout  = tonumber(lock_opts.timeout,  10) or defaults.timeout,
            step     = tonumber(lock_opts.step,     10) or defaults.step,
            ratio    = tonumber(lock_opts.ratio,    10) or defaults.ratio,
            max_step = tonumber(lock_opts.max_step, 10) or defaults.max_step,
        }
        self.lock = lock:new(store, opts)
    end

    return setmetatable(self, store)
end

function storage:key(id)
    return self.encode(id)
end

-- Opens session and writes it to the store. Returns 4 decoded data elements from the cookie-string.
-- @param value (string) the cookie string containing the encoded data.
-- @param lifetime (number) lifetime in seconds of the data in the store (ttl)
-- @return id (string), expires(number), data (string), hash (string).
function storage:open(value, lifetime)
    local cookie, err = self.cookie:parse(value)
    if not cookie then
        return  nil, err
    end

    local key = self:key(cookie.id)
    if self.uselocking then
        local ok, err = self.lock:lock(concat{key, ".lock"})
        if not ok then
            return nil, err
        end
    end

    local store = self.store
    local data = store:get(key)

    store:set(key, data, lifetime)

    if self.uselocking then
        self.lock:unlock()
    end

    return data
end

-- acquire locks if required
function storage:start(id)
    if self.uselocking then
        return self.lock:lock(concat{self:key(id), ".lock"})
    end

    return true
end

-- Saves the session data to the SHM.
-- server-side in this case.
-- @param id (string)
-- @param expires(number) lifetime in SHM (ttl) is calculated from this
-- @param data (string)
-- @param hash (string)
-- @return encoded cookie-string value
function storage:save(id, expires, data, close)
    local lifetime = expires - now()
    if lifetime <= 0 then
        if self.uselocking and close then
            self.lock:unlock()
        end

        return nil, "expired"
    end

    local key = self:key(id)
    local ok, err = self.store:set(key, data, lifetime)
    if self.uselocking and close then
        self.lock:unlock()
    end

    if not ok then
        return nil, err
    end

    return true
end

-- release any locks
-- @return true
function storage:close()
    if self.uselocking then
        self.lock:unlock()
    end

    return true
end

-- destroy the session by deleting is from the SHM
-- @param id (string) id of session to destroy
-- @return true
function storage:destroy(id)
    local key = self:key(id)

    self.store:delete(key)

    if self.uselocking then
        self.lock:unlock()
    end

    return true, nil
end

-- updates the remaining ttl in the SHM
-- @param id (string) id of session to update
-- @param lifetime (number) time in seconds the value should remain available
function storage:ttl(id, lifetime)
    local key = self:key(id)

    local ok, err = self.store:expire(key, lifetime)

    if self.uselocking then
        self.lock:unlock()
    end

    return ok, err
end

return storage

local setmetatable = setmetatable
local tonumber     = tonumber
local concat       = table.concat
local now          = ngx.now
local var          = ngx.var
local ngx          = ngx
local dshm         = require "resty.dshm"

local defaults = {
    store             = var.session_dshm_store                           or "sessions",
    host              = var.session_dshm_host                            or "127.0.0.1",
    port              = tonumber(var.session_dshm_port,              10) or 4321,
    pool_size         = tonumber(var.session_dshm_pool_size,         10) or 100,
    pool_idle_timeout = tonumber(var.session_dshm_pool_idle_timeout, 10) or 1000
}

local shm = {}

shm.__index = shm

function shm.new(session)
    local config = session.shm or defaults
    local store = config.store or defaults.store

    local self = {
        store             = dshm:new(),
        cookie            = session.cookie,
        encode            = session.encoder.encode,
        decode            = session.encoder.decode,
        name              = store,
        host              = defaults.host,
        port              = defaults.port,
        pool_size         = defaults.pool_size,
        pool_idle_timeout = defaults.pool_idle_timeout
    }
    return setmetatable(self, shm)
end

function shm:connect()
    return self.store:connect(self.host, self.port)
end

function shm:set_keepalive()
    return self.store:set_keepalive(self.pool_idle_timeout, self.pool_size)
end

function shm:set(...)
    local _, err = self:connect()
    if err then
        return nil, err
    end
    local ok
    ok, err = self.store:set(...)
    self:set_keepalive()
    if err then
        return nil, err
    end
    return ok, nil
end

function shm:get(...)
    local _, err = self:connect()
    if err then
        return nil, err
    end
    local ok
    ok, err = self.store:get(...)
    self:set_keepalive()
    if err then
        return nil, err
    end
    return ok, nil
end

function shm:touch(...)
    local _, err = self:connect()
    if err then
        return nil, err
    end
    local ok
    ok, err = self.store:touch(...)
    self:set_keepalive()
    if err then
        return nil, err
    end
    return ok, nil
end

function shm:delete(...)
    local _, err = self:connect()
    if err then
        return nil, err
    end
    local ok
    ok, err = self.store:delete(...)
    self:set_keepalive()
    if err then
        return nil, err
    end
    return ok, nil
end

function shm:key(i)
    return self.encode(i)
end

function shm:open(cookie, lifetime)
    local c = self.cookie:parse(cookie)
    if c and c[1] and c[2] and c[3] then
        local i, e, h = self.decode(c[1]), tonumber(c[2], 10), self.decode(c[3])
        local k = self:key(i)
        local d = self:get(concat({self.name , k}, ":"))
        if d then
            self:touch(concat({self.name , k}, ":"), lifetime)
            d = ngx.decode_base64(d)
        end

        return i, e, d, h
    end
    return nil, "invalid"
end

function shm:start(_) -- luacheck: ignore
    return true, nil
end

function shm:save(i, e, d, h, _)
    local l = e - now()
    if l > 0 then
        local k = self:key(i)
        local ok, err = self:set(concat({self.name , k}, ":"), ngx.encode_base64(d), l)
        if ok then
            return concat({ k, e, self.encode(h) }, self.delimiter)
        end
        return nil, err
    end
    return nil, "expired"
end

function shm:destroy(i)
    self:delete(concat({self.name , self:key(i)}, ":"))
    return true, nil
end

return shm

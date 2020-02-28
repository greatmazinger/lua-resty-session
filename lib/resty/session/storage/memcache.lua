local memcached    = require "resty.memcached"
local setmetatable = setmetatable
local tonumber     = tonumber
local concat       = table.concat
local floor        = math.floor
local sleep        = ngx.sleep
local null         = ngx.null
local now          = ngx.now
local var          = ngx.var

local function enabled(val)
    if val == nil then return nil end
    return val == true or (val == "1" or val == "true" or val == "on")
end

local defaults = {
    prefix       = var.session_memcache_prefix                     or "sessions",
    socket       = var.session_memcache_socket,
    host         = var.session_memcache_host                       or "127.0.0.1",
    port         = tonumber(var.session_memcache_port,         10) or 11211,
    uselocking   = enabled(var.session_memcache_uselocking         or true),
    spinlockwait = tonumber(var.session_memcache_spinlockwait, 10) or 10000,
    maxlockwait  = tonumber(var.session_memcache_maxlockwait,  10) or 30,
    pool = {
        timeout  = tonumber(var.session_memcache_pool_timeout, 10),
        size     = tonumber(var.session_memcache_pool_size,    10)
    }
}

local memcache = {}

memcache.__index = memcache

function memcache.new(session)
    local config  = session.memcache or defaults
    local pool    = config.pool      or defaults.pool
    local locking = enabled(config.uselocking)
    if locking == nil then
        locking = defaults.uselocking
    end

    local self = {
        memcache     = memcached:new(),
        encode       = session.encoder.encode,
        decode       = session.encoder.decode,
        prefix       = config.prefix                     or defaults.prefix,
        uselocking   = locking,
        spinlockwait = tonumber(config.spinlockwait, 10) or defaults.spinlockwait,
        maxlockwait  = tonumber(config.maxlockwait,  10) or defaults.maxlockwait,
        pool = {
            timeout = tonumber(pool.timeout,         10) or defaults.pool.timeout,
            size    = tonumber(pool.size,            10) or defaults.pool.size
        },
    }
    local socket = config.socket or defaults.socket
    if socket and socket ~= "" then
        self.socket = socket
    else
        self.host = config.host or defaults.host
        self.port = config.port or defaults.port
    end

    return setmetatable(self, memcache)
end

function memcache:connect()
    local socket = self.socket
    if socket then
        return self.memcache:connect(socket)
    end
    return self.memcache:connect(self.host, self.port)
end

function memcache:set_keepalive()
    local pool = self.pool
    local timeout, size = pool.timeout, pool.size
    if timeout and size then
        return self.memcache:set_keepalive(timeout, size)
    end
    if timeout then
        return self.memcache:set_keepalive(timeout)
    end
    return self.memcache:set_keepalive()
end

function memcache:key(i)
    return concat({ self.prefix, self.encode(i) }, ":" )
end

function memcache:lock(k)
    if not self.uselocking then
        return true, nil
    end
    local s = self.spinlockwait
    local m = self.maxlockwait
    local w = s / 1000000
    local c = self.memcache
    local i = 1000000 / s * m
    local l = concat({ k, "lock" }, "." )
    for _ = 1, i do
        local ok = c:add(l, "1", m + 1)
        if ok then
            return true, nil
        end
        sleep(w)
    end
    return false, "no lock"
end

function memcache:unlock(k)
    if self.uselocking then
        return self.memcache:delete(concat({ k, "lock" }, "." ))
    end
    return true, nil
end

function memcache:get(k)
    local d = self.memcache:get(k)
    return d ~= null and d or nil
end

function memcache:set(k, d, l)
    return self.memcache:set(k, d, l)
end

function memcache:expire(k, l)
    self.memcache:touch(k, l)
end

function memcache:delete(k)
    self.memcache:delete(k)
end

function memcache:open(cookie, lifetime)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    local key = self:key(cookie.id)
    ok, err = self:lock(key)
    if not ok then
        self:set_keepalive()
        return nil, err
    end

    local data = self:get(key)
    if data then
        self:expire(key, floor(lifetime))
    end

    self:unlock(key)
    self:set_keepalive()

    return data
end

function memcache:start(id)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    local key = self:key(id)

    ok, err = self:lock(key)
    self:set_keepalive()

    return ok, err
end

function memcache:save(id, expires, data, close)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    local lifetime = floor(expires - now())
    if lifetime <= 0 then
        if close then
            self:unlock(k)
        end

        self:set_keepalive()

        return nil, "expired"
    end

    local key = self:key(id)
    ok, err = self:set(key, data, lifetime)

    if close then
        self:unlock(key)
    end

    self:set_keepalive()

    if not ok then
        return nil, err
    end

    return true
end

function memcache:close(id)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    local key = self:key(id)

    self:unlock(key)
    self:set_keepalive()

    return true
end

function memcache:destroy(id)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    local key = self:key(id)

    self:delete(key)
    self:unlock(key)
    self:set_keepalive()

    return true
end

function memcache:ttl(id, lifetime)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    local key = self:key(id)

    ok, err = self:expire(key, floor(lifetime))
    self:unlock(key)
    self:set_keepalive()

    return ok, err
end

return memcache

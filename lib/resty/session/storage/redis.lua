local redis        = require "resty.redis"

local setmetatable = setmetatable
local tonumber     = tonumber
local concat       = table.concat
local floor        = math.floor
local sleep        = ngx.sleep
local null         = ngx.null
local now          = ngx.now
local var          = ngx.var

local function enabled(value)
    if value == nil then return nil end
    return value == true or (value == "1" or value == "true" or value == "on")
end

local defaults = {
    prefix       = var.session_redis_prefix                      or "sessions",
    socket       = var.session_redis_socket,
    host         = var.session_redis_host                        or "127.0.0.1",
    port         = tonumber(var.session_redis_port,         10)  or 6379,
    auth         = var.session_redis_auth,
    uselocking   = enabled(var.session_redis_uselocking          or true),
    spinlockwait = tonumber(var.session_redis_spinlockwait, 10)  or 10000,
    maxlockwait  = tonumber(var.session_redis_maxlockwait,  10)  or 30,
    pool = {
        timeout  = tonumber(var.session_redis_pool_timeout, 10),
        size     = tonumber(var.session_redis_pool_size,    10)
    },
    ssl          = enabled(var.session_redis_ssl)                or false,
    ssl_verify   = enabled(var.session_redis_ssl_verify)         or false,
    server_name  = var.session_redis_server_name,
}

local storage = {}

storage.__index = storage

function storage.new(session)
    local config = session.redis or defaults
    local pool = config.pool     or defaults.pool

    local locking = enabled(config.uselocking)
    if locking == nil then
        locking = defaults.uselocking
    end

    local self = {
        redis         = redis:new(),
        auth          = config.auth                       or defaults.auth,
        encode        = session.encoder.encode,
        decode        = session.encoder.decode,
        prefix        = config.prefix                     or defaults.prefix,
        uselocking    = locking,
        spinlockwait  = tonumber(config.spinlockwait, 10) or defaults.spinlockwait,
        maxlockwait   = tonumber(config.maxlockwait,  10) or defaults.maxlockwait,
        pool = {
            timeout   = tonumber(pool.timeout,        10) or defaults.pool.timeout,
            size      = tonumber(pool.size,           10) or defaults.pool.size,
        },
        connect_opts = {
          ssl         = config.ssl                        or defaults.ssl,
          ssl_verify  = config.ssl_verify                 or defaults.ssl_verify,
          server_name = config.server_name                or defaults.server_name,
        },
    }

    local socket = config.socket or defaults.socket
    if socket and socket ~= "" then
        self.socket = socket
    else
        self.host = config.host or defaults.host
        self.port = config.port or defaults.port
    end

    return setmetatable(self, storage)
end

function storage:connect()
    local ok, err
    if self.socket then
        ok, err = self.redis:connect(self.socket)
    else
        ok, err = self.redis:connect(self.host, self.port, self.connect_opts)
    end

    if not ok then
        return nil, err
    end

    if self.auth and self.auth ~= "" and self.redis:get_reused_times() == 0 then
        ok, err = self.redis:auth(self.auth)
    end

    return ok, err
end

function storage:set_keepalive()
    local pool    = self.pool
    local timeout = pool.timeout
    local size    = pool.size

    if timeout and size then
        return self.redis:set_keepalive(timeout, size)
    end

    if timeout then
        return self.redis:set_keepalive(timeout)
    end

    return self.redis:set_keepalive()
end

function storage:key(id)
    return concat({ self.prefix, self.encode(id) }, ":" )
end

function storage:lock(key)
    if not self.uselocking then
        return true, nil
    end

    local s = self.spinlockwait
    local m = self.maxlockwait
    local w = s / 1000000
    local i = 1000000 / s * m
    local l = concat({ key, "lock" }, "." )

    for _ = 1, i do
        local ok = self.redis:setnx(l, "1")
        if ok == 1 then
            return self.redis:expire(l, m + 1)
        end

        sleep(w)
    end

    return false, "no lock"
end

function storage:unlock(key)
    if self.uselocking then
        return self.redis:del(concat({ key, "lock" }, "." ))
    end

    return true, nil
end

function storage:get(key)
    local data = self.redis:get(key)
    return data ~= null and data or nil
end

function storage:set(key, data, lifetime)
    return self.redis:setex(key, lifetime, data)
end

function storage:expire(key, lifetime)
    self.redis:expire(key, lifetime)
end

function storage:delete(key)
    self.redis:del(key)
end

function storage:open(cookie, lifetime)
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

function storage:start(id)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    ok, err = self:lock(self:key(id))

    self:set_keepalive()

    return ok, err
end

function storage:save(id, expires, data, close)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    local key      = self:key(id)
    local lifetime = floor(expires - now())

    if lifetime <= 0 then
        if close then
            self:unlock(key)
        end

        self:set_keepalive()

        return nil, "expired"
    end

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

function storage:close(id)
    local ok, err = self:connect()
    if not ok then
        return nil, err
    end

    local key = self:key(id)

    self:unlock(key)
    self:set_keepalive()

    return true
end

function storage:destroy(id)
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

function storage:ttl(id, lifetime)
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


return storage

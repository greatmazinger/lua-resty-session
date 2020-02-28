local require      = require

local random       = require "resty.random"
local resp         = require "ngx.resp"

local ngx          = ngx
local var          = ngx.var
local time         = ngx.time
local http_time    = ngx.http_time
local set_header   = ngx.req.set_header
local clear_header = ngx.req.clear_header
local add_header   = resp.add_header
local concat       = table.concat
local ceil         = math.ceil
local max          = math.max
local find         = string.find
local gsub         = string.gsub
local sub          = string.sub
local type         = type
local pcall        = pcall
local tonumber     = tonumber
local setmetatable = setmetatable
local getmetatable = getmetatable
local bytes        = random.bytes

local COOKIE_PARTS = {
    DEFAULT = {
        n = 3,
        "id",
        "expires", -- may also contain: `expires:usebefore`
        "hash"
    },
    cookie = {
        n = 4,
        "id",
        "expires", -- may also contain: `expires:usebefore`
        "data",
        "hash",
    },
}

-- convert option to boolean
-- @param val input
-- @return `true` on `true`, "1", "on" or "true", or `nil` on `nil`, or `false` otherwise
local function enabled(value)
    if value == nil then
        return nil
    end

    return value == true
        or value == "1"
        or value == "true"
        or value == "on"
end

-- returns the input value, or the default if the input is nil
local function ifnil(value, default)
    if value == nil then
        return default
    end

    return enabled(value)
end

-- loads a module if it exists, or alternatively a default module
-- @param prefix (string) a prefix for the module name to load, eg. "resty.session.encoders."
-- @param package (string) name of the module to load
-- @param default (string) the default module name, if `package` doesn't exist
-- @return the module table, and the name of the module loaded (either package, or default)
local function prequire(prefix, package, default)
    local ok, module = pcall(require, prefix .. package)
    if not ok then
        return require(prefix .. default), default
    end

    return module, package
end


-- create and set a cookie-header.
-- @session (table) the session object for which to create the cookie
-- @value value (string) the string value to set (must be encoded already). Defaults to an empty string.
-- @value expires (boolean) if truthy, the created cookie will delete the existing session cookie.
-- @return true
local function set_cookie(session, value, expires)
    if ngx.headers_sent then
        return nil, "attempt to set session cookie after sending out response headers"
    end

    value = value or ""
    local cookie = session.cookie
    local output = {}
    local i = 3

     -- build cookie parameters, elements 1+2 will be set later
    if expires then
        -- we're expiring/deleting the data, so set an expiry in the past
        output[i] = "; Expires=Thu, 01 Jan 1970 00:00:01 GMT; Max-Age=0"
        i=i+1
    elseif cookie.persistent then
        output[i]   = "; Expires="
        output[i+1] = http_time(session.expires)
        output[i+2] = "; Max-Age="
        output[i+3] = cookie.lifetime
        i = i + 4
    end

    local cookie_domain = cookie.domain
    if cookie_domain and cookie_domain ~= "localhost" and cookie_domain ~= "" then
        output[i]   = "; Domain="
        output[i+1] = cookie_domain
        i = i + 2
    end

    output[i]   = "; Path="
    output[i+1] = cookie.path or "/"
    i = i + 2

    local cookie_samesite = cookie.samesite
    if cookie_samesite == "Lax"
    or cookie_samesite == "Strict"
    or cookie_samesite == "None"
    then
        output[i] = "; SameSite="
        output[i+1] = cookie_samesite
        i = i + 2
    end

    if cookie.secure then
        output[i] = "; Secure"
        i = i + 1
    end

    if cookie.httponly then
        output[i] = "; HttpOnly"
    end

    -- How many chunks do we need?
    local cookie_parts
    if expires and cookie.chunks then
        -- expiring cookie, so deleting data. Do not measure data, but use
        -- existing chunk count to make sure we clear all of them
        cookie_parts = cookie.chunks or 1
    else
        -- calculate required chunks from data
        cookie_parts = max(ceil(#value / cookie.maxsize), 1)
    end

    for j=1, cookie_parts do
        -- create numbered chunk names if required
        local chunk_name = { session.name }
        if j > 1 then
            chunk_name[2] = "_"
            chunk_name[3] = j
            chunk_name[4] = "="
        else
            chunk_name[2] = "="
        end
        chunk_name = concat(chunk_name)
        output[1] = chunk_name

        if expires then
            -- expiring cookie, so deleting data; clear it
            output[2] = ""
        else
            -- grab the piece for the current chunk
            local sp = j * cookie.maxsize - (cookie.maxsize - 1)
            if j < cookie_parts then
                output[2] = sub(value, sp, sp + (cookie.maxsize - 1)) .. "0"
            else
                output[2] = sub(value, sp)
            end
        end

        add_header("Set-Cookie", concat(output))
    end

    return true
end

-- sets the usebefore property.
-- @param session (table) the session object
-- @return true if the value was updated, false otherwise
local function set_usebefore(session)
    local cookie    = session.cookie
    local usebefore = cookie.usebefore or 0

    if cookie.idletime == 0 then
        cookie.usebefore = session.expires
    else
        local new_value = time() + cookie.idletime
        if new_value - usebefore > 0.1 then -- less than 0.1 sec is not a new one
            cookie.usebefore = new_value
        end
    end

    return cookie.usebefore ~= usebefore
end


-- save the session.
-- This will write to storage, and set the cookie (if returned by storage).
-- NOTE: will always RESET lifetime!
-- @param session (table) the session object
-- @param close (boolean) whether or not to close the "storage state" (unlocking locks etc)
-- @return true on success
local function save(session, close)
    session.expires = time() + session.cookie.lifetime

    set_usebefore(session)

    local cookie, err = session.strategy.save(session, close)
    if not cookie then
        return nil, err
    end

    return set_cookie(session, cookie)
end

-- touches the session. This will NOT write to storage, and set the cookie (if
-- returned by storage).
-- Updates the "usebefore" / "idletime" without changing expiry.
-- @param session (table) the session object
-- @param close (boolean) whether or not to close the "storage state" (unlocking locks etc)
-- @return true on success
local function touch(session, close)
    if set_usebefore(session) then
        -- usebefore was updated, so set cookie
        local cookie, err = session.strategy.touch(session, close)
        if cookie then
            return set_cookie(session, cookie)
        end
        return nil, err
    end
    return true
end

-- regenerates the session. Generates a new session ID.
-- @param session (table) the session object
-- @param flush (boolean) if truthy the old session will be destroyed, and data deleted
-- @return nothing
local function regenerate(session, flush)
    local session_id = session.present and session.id
    if session_id then
        if flush and session.storage.destroy then
            session.storage:destroy(session_id)
            session.data = {}
        elseif session.storage.close then
            session.storage:close(session_id)
        end
    end

    session.id = session:identifier()
end


local secret = bytes(32, true) or bytes(32)
local defaults

local function init()
    defaults = {
        name       = var.session_name       or "session",
        identifier = var.session_identifier or "random",
        strategy   = var.session_strategy   or "default",
        storage    = var.session_storage    or "cookie",
        serializer = var.session_serializer or "json",
        encoder    = var.session_encoder    or "base64",
        cipher     = var.session_cipher     or "aes",
        hmac       = var.session_hmac       or "sha1",
        cookie = {
            persistent = enabled(var.session_cookie_persistent     or false),
            discard    = tonumber(var.session_cookie_discard,  10) or 10,
            renew      = tonumber(var.session_cookie_renew,    10) or 600,
            lifetime   = tonumber(var.session_cookie_lifetime, 10) or 3600,
            idletime   = tonumber(var.session_cookie_idletime, 10) or 0,
            path       = var.session_cookie_path                   or "/",
            domain     = var.session_cookie_domain,
            samesite   = var.session_cookie_samesite               or "Lax",
            secure     = enabled(var.session_cookie_secure),
            httponly   = enabled(var.session_cookie_httponly       or true),
            delimiter  = var.session_cookie_delimiter              or "|",
            maxsize    = var.session_cookie_maxsize                or 4000
        }, check = {
            ssi    = enabled(var.session_check_ssi                 or false),
            ua     = enabled(var.session_check_ua                  or true),
            scheme = enabled(var.session_check_scheme              or true),
            addr   = enabled(var.session_check_addr                or false)
        }
    }
    defaults.secret = var.session_secret or secret
end

local session = {
    _VERSION = "3.0"
}

session.__index = session

-- read the cookie for the session object.
-- @param session (table) the session object for which to read the cookie
-- @param i (number) do not use! internal recursion variable
-- @return string with cookie data (and the property `session.cookie.chunks`
--         will be set to the actual number of chunks read)
function session:get_cookie(i)
    local cookie_name = { "cookie_", self.name }
    if i then
        cookie_name[3] = "_"
        cookie_name[4] = i
    else
        i = 1
    end

    self.cookie.chunks = i

    local cookie = var[concat(cookie_name)]
    if not cookie then
        return nil
    end

    local cookie_size = #cookie
    if cookie_size <= self.cookie.maxsize then
        return cookie
    end

    return concat{ sub(cookie, 1, self.cookie.maxsize), self:get_cookie(i + 1) or "" }
end

-- Extracts the elements from the cookie-string (string-split essentially).
-- @param value (string) the string to split in the elements
-- @return array with the elements in order or nil if expected_count does not match to split count
function session:parse_cookie(value)
    local cookie
    local parts = COOKIE_PARTS[self.storage] or COOKIE_PARTS.DEFAULT

    local count = 1
    local pos   = 1

    local match_start, match_end = find(value, self.delimiter, 1, true)
    while match_start do
        if count > (parts.n - 1) then
            return nil, "invalid cookie" -- too many elements
        end
        if not cookie then
            cookie = {}
        end

        if count == 2 then
            local cookie_part = sub(value, pos, match_end - 1)
            local colon_pos = find(cookie_part, ":", 2, true)
            if colon_pos then
                cookie.expires = tonumber(sub(cookie_part, pos, colon_pos - 1), 10)
                if not cookie.expires then
                    return nil, "invalid cookie"
                end

                if self.idletime > 0 then
                    cookie.usebefore = tonumber(sub(cookie_part, pos, colon_pos + 1), 10)
                end
            else
                cookie.expires = tonumber(cookie_part, 10)
                if not cookie.expires then
                    return nil, "invalid cookie"
                end
            end
        else
            local cookie_part = self.encoder.decode(sub(value, pos, match_end - 1))
            if not cookie_part then
                return nil, "invalid cookie"
            end

            cookie[parts[count]] = cookie_part
        end

        count = count + 1
        pos   = match_end + 1

        match_start, match_end = find(value, self.delimiter, pos, true)
    end

    if count ~= parts.n then
        return nil, "invalid cookie"
    end

    local cookie_part = self.encoder.decode(sub(value, pos))
    if not cookie_part then
        return nil, "invalid cookie"
    end

    cookie[parts[count]] = cookie_part

    if cookie.id and cookie.expires and cookie.expires > time() and cookie.hash then
        return cookie
    end

    return nil, "invalid cookie"
end


-- Constructor: creates a new session
-- @return new session object
function session.new(opts)
    if getmetatable(opts) == session then
        return opts
    end

    if not defaults then
        init()
    end

    opts = type(opts) == "table" and opts or defaults

    local cookie = opts.cookie or defaults.cookie
    local check   = opts.check or defaults.check

    local ide, iden = prequire("resty.session.identifiers.", opts.identifier or defaults.identifier, "random")
    local ser, sern = prequire("resty.session.serializers.", opts.serializer or defaults.serializer, "json")
    local enc, encn = prequire("resty.session.encoders.",    opts.encoder    or defaults.encoder,    "base64")
    local cip, cipn = prequire("resty.session.ciphers.",     opts.cipher     or defaults.cipher,     "aes")
    local sto, ston = prequire("resty.session.storage.",     opts.storage    or defaults.storage,    "cookie")
    local str, strn = prequire("resty.session.strategies.",  opts.strategy   or defaults.strategy,   "default")
    local hma, hman = prequire("resty.session.hmac.",        opts.hmac       or defaults.hmac,       "sha1")

    local self = {
        name       = opts.name   or defaults.name,
        identifier = ide,
        serializer = ser,
        strategy   = str,
        encoder    = enc,
        hmac       = hma,
        data       = opts.data   or {},
        secret     = opts.secret or defaults.secret,
        cookie = {
            storage    = ston,
            encoder    = enc,
            persistent = ifnil(cookie.persistent, defaults.cookie.persistent),
            discard    = cookie.discard        or defaults.cookie.discard,
            renew      = cookie.renew          or defaults.cookie.renew,
            lifetime   = cookie.lifetime       or defaults.cookie.lifetime,
            idletime   = cookie.idletime       or defaults.cookie.idletime,
            path       = cookie.path           or defaults.cookie.path,
            domain     = cookie.domain         or defaults.cookie.domain,
            samesite   = cookie.samesite       or defaults.cookie.samesite,
            secure     = ifnil(cookie.secure,     defaults.cookie.secure),
            httponly   = ifnil(cookie.httponly,   defaults.cookie.httponly),
            delimiter  = cookie.delimiter      or defaults.cookie.delimiter,
            maxsize    = cookie.maxsize        or defaults.cookie.maxsize,
        }, check = {
            ssi        = ifnil(check.ssi,         defaults.check.ssi),
            ua         = ifnil(check.ua,          defaults.check.ua),
            scheme     = ifnil(check.scheme,      defaults.check.scheme),
            addr       = ifnil(check.addr,        defaults.check.addr)
        }
    }
    if self.cookie.idletime > 0 and self.cookie.discard > self.cookie.idletime then
        -- if using idletime, then the discard period must be less or equal
        self.cookie.discard = self.cookie.idletime
    end

    if not self[iden] then self[iden] = opts[iden] end
    if not self[sern] then self[sern] = opts[sern] end
    if not self[encn] then self[encn] = opts[encn] end
    if not self[cipn] then self[cipn] = opts[cipn] end
    if not self[ston] then self[ston] = opts[ston] end
    if not self[strn] then self[strn] = opts[strn] end
    if not self[hman] then self[hman] = opts[hman] end

    self.cipher  = cip.new(self)
    self.storage = sto.new(self)

    return setmetatable(self, session)
end

-- Constructor: creates a new session, opening the current session
-- @return 1) new session object, 2) true if session was present
function session.open(opts)
    local self = opts
    if getmetatable(self) == session then
        if self.opened then
            return self, self.present
        end
    else
        self = session.new(opts)
    end

    if self.cookie.secure == nil then
        self.cookie.secure = var.scheme == "https" or var.https == "on"
    end

    self.key = concat{
        self.check.ssi    and var.ssl_session_id  or "",
        self.check.ua     and var.http_user_agent or "",
        self.check.addr   and var.remote_addr     or "",
        self.check.scheme and var.scheme          or "",
    }
    self.opened = true
    local cookie = self:get_cookie()
    if cookie then
        cookie = self:parse_cookie()
        if cookie and self.strategy.open(self, cookie) then
            return self, true
        end
    end
    regenerate(self, true)
    return self, false
end

-- Constructor: creates a new session, opening the current session, and
-- renews/saves the session to storage if needed.
-- @return 1) new session object, 2) true if session was present
function session.start(opts)
    if getmetatable(opts) == session and opts.started then
        return opts, opts.present
    end

    local self, present = session.open(opts)

    self.started = true

    if not present then
        return save(self)
    end

    if self.storage.start then
        local ok, err = self.storage:start(self.id)
        if not ok then
            return nil, err
        end
    end

    local now = time()
    if self.expires - now < self.cookie.renew or
       self.expires > now + self.cookie.lifetime then
        local ok, err = save(self)
        if not ok then
            return nil, err
        end
    else
        -- we're not saving, so we must touch to update idletime/usebefore
        touch(self)
    end

    return self, present
end

-- regenerates the session. Generates a new session ID and saves it.
-- @param self (table) the session object
-- @param flush (boolean) if truthy the old session will be destroyed, and data deleted
-- @return nothing
function session:regenerate(flush)
    regenerate(self, flush)

    return save(self)
end

-- save the session.
-- This will write to storage, and set the cookie (if returned by storage).
-- @param session (table) the session object
-- @param close (boolean, defaults to true) whether or not to close the "storage state" (unlocking locks etc)
-- @return true on success
function session:save(close)
    if not self.id then
        self.id = self:identifier()
    end

    return save(self, close ~= false)
end

-- Destroy the session, clear data.
-- Note: will write the new (empty) cookie
-- @return true
function session:destroy()
    if self.storage.destroy then
        self.storage:destroy(self.id)
    end

    self.data      = {}
    self.present   = nil
    self.opened    = nil
    self.started   = nil
    self.destroyed = true

    return set_cookie(self, "", true)
end

-- closes the "storage state" (unlocking locks etc)
-- @return true
function session:close()
    local id = self.present and self.id
    if id and self.storage.close then
        return self.storage:close(id)
    end

    self.closed = true

    return true
end

-- Hide the current incoming session cookie by removing it from the "Cookie"
-- header, whilst leaving other cookies in there.
-- @return nothing
function session:hide()
    local cookies = var.http_cookie
    if not cookies then
        return
    end

    local r = {}
    local n = self.name
    local i = 1
    local j = 0
    local s = find(cookies, ";", 1, true)
    while s do
        local c = sub(cookies, i, s - 1)
        local b = find(c, "=", 1, true)
        if b then
            local key = gsub(sub(c, 1, b - 1), "^%s+", "") -- strip leading whitespace
            if key ~= n and key ~= "" then
                local z = #n
                if sub(key, z + 1, z + 1) ~= "_" or not tonumber(sub(key, z + 2), 10) then
                    j = j + 1
                    r[j] = c
                end
            end
        end
        i = s + 1
        s = find(cookies, ";", i, true)
    end

    local c = sub(cookies, i)
    if c and c ~= "" then
        local b = find(c, "=", 1, true)
        if b then
            local key = gsub(sub(c, 1, b - 1), "^%s+", "")
            if key ~= n and key ~= "" then
                local z = #n
                if sub(key, z + 1, z + 1) ~= "_" or not tonumber(sub(key, z + 2), 10) then
                    j = j + 1
                    r[j] = c
                end
            end
        end
    end

    if j == 0 then
        clear_header("Cookie")
    else
        set_header("Cookie", concat(r, "; ", 1, j))
    end
end

return session

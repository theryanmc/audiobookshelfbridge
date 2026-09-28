local T = require("ffi/util").template
local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local sha2 = require("ffi/sha2")
local socketutil = require("socketutil")
local socket = require("socket")
local logger = require("logger")
local RenderImage = require("ui/renderimage")
local util = require("util")

local Settings = require("audiobookshelfbridge/settings")
local VERSION = require("audiobookshelfbridge_version")
local ErrorLog = require("audiobookshelfbridge/errorlog")
local DownloadStaging = require("audiobookshelfbridge/downloadstaging")
local _ = require("gettext")

-- D-07: raised per-group /search limit. ABS defaults this to 12 per group,
-- and because /search ignores the filter parameter entirely (see
-- getSearchResults below), audiobook-only hits consume book-group slots
-- that client-side ebook filtering then removes -- a capped 12 can whittle
-- down to a handful. 30 is roughly two and a half times the default: a
-- comfortable number of ebook hits above the fold on a 6-inch screen, while
-- bounding the growth of a response whose book entries are serialized in
-- the expanded form. A single named constant so the maintainer can tune it
-- against their own library, which is what D-07 asks for.
local SEARCH_GROUP_LIMIT = 30

-- GC-02 (extends D-13): the three named search-result groups, in check
-- order. The exact keys the browser's three group loops read.
local SEARCH_GROUP_KEYS = { "authors", "series", "book" }

-- GC-02: returns the name of the first search-result group that is
-- present but not shaped like a group, or nil when every group is
-- well-shaped. An absent group is not malformed -- it means only that
-- the group matched nothing (D-13), and a JSON null decodes to nil under
-- the simple mode this file uses, so it reads as absent too. A present
-- group of any other type is a server contract violation; coalescing it
-- to an empty table here would turn a malformed response into a silently
-- shortened result list, which is the second half of what this phase's
-- prohibition against propagating a malformed response forbids.
--
-- Two hard constraints, both inherited from decodeResponse: no logging
-- and no error recording here -- the caller does that -- and no gettext
-- call, because callers shadow the single-underscore identifier as a
-- pcall placeholder and invoking it would crash.
local function findMalformedSearchGroup(result)
    for _, key in ipairs(SEARCH_GROUP_KEYS) do
        local group = result[key]
        if group ~= nil then
            if type(group) ~= "table" then
                return key
            end
            for _, entry in ipairs(group) do
                if type(entry) ~= "table" then
                    return key
                end
            end
        end
    end
    return nil
end

local AudiobookshelfApi = {}

local USER_AGENT = T("audiobookshelfbridge.koplugin/%1", table.concat(VERSION, "."))

-- CR-F4: a trailing slash on the stored server URL produced request paths
-- like "https://host//api/..." -- concatenation never inserted a slash of
-- its own, so a second one from the stored value survived into every
-- request. Stripping every trailing slash here, and routing every read of
-- the setting through it (credentials() and testConnection() below), fixes
-- existing configs on read without ever rewriting the file; editServer also
-- normalizes on save, so newly-entered URLs are stored clean too. Returns
-- non-string input unchanged so nil keeps meaning "not configured".
local function normalizeServerUrl(server)
    if type(server) ~= "string" then
        return server
    end
    return (server:gsub("/+$", ""))
end
AudiobookshelfApi.normalizeServerUrl = normalizeServerUrl

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

-- F33-D5: mirrors common/socket/url.lua's _M.parse (the parser
-- socket.http actually uses to pick the host it dials), in the same order:
-- scheme, then the "//" authority, then userinfo removed up to the FIRST
-- "@", then a trailing port (including an empty one) stripped, then an
-- IPv6 literal unwrapped. Deliberately not a "smarter" URL parser -- one
-- that disagreed with LuaSocket's own here would let a session be bound to
-- a host the connection never actually reaches. Returns the lowercased
-- host, or nil for anything without a scheme, a "//" authority, or a
-- non-empty host.
local function serverHost(url)
    if type(url) ~= "string" then
        return nil
    end
    local rest = url:match("^[%w][%w%+%-%.]*%:(.*)$")
    if not rest then
        return nil
    end
    local authority = rest:match("^//([^/%?#]*)")
    if not authority then
        return nil
    end
    -- Userinfo removed up to the FIRST "@": the exclusion class can never
    -- itself match "@", so it stops at the first one no matter how many
    -- follow.
    local host = authority:match("^[^@]*@(.*)$") or authority
    -- A trailing port, including an empty one, is stripped here -- before
    -- the IPv6 unwrap below, so a bracketed literal's own colons are never
    -- mistaken for a port separator.
    host = host:gsub(":[^:%]]*$", "")
    host = host:match("^%[(.+)%]$") or host
    if host == "" then
        return nil
    end
    return host:lower()
end
AudiobookshelfApi.serverHost = serverHost

-- F33-D1/F33-D5: clears every session key, and only session keys -- `token`
-- and `username` are left alone so a stored API token stays usable as the
-- fallback and the username can still pre-fill the sign-in dialog. `auth`
-- is cleared first so a reader that dies mid-write never leaves the
-- session marker set over an already-cleared token.
local function clearSession()
    Settings:write("auth", nil)
    Settings:write("access_token", nil)
    Settings:write("refresh_token", nil)
    Settings:write("session_host", nil)
end

-- F33-D1: the sole place session tokens are read. Session mode requires
-- every one of: the explicit `auth == "session"` marker, both tokens
-- present as non-empty strings, and `session_host` equal to the current
-- server's host. The explicit marker is what keeps a plain server+token
-- config -- and tests/api_metadata_test.lua's Settings stub, which answers
-- every key with "test-token" -- safely in token mode. F33-D5: a host
-- mismatch (or no host at all) clears the session on this read, before any
-- request is ever built, so no token can be sent to a different server.
local function sessionTokens()
    if Settings:read("auth") ~= "session" then
        return nil
    end
    local access_token = Settings:read("access_token")
    local refresh_token = Settings:read("refresh_token")
    if not isNonEmptyString(access_token) or not isNonEmptyString(refresh_token) then
        return nil
    end
    local current_host = serverHost(normalizeServerUrl(Settings:read("server")))
    local session_host = Settings:read("session_host")
    if current_host == nil or session_host ~= current_host then
        clearSession()
        logger.warn("AudiobookshelfApi: session belongs to a different server host, signed out")
        return nil
    end
    return access_token, refresh_token
end

-- S1: the single place credentials are read. On a fresh install the config
-- file does not exist, LuaSettings hands back an empty table, and both reads
-- return nil. Every request used to concatenate those values outside its
-- pcall, so the first tap on the plugin raised "attempt to concatenate a nil
-- value" and took KOReader down -- before the user could ever reach Settings
-- to fix it. F33-D1: returns server, bearer, mode -- the session access
-- token when signed in (mode "session"), else the stored API token (mode
-- "token"), else nil when neither is usable; callers turn a nil into an
-- "unconfigured" result the browser routes to Settings. Existing two-value
-- callers keep working unchanged: `bearer` is exactly the value they used
-- to call `token`.
local function credentials()
    local server = normalizeServerUrl(Settings:read("server"))
    if not isNonEmptyString(server) then
        return nil
    end
    local access_token = sessionTokens()
    if access_token then
        return server, access_token, "session"
    end
    local token = Settings:read("token")
    if isNonEmptyString(token) then
        return server, token, "token"
    end
    return nil
end

function AudiobookshelfApi:isConfigured()
    return credentials() ~= nil
end

function AudiobookshelfApi:isSignedIn()
    return sessionTokens() ~= nil
end

-- Best-effort only: the server revoke this bounds (AudiobookshelfApi:signOut)
-- runs after the user already has their answer, so it is capped tighter
-- than the 5s/15s default rather than left open-ended.
local LOGOUT_BLOCK_TIMEOUT = 3
local LOGOUT_TOTAL_TIMEOUT = 5

-- S2: `redirect = false`. LuaSocket follows up to five redirects by default,
-- and its tredirect copies the request headers verbatim to the new location
-- (socket/http.lua) -- Authorization included. A captive-portal Wi-Fi that
-- 302s every request to its sign-in page would be handed the API token. ABS
-- /api endpoints never redirect, so a 3xx is a failure here, reported with a
-- hint to check the URL or sign in to the network.
--
-- S7: `path` must already be percent-encoded by the caller. Ids and inos come
-- from server responses and are placed into path segments, so they are encoded
-- with util.urlEncode at the call site the same way author_id always was.
local function buildRequest(server, token, path, sink)
    return {
        url = server .. path,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["User-Agent"] = USER_AGENT,
        },
        sink = sink,
        redirect = false,
    }
end

local function isRedirect(code)
    return type(code) == "number" and code >= 300 and code < 400
end

-- CR-L1: `socket.http.request` is `socket.protect`'d (common/socket/http.lua)
-- -- a transport failure (a closed connection, a DNS failure, the block or
-- total timeout expiring) never raises through that wrapper. It comes back
-- as ok == true with a string in `code` (e.g. "timeout", "connection
-- refused", "sink timeout"), and headers/status both nil. Every call site
-- below still wraps the request in its own pcall too, so a caught raise
-- (not ok) is a real bug, not a transport contract -- and is folded into
-- this same branch rather than left to fall through to the status checks,
-- where a non-numeric code compared against 200 or a redirect range would
-- always be false and silently swallow the failure.
local function isConnectionFailure(ok, code)
    return not ok or type(code) ~= "number"
end

-- Only method_name and the LuaSocket error string ever reach ErrorLog here
-- (D-J/T-e82-03): never the request table, the token, the URL, or a body.
local function connectionFailed(method_name, err)
    logger.warn("AudiobookshelfApi: http request failed in " .. method_name .. ":", err)
    ErrorLog:record(T("%1: connection failed: %2", method_name, tostring(err)))
    return nil, "connection"
end

-- The no-credentials and redirect exits, shared by every method below so the
-- log line and Recent-errors entry read the same everywhere. No gettext here:
-- callers shadow `_` as a pcall placeholder (the Phase 1 finding), so these
-- strings match the existing non-translated ErrorLog style in this file.
local function unconfigured(method_name)
    logger.warn("AudiobookshelfApi: " .. method_name .. " called before server/token were configured")
    return nil, "unconfigured"
end

local function redirected(method_name, code, status)
    logger.warn("AudiobookshelfApi: server redirected in " .. method_name .. ":", status or code)
    ErrorLog:record(T("%1: server redirected (%2). Check the server URL, or sign in to the Wi-Fi network.",
        method_name, tostring(code)))
    return nil, "redirect"
end

-- D-13: the one shared decode guard. Every JSON-decoding method routes
-- through this so a malformed or empty response can never propagate as a
-- throw (it indexes an error string) or as a silently-empty list. Placed
-- immediately after the module table declaration so it precedes every
-- caller.
--
-- Two hard constraints: neither logger.warn nor ErrorLog:record below may
-- ever be passed `response`, the decoded table, the request table, or any
-- field value -- only `method_name` and `key` -- because ErrorLog's buffer is
-- rendered on screen (errorlog.lua's own contract). And no gettext call:
-- every caller of this method shadows the single-underscore identifier as a
-- pcall placeholder, so a gettext call placed after such a line would invoke
-- the placeholder and crash at runtime (the Phase 1 finding).
function AudiobookshelfApi:decodeResponse(response, method_name, key)
    local ok, result = pcall(JSON.decode, response, JSON.decode.simple)
    if not ok or type(result) ~= "table" then
        logger.warn("AudiobookshelfApi: malformed data in " .. method_name)
        ErrorLog:record(T("%1: server sent unreadable data", method_name))
        return nil
    end
    if key == nil then
        return result
    end
    if type(result[key]) ~= "table" then
        logger.warn("AudiobookshelfApi: missing expected field", method_name, key)
        ErrorLog:record(T("%1: missing expected field", method_name))
        return nil
    end
    return result[key]
end

-- S2 applied to credentials (T-f33-03): `redirect = false`, and deliberately
-- NO Authorization header -- neither /login nor /auth/refresh needs or gets
-- one. A followed redirect here would hand the password or the refresh
-- token to whoever answered.
local function buildAuthRequest(server, path, body, sink, extra_headers)
    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
    }
    for key, value in pairs(extra_headers or {}) do
        headers[key] = value
    end
    return {
        url = server .. path,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = sink,
        redirect = false,
    }
end

-- F33-D4: local clear first (always succeeds), then a best-effort server
-- revoke. Verified against server/Auth.js: POST /logout has no auth
-- middleware at all (no passport, no rate limiter), reads
-- `x-refresh-token` (falling back to a cookie this plugin never sets),
-- invalidates only that one refresh token, and replies
-- `{ redirect_url }` -- a body this plugin never reads. `revoke` is
-- returned only when a session valid for the CURRENT host was actually
-- captured; every one of its outcomes, including a raise, is logger-only
-- and never surfaces as a value the caller could show.
function AudiobookshelfApi:signOut()
    local server = normalizeServerUrl(Settings:read("server"))
    local _access, refresh = sessionTokens()
    clearSession()
    if not isNonEmptyString(refresh) or not isNonEmptyString(server) then
        return nil
    end
    return function()
        local ok, err = pcall(function()
            socketutil:set_timeout(LOGOUT_BLOCK_TIMEOUT, LOGOUT_TOTAL_TIMEOUT)
            local sink = {}
            local request = buildAuthRequest(server, "/logout", "{}", socketutil.table_sink(sink),
                { ["x-refresh-token"] = refresh })
            local req_ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
            socketutil:reset_timeout()
            if isConnectionFailure(req_ok, code) then
                logger.warn("AudiobookshelfApi: signOut logout connection failed:", code)
            elseif isRedirect(code) or code ~= 200 then
                logger.warn("AudiobookshelfApi: signOut logout unexpected response:", status or code)
            end
        end)
        if not ok then
            logger.warn("AudiobookshelfApi: signOut logout raised:", err)
        end
    end
end

-- The password lives only in `body` and the request source built from it
-- here -- never in Settings, logger, ErrorLog, or any on-screen message.
function AudiobookshelfApi:login(username, password)
    local server = normalizeServerUrl(Settings:read("server"))
    local host = serverHost(server)
    if not host then
        logger.warn("AudiobookshelfApi: login called before a valid server URL was configured")
        return false, "unconfigured"
    end
    local body = JSON.encode({ username = username, password = password })
    local sink = {}
    socketutil:set_timeout()
    local request = buildAuthRequest(server, "/login", body, socketutil.table_sink(sink),
        { ["x-return-tokens"] = "true" })
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local response = table.concat(sink)
    socketutil:reset_timeout()
    if isConnectionFailure(ok, code) then
        logger.warn("AudiobookshelfApi: http request failed in login:", code)
        ErrorLog:record(T("login: connection failed: %1", tostring(code)))
        return false, "connection", tostring(code)
    end
    if isRedirect(code) then
        logger.warn("AudiobookshelfApi: server redirected in login:", status or code)
        ErrorLog:record(T("login: server redirected (%1)", tostring(code)))
        return false, "redirect"
    end
    if code == 401 then
        logger.warn("AudiobookshelfApi: login rejected:", status or code)
        ErrorLog:record("login: rejected (401)")
        return false, "invalid_credentials"
    end
    if code == 429 then
        logger.warn("AudiobookshelfApi: login rate limited:", status or code)
        ErrorLog:record("login: too many attempts (429)")
        return false, "rate_limited"
    end
    if code ~= 200 or response == "" then
        logger.warn("AudiobookshelfApi: cannot sign in", status or code)
        ErrorLog:record(T("login: server error: %1", tostring(status or code)))
        return false, "server", code
    end
    local decoded = self:decodeResponse(response, "login")
    if not decoded then
        return false, "unreadable"
    end
    local user = decoded.user
    -- F33-D3: a 200 without both tokens is "unsupported" -- the deprecated
    -- legacy `user.token` field is never read or stored.
    if type(user) ~= "table" or not isNonEmptyString(user.accessToken) or not isNonEmptyString(user.refreshToken) then
        logger.warn("AudiobookshelfApi: login server did not return a session")
        ErrorLog:record("login: server did not return a session")
        return false, "unsupported"
    end
    Settings:write("refresh_token", user.refreshToken)
    Settings:write("access_token", user.accessToken)
    Settings:write("session_host", host)
    Settings:write("username", username)
    -- Written LAST: an interrupted write sequence then never leaves the
    -- session marker set over incomplete tokens.
    Settings:write("auth", "session")
    return true
end

-- F33-D6: the shared refresh path. Returns the new access token on
-- success, or nil plus a reason exactly like every other API method. Never
-- calls withAuth -- there is no loop here to close. Records its own
-- ErrorLog entries (F33-D7): a refresh failure is an account-level event,
-- worth surfacing under this method's own name regardless of which request
-- triggered it.
local function refreshSession(server)
    local _access, refresh = sessionTokens()
    if not isNonEmptyString(refresh) then
        return nil, "session_expired"
    end
    local sink = {}
    socketutil:set_timeout()
    local request = buildAuthRequest(server, "/auth/refresh", "{}", socketutil.table_sink(sink),
        { ["x-refresh-token"] = refresh })
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local response = table.concat(sink)
    socketutil:reset_timeout()
    if isConnectionFailure(ok, code) then
        connectionFailed("refreshSession", code)
        return nil, "connection", tostring(code)
    end
    if isRedirect(code) then
        redirected("refreshSession", code, status)
        return nil, "redirect"
    end
    if code == 401 or code == 403 then
        clearSession()
        logger.warn("AudiobookshelfApi: refreshSession: session expired, signed out")
        ErrorLog:record("refreshSession: session expired, sign in again")
        return nil, "session_expired"
    end
    if code ~= 200 or response == "" then
        logger.warn("AudiobookshelfApi: refreshSession failed", status or code)
        ErrorLog:record(T("refreshSession: server error: %1", tostring(status or code)))
        return nil, "server", code
    end
    local decoded = AudiobookshelfApi:decodeResponse(response, "refreshSession")
    local user = decoded and decoded.user
    if type(user) ~= "table" or not isNonEmptyString(user.accessToken) or not isNonEmptyString(user.refreshToken) then
        if decoded then
            -- decodeResponse already recorded when the decode itself
            -- failed; this covers only a well-formed reply with the wrong
            -- shape.
            logger.warn("AudiobookshelfApi: refreshSession missing expected field")
            ErrorLog:record("refreshSession: missing expected field")
        end
        return nil, "unreadable"
    end
    -- The refresh token rotates on every refresh: persist it, then the
    -- access token, immediately -- before the retry that triggered this
    -- call is ever attempted.
    Settings:write("refresh_token", user.refreshToken)
    Settings:write("access_token", user.accessToken)
    return user.accessToken
end

-- Runs one GET/POST attempt with a table sink at the given timeouts and
-- returns a plain record every withAuth caller can classify and, on a
-- retry, reuse unchanged.
local function sendTable(server, token, path, block_timeout, total_timeout, prepare)
    socketutil:set_timeout(block_timeout, total_timeout)
    local sink = {}
    local request = buildRequest(server, token, path, socketutil.table_sink(sink))
    if prepare then
        prepare(request)
    end
    local ok, code, headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local body = table.concat(sink)
    socketutil:reset_timeout()
    return { ok = ok, code = code, headers = headers, status = status, body = body }
end

-- F33-D6: at most one refresh and one retry per request, no matter how the
-- retry itself turns out -- a 401 on the retry goes through the caller's
-- normal status handling, never back through here.
local function withAuth(attempt)
    local server, bearer, mode = credentials()
    if not server then
        return nil, "unconfigured"
    end
    local outcome = attempt(server, bearer)
    if mode == "session" and outcome.code == 401 then
        local new_access, reason, detail = refreshSession(server)
        if not new_access then
            return nil, reason, detail
        end
        return attempt(server, new_access)
    end
    return outcome
end

-- "unconfigured" routes through the shared unconfigured() exit (logging
-- plus the browser's Settings redirect); every other reason has already
-- been logged by refreshSession (F33-D7), so it passes straight through.
local function authFailed(method_name, reason)
    if reason == "unconfigured" then
        return unconfigured(method_name)
    end
    return nil, reason
end

function AudiobookshelfApi:getLibraries()
    local outcome, reason = withAuth(function(server, token)
        return sendTable(server, token, "/api/libraries")
    end)
    if not outcome then
        return authFailed("getLibraries", reason)
    end
    if isConnectionFailure(outcome.ok, outcome.code) then
        return connectionFailed("getLibraries", outcome.code)
    end
    if isRedirect(outcome.code) then
        return redirected("getLibraries", outcome.code, outcome.status)
    end
    if outcome.code == 200 and outcome.body ~= "" then
        local result = self:decodeResponse(outcome.body, "getLibraries", "libraries")
        if not result then
            return nil, "unreadable"
        end
        return result
    end
    logger.warn("AudiobookshelfApi: cannot get libraries", outcome.status or outcome.code)
    ErrorLog:record(T("getLibraries: server error: %1", tostring(outcome.status or outcome.code)))
    return nil, "server"
end

-- S8: page size for /items listings, and a hard stop on page count so a
-- server that keeps returning full pages can never loop this forever.
-- 100 is ABS's own web-client page size; 200 pages is 20,000 items.
local ITEMS_PAGE_SIZE = 100
local ITEMS_MAX_PAGES = 200

-- S8: walks a /items listing page by page instead of asking for the whole
-- library in one request with limit=0. A large library came back as a single
-- response that had to be held and decoded in memory in one go, on a device
-- with very little of it, with the UI stalled the entire time. Paging keeps
-- each blocking request bounded; the server sorts globally, so pages compose
-- into the same order limit=0 produced.
--
-- `base_path` is the encoded path plus its own query string, without limit or
-- page. Stops when a page comes back short or the running total reaches the
-- server's declared `total`. Same return contract as the single-request
-- methods: the results array, or nil plus a reason. AUTH-03: each page runs
-- its own withAuth + sendTable, so credentials are re-read per page and a
-- page requested after a mid-listing refresh carries the new token.
local function fetchAllPages(self, base_path, method_name)
    local all = {}
    for page = 0, ITEMS_MAX_PAGES - 1 do
        local path = base_path .. "&limit=" .. ITEMS_PAGE_SIZE .. "&page=" .. page
        local outcome, reason = withAuth(function(server, token)
            return sendTable(server, token, path, socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        end)
        if not outcome then
            return authFailed(method_name, reason)
        end
        if isConnectionFailure(outcome.ok, outcome.code) then
            return connectionFailed(method_name, outcome.code)
        end
        if isRedirect(outcome.code) then
            return redirected(method_name, outcome.code, outcome.status)
        end
        if outcome.code ~= 200 or outcome.body == "" then
            logger.warn("AudiobookshelfApi: " .. method_name .. " page", page, "failed:", outcome.status or outcome.code)
            ErrorLog:record(T("%1: server error: %2", method_name, tostring(outcome.status or outcome.code)))
            return nil, "server"
        end
        -- Whole object, not just `results`: `total` is needed to know when to
        -- stop. The shape check on `results` mirrors decodeResponse's own
        -- missing-field branch so a malformed page is reported the same way.
        local decoded = self:decodeResponse(outcome.body, method_name)
        if not decoded then
            return nil, "unreadable"
        end
        local results = decoded.results
        if type(results) ~= "table" then
            logger.warn("AudiobookshelfApi: missing expected field", method_name, "results")
            ErrorLog:record(T("%1: missing expected field", method_name))
            return nil, "unreadable"
        end
        for i = 1, #results do
            all[#all + 1] = results[i]
        end
        local total = tonumber(decoded.total)
        if #results < ITEMS_PAGE_SIZE or (total and #all >= total) then
            break
        end
    end
    return all
end

function AudiobookshelfApi:getLibraryItems(id)
    -- this is "ebooks" base64 encoded, and the URL encoded, to only return library items with ebooks
    local filters = "ebooks." .. "ZWJvb2s%3D"
    return fetchAllPages(self,
        "/api/libraries/" .. util.urlEncode(id) .. "/items?filter=" .. filters .. "&sort=media.metadata.title",
        "getLibraryItems")
end

-- D-17: the series drill-in's scoped call. `library_id` scopes the request by
-- URL path (SRCH-06); `series_id` is the value being filtered on. The filter
-- value is encoded twice -- base64 via ffi/sha2's bin_to_base64, then
-- percent-encoded via util.urlEncode -- which is the whole security control
-- on this call: ABS's filter parser base64-decodes the value after
-- URL-decoding it, and util.urlEncode percent-encodes everything outside the
-- unreserved set, so a server-supplied id containing an ampersand, a
-- question mark, a hash, or a path-traversal sequence cannot escape the
-- query value (T-03-01). Deliberately sends no `sort` parameter: the whole
-- series is fetched (paged, see fetchAllPages) and D-09's client-side
-- comparator in the browser is the single ordering authority (flagged
-- assumption A-01). Deliberately carries no `ebooks` filter term either --
-- ABS's `filter` parameter accepts exactly one filter group per request,
-- which is precisely why SRCH-07's ebook test is applied client-side against
-- the frame-cached snapshot.
function AudiobookshelfApi:getSeriesItems(library_id, series_id)
    local filters = "series." .. util.urlEncode(sha2.bin_to_base64(series_id))
    return fetchAllPages(self,
        "/api/libraries/" .. util.urlEncode(library_id) .. "/items?filter=" .. filters,
        "getSeriesItems")
end

-- D-17: the author drill-in's scoped call, copying getLibraryItem's
-- single-resource GET skeleton below. `author_id` arrives from a server
-- response and is placed into a path segment, so it is percent-encoded
-- with util.urlEncode before use -- it encodes everything outside the
-- unreserved set, including the slash and the dot, so an id carrying a
-- traversal sequence or a query separator cannot escape its segment
-- (T-03-08). Both include values are required by D-17: requesting `series`
-- alongside `items` is what makes the server compute a per-item sequence,
-- which this plan does not consume but which is cheap and keeps the
-- option open without another endpoint change.
function AudiobookshelfApi:getAuthorItems(author_id)
    -- This endpoint takes no limit parameter -- bounded only by the
    -- author's whole bibliography -- so it belongs with the other
    -- unbounded list calls at the large-content timeouts rather than the
    -- argument-less 5s/15s default.
    local outcome, reason = withAuth(function(server, token)
        return sendTable(server, token,
            "/api/authors/" .. util.urlEncode(author_id) .. "?include=items,series",
            socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end)
    if not outcome then
        return authFailed("getAuthorItems", reason)
    end
    if isConnectionFailure(outcome.ok, outcome.code) then
        return connectionFailed("getAuthorItems", outcome.code)
    end
    if isRedirect(outcome.code) then
        return redirected("getAuthorItems", outcome.code, outcome.status)
    end
    if outcome.code == 200 and outcome.body ~= "" then
        -- Keyed on "libraryItems": when `items` is included the server
        -- always sets that field, to an empty array for an author with no
        -- items, so a missing field genuinely is a malformed response
        -- (verified against server source).
        local result = self:decodeResponse(outcome.body, "getAuthorItems", "libraryItems")
        if not result then
            return nil, "unreadable"
        end
        return result
    end
    logger.warn("AudiobookshelfApi: cannot get author items", author_id, outcome.status or outcome.code)
    ErrorLog:record(T("getAuthorItems: server error: %1", tostring(outcome.status or outcome.code)))
    return nil, "server"
end

-- The library listing always uses minified metadata on current ABS servers.
-- Batch-get is a read-only POST returning the author/series ID arrays we need.
function AudiobookshelfApi:getLibraryItemsMetadata(items)
    local expanded = {}
    for first = 1, #items, ITEMS_PAGE_SIZE do
        local ids, expected = {}, {}
        for i = first, math.min(first + ITEMS_PAGE_SIZE - 1, #items) do
            ids[#ids + 1] = items[i].id
            expected[items[i].id] = true
        end
        local body = JSON.encode({ libraryItemIds = ids })
        local outcome, reason = withAuth(function(server, token)
            return sendTable(server, token, "/api/items/batch/get",
                socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT,
                function(request)
                    request.method = "POST"
                    request.headers["Content-Type"] = "application/json"
                    request.headers["Content-Length"] = tostring(#body)
                    -- A fresh source on every attempt: a consumed ltn12
                    -- source must never be resent to a retry.
                    request.source = ltn12.source.string(body)
                end)
        end)
        if not outcome then
            return authFailed("getLibraryItemsMetadata", reason)
        end
        if isConnectionFailure(outcome.ok, outcome.code) then
            return connectionFailed("getLibraryItemsMetadata", outcome.code)
        end
        if isRedirect(outcome.code) then return redirected("getLibraryItemsMetadata", outcome.code) end
        if outcome.code ~= 200 then
            ErrorLog:record("getLibraryItemsMetadata: server error " .. tostring(outcome.code))
            return nil, "server"
        end
        local result = self:decodeResponse(outcome.body, "getLibraryItemsMetadata", "libraryItems")
        if not result then return nil, "unreadable" end
        for _, item in ipairs(result) do
            local metadata = type(item) == "table" and type(item.media) == "table" and item.media.metadata
            if type(metadata) ~= "table" or not expected[item.id]
                or type(metadata.authors) ~= "table" or type(metadata.series) ~= "table" then
                ErrorLog:record("getLibraryItemsMetadata: invalid item metadata")
                return nil, "unreadable"
            end
            expanded[item.id] = item
            expected[item.id] = nil
        end
        if next(expected) then
            ErrorLog:record("getLibraryItemsMetadata: incomplete response")
            return nil, "unreadable"
        end
    end
    local ordered = {}
    for _, item in ipairs(items) do ordered[#ordered + 1] = expanded[item.id] end
    return ordered
end

function AudiobookshelfApi:getLibraryItem(id)
    local outcome, reason = withAuth(function(server, token)
        return sendTable(server, token, "/api/items/" .. util.urlEncode(id) .. "?expanded=1")
    end)
    if not outcome then
        return authFailed("getLibraryItem", reason)
    end
    if isConnectionFailure(outcome.ok, outcome.code) then
        return connectionFailed("getLibraryItem", outcome.code)
    end
    if isRedirect(outcome.code) then
        return redirected("getLibraryItem", outcome.code, outcome.status)
    end
    if outcome.code == 200 and outcome.body ~= "" then
        local result = self:decodeResponse(outcome.body, "getLibraryItem")
        if not result then
            return nil, "unreadable"
        end
        return result
    end
    logger.warn("AudiobookshelfApi: cannot get library item", id, outcome.status or outcome.code)
    ErrorLog:record(T("getLibraryItem: server error: %1", tostring(outcome.status or outcome.code)))
    return nil, "server"
end

-- CR-F5: the full return contract, so a caller can name the true failure
-- instead of a single generic message. true, code on success; otherwise
-- false, reason[, detail], where reason is one of:
--   unconfigured    -- neither a session nor an API token is usable;
--   session_expired -- AUTH-03: the session could not be renewed (401/403
--                      on /auth/refresh); the session has been cleared;
--   open_failed     -- the staging file could not be opened for writing;
--   connection      -- a transport failure (detail is the LuaSocket error
--                      string, e.g. "timeout") -- on either the download
--                      itself or the refresh attempt that preceded it;
--   redirect        -- the server answered with a 3xx;
--   server          -- any other non-200 status (detail is the numeric
--                      status);
--   incomplete      -- the transfer did not measure as complete;
--   commit_failed   -- the completed staging file could not replace the
--                      destination.
function AudiobookshelfApi:downloadFile(id, ino, filename, local_path)
    local fullpath = local_path .. "/" .. filename
    -- A-07 gap closure: the destination (fullpath) is never opened for
    -- writing and never removed anywhere in this function. The transfer
    -- streams into a staging file beside it instead, and is renamed onto
    -- the destination only after a verified-complete transfer via the
    -- staging module's commit step -- so a pre-existing good copy survives
    -- every failure mode untouched, which is what 04-UAT.md test 6 found
    -- missing. Computed once, before the first attempt, and reused
    -- unchanged by a retry (AUTH-03/AUTH-06): each attempt below truncates
    -- and discards this same path, so a 401's partial bytes are always
    -- gone before the retry -- and before the refresh in between -- ever
    -- writes to it again.
    local temp_path = DownloadStaging.tempPathFor(local_path, id, ino)

    local function attempt(server, token)
        -- D-01: ebook downloads deliberately have no whole-transfer cap --
        -- a large book on slow Wi-Fi can legitimately take longer than any
        -- fixed limit. This matches KOReader's OPDS downloader. With a
        -- negative total, socketutil.file_sink below hands back the plain
        -- ltn12 file sink; the block timeout still fails a connection that
        -- stops delivering data.
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, -1)
        local outfile, err
        if temp_path then
            -- "w" truncates: a retry never appends to a prior attempt's
            -- bytes, even if the staging file survived somehow.
            outfile, err = io.open(temp_path, "w")
        else
            err = "no_staging_path"
        end
        if not outfile then
            socketutil:reset_timeout()
            return { open_failed = true, err = err }
        end
        local request = buildRequest(server, token,
            "/api/items/" .. util.urlEncode(id) .. "/file/" .. util.urlEncode(ino) .. "/download",
            socketutil.file_sink(outfile))
        local ok, code, headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
        socketutil:reset_timeout()
        -- Belt-and-braces close on every path: the sink closes the handle
        -- only on its own clean end-of-stream signal, so a failed or
        -- stalled transfer leaves it open; a double close (the success
        -- path) is harmless, which is why this is wrapped in its own pcall.
        pcall(function() outfile:close() end)
        if isConnectionFailure(ok, code) or code ~= 200 then
            -- Every non-200 outcome discards the staging file here, before
            -- withAuth ever gets to decide whether to refresh -- so a 401's
            -- partial bytes are gone before the refresh request is even
            -- built (AUTH-06). The pre-existing destination, if any, is
            -- never touched by this branch (A-07).
            DownloadStaging.discard(temp_path)
        end
        return { ok = ok, code = code, headers = headers, status = status }
    end

    local outcome, reason, detail = withAuth(attempt)
    if not outcome then
        if reason == "unconfigured" then
            unconfigured("downloadFile")
            return false, "unconfigured"
        end
        -- Every other reason (session_expired, connection, redirect,
        -- server, unreadable) came from refreshSession, which has already
        -- logged and recorded it itself (F33-D7).
        return false, reason, detail
    end
    if outcome.open_failed then
        -- An undrivable staging path and an unopenable staging file are the
        -- same fact from the caller's side (nothing could be opened), so
        -- both fold into this one failure exit. The message names the
        -- staging path rather than the destination.
        logger.warn("AudiobookshelfApi: cannot open local file for writing:", temp_path or fullpath, outcome.err)
        ErrorLog:record(T("downloadFile: could not open local file: %1", tostring(outcome.err)))
        return false, "open_failed"
    end
    if isConnectionFailure(outcome.ok, outcome.code) then
        connectionFailed("downloadFile", outcome.code)
        return false, "connection", tostring(outcome.code)
    end
    if isRedirect(outcome.code) then
        redirected("downloadFile", outcome.code, outcome.status)
        return false, "redirect"
    end
    if outcome.code ~= 200 then
        logger.warn("AudiobookshelfApi: cannot download file:", id, ino, outcome.status or outcome.code)
        ErrorLog:record(T("downloadFile: transfer failed: %1", tostring(outcome.status or outcome.code)))
        return false, "server", outcome.code
    end
    -- GC-07/GC-10: a clean 200 is not by itself proof the whole file
    -- arrived -- a server that closes the connection cleanly after a short
    -- or empty body yields a 200 with a truncated or zero-byte payload and
    -- no error anywhere. The completeness decision now lives in the
    -- staging module's isCompleteTransfer predicate (CR-01 gap closure):
    -- it rejects a non-positive measured size unconditionally, with no
    -- dependence on any server-controlled header, then -- only if a length was declared
    -- as a number (LuaSocket lower-cases response header names, so the
    -- lowercase key below is correct) -- rejects on inequality. When the
    -- header is absent or does not parse as a number, that comparison is
    -- skipped rather than turned into an invented failure (GC-13; flagged
    -- assumption A-16: whether this endpoint sets the header on the
    -- maintainer's server version is unconfirmed, and the skip is what
    -- makes that harmless -- and, since GC-10's size test does not depend
    -- on the header, it no longer bears on correctness at all). The
    -- decision is a pure comparison over a byte count -- nothing here
    -- opens, parses, decodes, or checksums the staged file (META-04).
    local declared_length = tonumber(outcome.headers and outcome.headers["content-length"])
    local actual_size = DownloadStaging.fileSize(temp_path)
    if not DownloadStaging.isCompleteTransfer(actual_size, declared_length) then
        DownloadStaging.discard(temp_path)
        logger.warn("AudiobookshelfApi: transfer incomplete:", id, ino, "declared", declared_length, "actual", actual_size)
        ErrorLog:record(T("downloadFile: transfer incomplete: %1", tostring(actual_size)))
        return false, "incomplete"
    end
    local commit_ok, commit_reason = DownloadStaging.commit(temp_path, fullpath)
    if not commit_ok then
        -- GC-08: the staging file is deliberately left in place here -- it
        -- may be the only complete copy -- so its path is logged alongside
        -- the reason so a user whose overwrite could not be completed can
        -- find it.
        logger.warn("AudiobookshelfApi: could not replace existing file:", fullpath, commit_reason, temp_path)
        ErrorLog:record(T("downloadFile: could not replace existing file: %1", tostring(commit_reason)))
        return false, "commit_failed"
    end
    return true, outcome.code
end

function AudiobookshelfApi:getLibraryItemCover(id)
    -- Same endpoint/headers as downloadCover, which correctly uses the
    -- larger file-transfer timeouts; align this call so the Book Details
    -- cover thumbnail doesn't time out sooner than the sidecar cover write.
    local outcome, reason = withAuth(function(server, token)
        return sendTable(server, token,
            "/api/items/" .. util.urlEncode(id) .. "/cover?format=webp",
            socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end)
    -- CR-F7/OD-2: logger only in every branch below, all the way through.
    -- A cover that cannot be fetched -- whatever the reason, a transport
    -- failure, a redirect, a 404, an unrenewable session, or any other
    -- status -- must never surface in Settings -> Recent errors, which is
    -- a user-facing buffer. (refreshSession still records its own F33-D7
    -- entry on a genuine session failure; this method adds nothing more.)
    if not outcome then
        logger.warn("AudiobookshelfApi: getLibraryItemCover could not renew the session:", id, reason)
        return nil, reason
    end
    if isConnectionFailure(outcome.ok, outcome.code) then
        logger.warn("AudiobookshelfApi: http request failed in getLibraryItemCover:", outcome.code)
        return nil, outcome.code
    end
    if isRedirect(outcome.code) then
        logger.warn("AudiobookshelfApi: server redirected in getLibraryItemCover:", outcome.status or outcome.code)
        return nil
    end
    if outcome.code == 200 and outcome.body ~= "" then
        local result = RenderImage:renderImageData(outcome.body, #outcome.body)
        return result
    end
    logger.warn("AudiobookshelfApi: cannot get library item cover", id, outcome.status or outcome.code)
    -- Second value is the numeric HTTP status, so CoverCache can tell a
    -- definite 404 (D-02) from every other failure mode.
    return nil, outcome.code
end

-- Mirrors downloadFile's file-sink shape (raw bytes to disk), not
-- getLibraryItemCover's table-sink + RenderImage decode above -- the sidecar
-- cover write needs an image *file*, and decoding to a BlitBuffer and
-- re-encoding back to webp is both lossy and unsolved in this codebase
-- (META-03/META-04). Same URL, same headers as getLibraryItemCover.
function AudiobookshelfApi:downloadCover(id, local_path)
    local function attempt(server, token)
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local outfile, err = io.open(local_path, "w")
        if not outfile then
            socketutil:reset_timeout()
            return { open_failed = true, err = err }
        end
        local request = buildRequest(server, token,
            "/api/items/" .. util.urlEncode(id) .. "/cover?format=webp",
            socketutil.file_sink(outfile))
        local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
        socketutil:reset_timeout()
        -- Same close+remove cleanup on failure as downloadFile, for the
        -- same reason: the sink only closes the handle on a clean
        -- end-of-stream or its own sink timeout.
        pcall(function() outfile:close() end)
        if isConnectionFailure(ok, code) or code ~= 200 then
            os.remove(local_path)
        end
        return { ok = ok, code = code, status = status }
    end

    local outcome, reason = withAuth(attempt)
    -- OD-2: a missing/failed cover must never surface in Settings -> Recent
    -- errors, which is a user-facing buffer -- whatever the reason,
    -- including an unrenewable session (refreshSession still records its
    -- own F33-D7 entry on a genuine session failure; nothing more is added
    -- here).
    if not outcome then
        logger.warn("AudiobookshelfApi: cannot download cover, session unusable:", id, reason)
        return false
    end
    if outcome.open_failed then
        -- No ErrorLog:record here (OD-2). logger.warn only, with the item
        -- id and reason.
        logger.warn("AudiobookshelfApi: cannot open local cover file for writing:", local_path, outcome.err)
        return false
    end
    if isConnectionFailure(outcome.ok, outcome.code) or outcome.code ~= 200 then
        -- isConnectionFailure only picks the logger wording here (OD-2:
        -- still no ErrorLog either way) -- a caught raise or a non-numeric
        -- code is a transport failure, not an HTTP status.
        if isConnectionFailure(outcome.ok, outcome.code) then
            logger.warn("AudiobookshelfApi: cannot download cover, connection failed:", id, outcome.code)
        else
            logger.warn("AudiobookshelfApi: cannot download cover:", id, outcome.status or outcome.code)
        end
        -- Second value is the numeric HTTP status when the server answered,
        -- or a transport error string otherwise ("sink timeout", "timeout",
        -- or the caught error) -- CoverCache uses this to tell a definite
        -- 404 (D-02) from every other failure mode.
        return false, outcome.code
    end
    return true
end

function AudiobookshelfApi:getSearchResults(id, search_query)
    local url_encoded_search_string = util.urlEncode(search_query)
    -- The `filter` parameter that used to sit here is dead: the search
    -- controller behind this endpoint reads only the query text and the
    -- limit (verified against server source at release v2.36.0), so the
    -- plugin was paying for a parameter that did nothing. The ebook test is
    -- applied client-side against the frame-cached snapshot instead
    -- (D-15/SRCH-07).
    local outcome, reason = withAuth(function(server, token)
        -- This is a raised-limit search response on possibly-weak Wi-Fi --
        -- use the large-content timeouts rather than the argument-less
        -- 5s/15s default.
        return sendTable(server, token,
            "/api/libraries/" .. util.urlEncode(id) .. "/search?q=" .. url_encoded_search_string .. "&limit=" .. SEARCH_GROUP_LIMIT,
            socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end)
    if not outcome then
        return authFailed("getSearchResults", reason)
    end
    if isConnectionFailure(outcome.ok, outcome.code) then
        return connectionFailed("getSearchResults", outcome.code)
    end
    if isRedirect(outcome.code) then
        return redirected("getSearchResults", outcome.code, outcome.status)
    end
    if outcome.code == 200 and outcome.body ~= "" then
        -- D-13's derived rule: a search response is malformed only when the
        -- top-level decode fails or is not a table. An absent or empty
        -- group key is not malformed -- it means only that the group
        -- matched nothing -- so no key is validated here.
        local result = self:decodeResponse(outcome.body, "getSearchResults")
        if not result then
            return nil, "unreadable"
        end
        -- GC-02: each named group is checked for shape now that the value
        -- is known to be a table, before the browser ever iterates it. A
        -- present-but-wrong-typed group is a server contract violation,
        -- not an absent one, so it is reported as unreadable rather than
        -- silently coalesced to an empty list. Only a member of this
        -- file's own three-element key list ever reaches either sink
        -- below -- never a key or value read from the response.
        local malformed_group = findMalformedSearchGroup(result)
        if malformed_group then
            logger.warn("AudiobookshelfApi: malformed search group in getSearchResults", malformed_group)
            ErrorLog:record(T("getSearchResults: malformed group: %1", malformed_group))
            return nil, "unreadable"
        end
        return result
    end
    logger.warn("AudiobookshelfApi: cannot search library", id, outcome.status or outcome.code)
    ErrorLog:record(T("getSearchResults: server error: %1", tostring(outcome.status or outcome.code)))
    return nil, "server"
end

function AudiobookshelfApi:testConnection()
    -- CR-F4: normalized before the empty check, so a stored value of only
    -- slashes reads as not set rather than as a URL to dial. Kept verbatim.
    local server = normalizeServerUrl(Settings:read("server"))
    if not server or server == "" then
        local message = _("Server URL is not set")
        logger.warn("AudiobookshelfApi: testConnection called with no server URL configured")
        ErrorLog:record(message)
        return false, message
    end
    -- AUTH-05: neither a session nor an API token is usable.
    local _server, _bearer, mode = credentials()
    if not mode then
        local message = _("Sign in or set an API token first")
        logger.warn("AudiobookshelfApi: testConnection called with no sign-in or API token configured")
        ErrorLog:record(message)
        return false, message
    end
    local outcome, reason, detail = withAuth(function(req_server, token)
        return sendTable(req_server, token, "/api/me")
    end)
    if not outcome then
        local message
        if reason == "session_expired" then
            -- refreshSession already recorded this itself (F33-D7); do not
            -- record it again here.
            message = _("Your sign-in has expired. Sign in again.")
        elseif reason == "connection" then
            message = T(_("Could not reach the server (%1). Check the server URL and your Wi-Fi connection."),
                tostring(detail))
            ErrorLog:record(message)
        elseif reason == "redirect" then
            message = _("The server redirected the request instead of answering it. Check the URL (http vs https, extra path), or sign in to the Wi-Fi network first.")
            ErrorLog:record(message)
        else
            message = T(_("Could not renew your sign-in (%1). Try again in a few minutes."), tostring(detail or reason))
            ErrorLog:record(message)
        end
        return false, message
    end
    if isConnectionFailure(outcome.ok, outcome.code) then
        connectionFailed("testConnection", outcome.code)
        return false, T(_("Could not reach the server (%1). Check the server URL and your Wi-Fi connection."),
            tostring(outcome.code))
    end
    if outcome.code == 200 then
        return true, nil
    end
    if isRedirect(outcome.code) then
        -- The one place a redirect gets a full sentence: this is the check a
        -- user runs when something is wrong, so name the two usual causes.
        local message = _("The server redirected the request instead of answering it. Check the URL (http vs https, extra path), or sign in to the Wi-Fi network first.")
        logger.warn("AudiobookshelfApi: testConnection redirected:", outcome.status or outcome.code)
        ErrorLog:record(message)
        return false, message
    end
    if outcome.code == 401 then
        -- AUTH-05: a 401 here already survived withAuth's one refresh
        -- attempt (session mode) or never had a session to refresh (token
        -- mode), so this is a genuine rejection either way.
        local message = (mode == "session")
            and _("The server rejected your sign-in. Sign in again.")
            or _("Invalid or expired API token")
        logger.warn("AudiobookshelfApi: testConnection unauthorized:", outcome.status or outcome.code)
        ErrorLog:record(message)
        return false, message
    end
    if outcome.code == 404 then
        local message = _("Server reached, but it does not support this connection check. Try browsing a library instead.")
        logger.warn("AudiobookshelfApi: testConnection endpoint not found:", outcome.status or outcome.code)
        ErrorLog:record(message)
        return false, message
    end
    local message = tostring(outcome.status or outcome.code)
    logger.warn("AudiobookshelfApi: testConnection failed:", outcome.status or outcome.code)
    ErrorLog:record(T("testConnection: unexpected error: %1", message))
    return false, message
end

return AudiobookshelfApi

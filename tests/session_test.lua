-- Run: luajit tests/session_test.lua
--
-- Drives the real audiobookshelfbridge/api, audiobookshelfbridge/settingsmenu
-- and audiobookshelfbridge/browser against a stubbed socket.http and a
-- table-backed Settings, in the style of tests/transport_test.lua and
-- tests/api_metadata_test.lua. Covers AUTH-01 through AUTH-08: sign-in,
-- session precedence and host binding, refresh-and-retry, sign-out
-- ordering, and the secret-hygiene invariant (F33-D1 through F33-D9).

package.loaded["ffi/util"] = {
    template = function(text, ...)
        local args = { ... }
        return (text:gsub("%%(%d)", function(d)
            return tostring(args[tonumber(d)])
        end))
    end,
}

package.loaded.ltn12 = {
    source = {
        -- Yields the body exactly once, then nil -- the real ltn12 source
        -- contract. A retried POST must build a fresh source; a consumed
        -- one returning nil forever would prove a stale source was reused.
        string = function(body)
            local sent = false
            return function()
                if sent then return nil end
                sent = true
                return body
            end
        end,
    },
}

package.loaded.socket = { skip = function(_, ...) return select(2, ...) end }

local timeout_active = false
local reset_count = 0
package.loaded.socketutil = {
    set_timeout = function() timeout_active = true end,
    reset_timeout = function() timeout_active = false; reset_count = reset_count + 1 end,
    table_sink = function(t)
        assert(timeout_active, "sink built before set_timeout")
        return function(data) if data then t[#t + 1] = data end; return true end
    end,
    file_sink = function(outfile)
        return function(data) if data then outfile:write(data) end; return true end
    end,
}

package.loaded["ffi/sha2"] = {}
package.loaded.util = {
    urlEncode = function(s) return s end,
    getSafeFilename = function(name) return name end,
    getFriendlySize = function(n) return tostring(n) end,
}
package.loaded["ui/renderimage"] = {
    renderImageData = function(_self, _data, _len) return "sentinel-image" end,
}
package.loaded.gettext = function(text) return text end

local logger_calls = {}
package.loaded.logger = {
    warn = function(...) table.insert(logger_calls, { ... }) end,
    dbg = function() end,
}

-- AUTH-06: downloadstaging.lua has zero requires, so the REAL module is
-- loaded here (not stubbed) against a throwaway directory -- this is what
-- lets the download tests below assert real byte survival on disk.
local STAGING_DIR = os.tmpname()
os.remove(STAGING_DIR)
os.execute("mkdir -p " .. STAGING_DIR)
local DownloadStaging = dofile("audiobookshelfbridge/downloadstaging.lua")
package.loaded["audiobookshelfbridge/downloadstaging"] = DownloadStaging

-- Settings: a table-backed store. write(key, nil) deletes, matching
-- LuaSettings:saveSetting(key, nil). Every written key is appended to
-- write_order, so login's "auth written last" contract is checkable.
local settings_table = {}
local write_order = {}
package.loaded["audiobookshelfbridge/settings"] = {
    read = function(_self, key, default)
        local v = settings_table[key]
        if v == nil then return default end
        return v
    end,
    write = function(_self, key, value)
        if value == nil then
            settings_table[key] = nil
        else
            settings_table[key] = value
        end
        table.insert(write_order, key)
    end,
}

-- ErrorLog: unbounded list, like transport_test.lua -- this file wants to
-- see every record, not just the most recent 20.
local error_log = {}
package.loaded["audiobookshelfbridge/errorlog"] = {
    record = function(_self, message) table.insert(error_log, tostring(message)) end,
    getRecent = function(_self) return error_log end,
}

-- JSON: encode records the table it was handed (so login's body can be
-- checked for shape) and returns a deterministic placeholder string --
-- never the real credentials, so nothing sensitive round-trips through a
-- string comparison by accident. decode is a callable table with a
-- `simple` field (JSON.decode.simple), mapping sentinel body strings to a
-- freshly-built Lua table per call.
local encode_calls = {}
local SIMPLE_BODIES = {
    LOGIN_OK = function() return { user = { accessToken = "ACCESS-ONE", refreshToken = "REFRESH-ONE" } } end,
    LOGIN_LEGACY = function() return { user = { token = "legacy-non-expiring-token" } } end,
    REFRESH_OK = function() return { user = { accessToken = "ACCESS-TWO", refreshToken = "REFRESH-TWO" } } end,
    LIBS = function() return { libraries = { { id = "lib1", name = "Library One" } } } end,
    ITEM = function() return { id = "item1", title = "Item One" } end,
}
package.loaded.json = {
    encode = function(t)
        table.insert(encode_calls, t)
        return "ENCODED-BODY-" .. tostring(#encode_calls)
    end,
    decode = setmetatable({ simple = true }, {
        __call = function(_self, body)
            local builder = SIMPLE_BODIES[body]
            if not builder then
                error("session_test: unhandled decode body " .. tostring(body))
            end
            return builder()
        end,
    }),
}

-- The http stub: routes on the URL suffix, asserts the request-shape
-- facts from the plan's behavior block (redirect=false, no Authorization
-- on /login and /auth/refresh, the right header on each), and returns
-- per-endpoint canned outcomes driven by mode variables the test flips.
local LOGIN_MODE = "ok"
local REFRESH_MODE = "ok"
local LOGOUT_MODE = "ok"
local LIBS_RESPONSES = {}

local login_requests, refresh_requests, libs_requests, logout_requests = {}, {}, {}, {}

local function bodyOf(request)
    return request.source and request.source() or nil
end

local function loginResponse(request)
    table.insert(login_requests, request)
    assert(request.method == "POST")
    assert(request.redirect == false)
    assert(request.headers["Authorization"] == nil, "login must never carry an Authorization header")
    assert(request.headers["x-return-tokens"] == "true")
    assert(request.headers["Content-Type"] == "application/json")
    assert(tonumber(request.headers["Content-Length"]) == #bodyOf(request))
    if LOGIN_MODE == "timeout" then return nil, "timeout" end
    if LOGIN_MODE == "raised" then error("transport failed") end
    if LOGIN_MODE == "redirect" then return 1, 302 end
    if LOGIN_MODE == "401" then return 1, 401 end
    if LOGIN_MODE == "429" then return 1, 429 end
    if LOGIN_MODE == "server" then return 1, 500 end
    if LOGIN_MODE == "legacy" then request.sink("LOGIN_LEGACY"); return 1, 200 end
    if LOGIN_MODE == "ok" then request.sink("LOGIN_OK"); return 1, 200 end
    error("session_test: unhandled LOGIN_MODE " .. tostring(LOGIN_MODE))
end

local function refreshResponse(request)
    table.insert(refresh_requests, request)
    assert(request.method == "POST")
    assert(request.redirect == false)
    assert(request.headers["Authorization"] == nil, "refresh must never carry an Authorization header")
    assert(type(request.headers["x-refresh-token"]) == "string" and request.headers["x-refresh-token"] ~= "")
    if REFRESH_MODE == "timeout" then return nil, "timeout" end
    if REFRESH_MODE == "401" then return 1, 401 end
    if REFRESH_MODE == "403" then return 1, 403 end
    if REFRESH_MODE == "429" then return 1, 429 end
    if REFRESH_MODE == "ok" then request.sink("REFRESH_OK"); return 1, 200 end
    error("session_test: unhandled REFRESH_MODE " .. tostring(REFRESH_MODE))
end

local function logoutResponse(request)
    table.insert(logout_requests, request)
    assert(request.method == "POST")
    assert(request.redirect == false)
    assert(request.headers["Authorization"] == nil, "logout must never carry an Authorization header")
    assert(type(request.headers["x-refresh-token"]) == "string" and request.headers["x-refresh-token"] ~= "")
    assert(not request.url:find("allDevices", 1, true))
    if LOGOUT_MODE == "timeout" then return nil, "timeout" end
    if LOGOUT_MODE == "raised" then error("transport failed") end
    if LOGOUT_MODE == "redirect" then return 1, 302 end
    if LOGOUT_MODE == "server" then return 1, 500 end
    if LOGOUT_MODE == "ok" then return 1, 200 end
    error("session_test: unhandled LOGOUT_MODE " .. tostring(LOGOUT_MODE))
end

local function libsResponse(request)
    table.insert(libs_requests, request)
    assert(request.method == "GET")
    local resp = table.remove(LIBS_RESPONSES, 1) or { mode = "ok" }
    if resp.mode == "401" then return 1, 401 end
    if resp.mode == "ok" then request.sink("LIBS"); return 1, 200 end
    error("session_test: unhandled libs response mode " .. tostring(resp.mode))
end

-- Task 2 additions: getLibraryItem, downloadFile, downloadCover and
-- testConnection each hit their own endpoint.
local ITEM_RESPONSES, DOWNLOAD_MODE, COVER_MODE, ME_MODE = {}, "ok", "ok", "ok"
local item_requests, download_requests, cover_requests, me_requests = {}, {}, {}, {}
-- Set to a staging path before a scenario that must prove the file is gone
-- by the time the refresh request is sent (AUTH-06).
local EXPECT_STAGING_GONE = nil

local function itemResponse(request)
    table.insert(item_requests, request)
    assert(request.method == "GET")
    local resp = table.remove(ITEM_RESPONSES, 1) or { mode = "ok" }
    if resp.mode == "401" then return 1, 401 end
    if resp.mode == "ok" then request.sink("ITEM"); return 1, 200 end
    error("session_test: unhandled item response mode " .. tostring(resp.mode))
end

local function downloadResponse(request)
    table.insert(download_requests, request)
    assert(request.method == "GET")
    if DOWNLOAD_MODE == "unauthorized" then
        request.sink("UNAUTHORIZED")
        return 1, 401
    end
    if DOWNLOAD_MODE == "timeout" then return nil, "timeout" end
    if DOWNLOAD_MODE == "ok" then
        request.sink("EPUBDATA")
        return 1, 200
    end
    error("session_test: unhandled DOWNLOAD_MODE " .. tostring(DOWNLOAD_MODE))
end

local function coverResponse(request)
    table.insert(cover_requests, request)
    assert(request.method == "GET")
    if COVER_MODE == "unauthorized" then return 1, 401 end
    if COVER_MODE == "ok" then request.sink("COVERBYTES"); return 1, 200 end
    error("session_test: unhandled COVER_MODE " .. tostring(COVER_MODE))
end

local function meResponse(request)
    table.insert(me_requests, request)
    assert(request.method == "GET")
    if ME_MODE == "401" then return 1, 401 end
    if ME_MODE == "ok" then return 1, 200 end
    error("session_test: unhandled ME_MODE " .. tostring(ME_MODE))
end

package.loaded["socket.http"] = {
    request = function(request)
        local url = request.url
        if url:find("/login", 1, true) then
            return loginResponse(request)
        elseif url:find("/auth/refresh", 1, true) then
            -- AUTH-06: whichever download scenario is currently proving
            -- "discarded before the refresh" gets checked right here,
            -- before the refresh's own response is even decided.
            if EXPECT_STAGING_GONE then
                assert(not io.open(EXPECT_STAGING_GONE, "r"),
                    "the staging file must be discarded before the refresh request is sent")
            end
            return refreshResponse(request)
        elseif url:find("/logout", 1, true) then
            return logoutResponse(request)
        elseif url:find("/file/", 1, true) then
            return downloadResponse(request)
        elseif url:find("/cover", 1, true) then
            return coverResponse(request)
        elseif url:find("/api/items/", 1, true) then
            return itemResponse(request)
        elseif url:find("/api/me", 1, true) then
            return meResponse(request)
        elseif url:find("/api/libraries", 1, true) then
            return libsResponse(request)
        end
        error("session_test: unhandled URL " .. tostring(url))
    end,
}

-- UI stubs -------------------------------------------------------------

local ui_events = {}
package.loaded["ui/uimanager"] = {
    show = function(_self, widget, _refresh) table.insert(ui_events, { "show", widget }) end,
    close = function(_self, widget) table.insert(ui_events, { "close", widget }) end,
    nextTick = function(_self, fn) fn() end,
    forceRePaint = function(_self) table.insert(ui_events, { "forceRePaint" }) end,
    scheduleIn = function(_self, _delay, fn) fn() end,
    broadcastEvent = function(_self, _event) end,
    setDirty = function(_self, ...) end,
}

local infomessage_calls = {}
package.loaded["ui/widget/infomessage"] = {
    new = function(_self, t) table.insert(infomessage_calls, t); return t end,
}

local confirmbox_calls = {}
package.loaded["ui/widget/confirmbox"] = {
    new = function(_self, t) table.insert(confirmbox_calls, t); return t end,
}

local multiinput_calls = {}
local SCRIPTED_FIELDS = { "", "" }
package.loaded["ui/widget/multiinputdialog"] = {
    new = function(_self, t)
        table.insert(multiinput_calls, t)
        t.getFields = function() return SCRIPTED_FIELDS end
        t.onClose = function() end
        t.onShowKeyboard = function() end
        return t
    end,
}

package.loaded["ui/widget/inputdialog"] = { new = function(_self, t) return t end }
package.loaded["ui/widget/textviewer"] = { new = function(_self, t) return t end }

-- Widget base, following tests/librarytabs_test.lua's precedent: extend()
-- returns a table whose metatable __index chains to the base, new()
-- builds and calls init() when present.
local Widget = {}
function Widget:extend(fields) return setmetatable(fields or {}, { __index = self }) end
function Widget:new(fields)
    local obj = self:extend(fields)
    if obj.init then obj:init() end
    return obj
end
function Widget:switchItemTable(title, rows)
    self.item_table = rows
    self.title = title
end
function Widget:init() end
package.loaded["ui/widget/menu"] = Widget

-- NetworkMgr: defines ONLY isConnected, driven by a mode variable.
-- Calling any other method fails the test -- proof that no Wi-Fi-prompting
-- path (runWhenOnline, willRerunWhenOnline, isOnline) is ever used by the
-- sign-out flow.
local NETWORK_MODE = "connected"
package.loaded["ui/network/manager"] = setmetatable({
    isConnected = function(_self)
        if NETWORK_MODE == "raise" then error("network check must not be needed here") end
        return NETWORK_MODE == "connected"
    end,
}, {
    __index = function(_t, key)
        error("session_test: NetworkMgr." .. tostring(key) .. " must never be called (no Wi-Fi prompt path)")
    end,
})

_G.G_reader_settings = { readSetting = function() return nil end }

-- ------------------------------------------------------------------
-- Load the real modules.
-- ------------------------------------------------------------------

local Api = require("audiobookshelfbridge/api")
local SettingsMenu = require("audiobookshelfbridge/settingsmenu")

local function resetAll()
    settings_table = {}
    write_order = {}
    package.loaded["audiobookshelfbridge/settings"].read = function(_self, key, default)
        local v = settings_table[key]
        if v == nil then return default end
        return v
    end
    package.loaded["audiobookshelfbridge/settings"].write = function(_self, key, value)
        if value == nil then settings_table[key] = nil else settings_table[key] = value end
        table.insert(write_order, key)
    end
    login_requests, refresh_requests, libs_requests, logout_requests = {}, {}, {}, {}
    item_requests, download_requests, cover_requests, me_requests = {}, {}, {}, {}
    LIBS_RESPONSES = {}
    ITEM_RESPONSES = {}
    EXPECT_STAGING_GONE = nil
    ui_events = {}
    infomessage_calls = {}
    confirmbox_calls = {}
    multiinput_calls = {}
    -- GKC-D3: drain any pending fallback notice so it never leaks between
    -- scenarios.
    Api:takeFallbackNotice()
end

-- 1. serverHost -----------------------------------------------------

assert(Api.serverHost("https://books.example.com") == "books.example.com")
assert(Api.serverHost("http://Books.Example.COM:8080/abs/") == "books.example.com")
assert(Api.serverHost("https://books.example.com:443") == "books.example.com")
assert(Api.serverHost("https://user:secret@books.example.com/") == "books.example.com")
assert(Api.serverHost("http://[::1]:13378") == "::1")
assert(Api.serverHost("http://[::1]") == "::1")
assert(Api.serverHost("http://[2001:DB8::1]/abs") == "2001:db8::1")
assert(Api.serverHost("http://192.168.1.10:13378") == "192.168.1.10")
assert(Api.serverHost("https://a@b@host.example") == "b@host.example")
assert(Api.serverHost("https://host.example:") == "host.example")
assert(Api.serverHost("books.example.com") == nil)
assert(Api.serverHost("https://") == nil)
assert(Api.serverHost("https:books") == nil)
assert(Api.serverHost(nil) == nil)
assert(Api.serverHost("") == nil)
print("PASS: serverHost mirrors socket/url.lua's parse and lowercases the result")

-- 2. login success ----------------------------------------------------

resetAll()
settings_table.server = "https://Books.Example.com/"
settings_table.token = "APITOKEN-SECRET"
LOGIN_MODE = "ok"

local login_ok = Api:login("alice", "PASSWORD-SECRET")
assert(login_ok == true)
assert(#login_requests == 1)
assert(encode_calls[#encode_calls].username == "alice")
assert(encode_calls[#encode_calls].password == "PASSWORD-SECRET")
assert(settings_table.access_token == "ACCESS-ONE")
assert(settings_table.refresh_token == "REFRESH-ONE")
assert(settings_table.session_host == "books.example.com")
assert(settings_table.username == "alice")
assert(settings_table.auth == "session")
assert(settings_table.token == "APITOKEN-SECRET", "an existing API token must survive sign-in (F33-D2)")
-- auth is written last among this call's writes.
local auth_index
for i = #write_order, 1, -1 do
    if write_order[i] == "auth" then auth_index = i; break end
end
assert(auth_index == #write_order, "auth must be the last key written on a successful sign-in")
assert(Api:isSignedIn() == true)
print("PASS: login writes refresh/access/session_host/username then auth last, keeps an existing API token")

-- No server configured: zero requests, no writes.
resetAll()
settings_table.server = "https://"
local ok_unconf, reason_unconf = Api:login("alice", "x")
assert(ok_unconf == false and reason_unconf == "unconfigured")
assert(#login_requests == 0)
assert(next(settings_table) == nil or settings_table.server ~= nil)
print("PASS: login with no valid server host sends zero requests")

-- 3. login failure modes, each writes nothing ---------------------------

local LOGIN_FAILURES = {
    ["401"] = "invalid_credentials",
    ["429"] = "rate_limited",
    ["timeout"] = "connection",
    ["redirect"] = "redirect",
    ["server"] = "server",
    ["legacy"] = "unsupported",
}
for mode, expected_reason in pairs(LOGIN_FAILURES) do
    resetAll()
    settings_table.server = "https://books.example.com"
    LOGIN_MODE = mode
    local ok, reason = Api:login("alice", "PASSWORD-SECRET")
    assert(ok == false, mode)
    assert(reason == expected_reason, mode .. ": got " .. tostring(reason))
    assert(settings_table.auth == nil, mode .. ": must write nothing on failure")
    assert(settings_table.access_token == nil, mode)
end
LOGIN_MODE = "ok"
print("PASS: every login failure mode reports its own reason and writes no Settings key")

-- 4. precedence and host binding ----------------------------------------

resetAll()
settings_table.server = "https://books.example.com"
settings_table.token = "APITOKEN-SECRET"
Api:login("alice", "PASSWORD-SECRET")
assert(Api:isSignedIn())

LIBS_RESPONSES = { { mode = "ok" } }
Api:getLibraries()
assert(libs_requests[#libs_requests].headers["Authorization"] == "Bearer ACCESS-ONE",
    "session mode must send the access token, not the API token")

-- Same host, different scheme/port/path: session survives.
settings_table.server = "http://books.example.com:8080/abs/"
assert(Api:isSignedIn())
LIBS_RESPONSES = { { mode = "ok" } }
Api:getLibraries()
assert(libs_requests[#libs_requests].headers["Authorization"] == "Bearer ACCESS-ONE")

settings_table.server = "https://BOOKS.example.com:443"
assert(Api:isSignedIn())

-- Different host: session is cleared on the very next read.
settings_table.server = "https://other.example.com"
assert(not Api:isSignedIn())
assert(settings_table.auth == nil and settings_table.access_token == nil
    and settings_table.refresh_token == nil and settings_table.session_host == nil)
assert(settings_table.username == "alice" and settings_table.token == "APITOKEN-SECRET",
    "username and API token survive a host mismatch")

LIBS_RESPONSES = { { mode = "ok" } }
Api:getLibraries()
assert(libs_requests[#libs_requests].headers["Authorization"] == "Bearer APITOKEN-SECRET",
    "after a host mismatch, getLibraries falls back to the API token")
for _, req in ipairs(libs_requests) do
    assert(not (req.headers["Authorization"] or ""):find("ACCESS", 1, true)
        or req.headers["Authorization"] == "Bearer ACCESS-ONE", "no ACCESS token ever reaches another host")
end
print("PASS: a session survives scheme/port/path changes on the same host, clears on a different host")

-- 5. refresh-and-retry, no loop, and session_expired ---------------------

local function signInFreshSession()
    resetAll()
    settings_table.server = "https://books.example.com"
    LOGIN_MODE = "ok"
    assert(Api:login("alice", "PASSWORD-SECRET"))
end

signInFreshSession()
LIBS_RESPONSES = { { mode = "401" }, { mode = "ok" } }
REFRESH_MODE = "ok"
local libs, libs_reason = Api:getLibraries()
assert(libs and libs[1].id == "lib1")
assert(#libs_requests == 2 and #refresh_requests == 1, "expected exactly 3 http calls total")
assert(libs_requests[1].headers["Authorization"] == "Bearer ACCESS-ONE")
assert(libs_requests[2].headers["Authorization"] == "Bearer ACCESS-TWO", "the retry must use the rotated token")
assert(settings_table.access_token == "ACCESS-TWO" and settings_table.refresh_token == "REFRESH-TWO")

-- A later forced 401 refreshes with the rotated (REFRESH-TWO) token.
LIBS_RESPONSES = { { mode = "401" }, { mode = "ok" } }
Api:getLibraries()
assert(refresh_requests[#refresh_requests].headers["x-refresh-token"] == "REFRESH-TWO")
print("PASS: a 401 triggers exactly one refresh, one retry, and the rotated token is used next time")

-- No loop: the retry also gets a 401.
signInFreshSession()
LIBS_RESPONSES = { { mode = "401" }, { mode = "401" } }
REFRESH_MODE = "ok"
local no_loop_result, no_loop_reason = Api:getLibraries()
assert(no_loop_result == nil and no_loop_reason == "server")
assert(#libs_requests == 2 and #refresh_requests == 1, "must never refresh twice for one request")
print("PASS: a 401 on the retry is never refreshed again")

-- refresh 401 / 403 clear the session and report session_expired.
for _, refresh_mode in ipairs({ "401", "403" }) do
    signInFreshSession()
    LIBS_RESPONSES = { { mode = "401" } }
    REFRESH_MODE = refresh_mode
    local result, reason = Api:getLibraries()
    assert(result == nil and reason == "session_expired", refresh_mode)
    assert(#libs_requests == 1 and #refresh_requests == 1, refresh_mode)
    assert(settings_table.auth == nil and settings_table.access_token == nil
        and settings_table.refresh_token == nil and settings_table.session_host == nil, refresh_mode)
    assert(settings_table.username == "alice", refresh_mode .. ": username must survive")
end
REFRESH_MODE = "ok"
print("PASS: refresh 401/403 clears the session, keeps username, reason session_expired, exactly 2 calls")

-- refresh timeout / 429 keep the session.
for _, refresh_mode in ipairs({ "timeout", "429" }) do
    signInFreshSession()
    LIBS_RESPONSES = { { mode = "401" } }
    REFRESH_MODE = refresh_mode
    local result, reason = Api:getLibraries()
    assert(result == nil, refresh_mode)
    assert(reason == (refresh_mode == "timeout" and "connection" or "server"), refresh_mode .. ": " .. tostring(reason))
    assert(settings_table.auth == "session", refresh_mode .. ": session must be kept")
end
REFRESH_MODE = "ok"
print("PASS: a flaky refresh (timeout/429) keeps the session")

-- Token-only config: a 401 is reported exactly as today, no refresh.
resetAll()
settings_table.server = "https://books.example.com"
settings_table.token = "APITOKEN-SECRET"
LIBS_RESPONSES = { { mode = "401" } }
local token_result, token_reason = Api:getLibraries()
assert(token_result == nil and token_reason == "server")
assert(#libs_requests == 1 and #refresh_requests == 0)
print("PASS: a token-only config never triggers a refresh on a 401")

-- 6. SettingsMenu rows and the sign-in dialog -----------------------------

resetAll()
settings_table.server = "https://books.example.com"
local menu = SettingsMenu:new{}
local function rowOfType(rows, type_name)
    for _, row in ipairs(rows) do
        if row.type == type_name then return row end
    end
    return nil
end
assert(rowOfType(menu.item_table, "sign_in").text == "Sign in with username and password")
assert(rowOfType(menu.item_table, "sign_out") == nil)

menu:onMenuSelect({ type = "sign_in" })
local dialog = multiinput_calls[#multiinput_calls]
assert(dialog.fields[1].text == "" and dialog.fields[2].text == "" and dialog.fields[2].text_type == "password")

-- Empty username: no request.
SCRIPTED_FIELDS = { "", "" }
local function findButton(t, text)
    for _, row in ipairs(t.buttons) do
        for _, button in ipairs(row) do
            if button.text == text then return button end
        end
    end
end
findButton(dialog, "Sign in").callback()
assert(#login_requests == 0, "an empty username must send no request")

SCRIPTED_FIELDS = { "alice", "PASSWORD-SECRET" }
LOGIN_MODE = "ok"
findButton(dialog, "Sign in").callback()
assert(#login_requests == 1)
assert(infomessage_calls[#infomessage_calls].text:find("alice", 1, true))
assert(settings_table.auth == "session")

-- http:// server adds the password-field warning.
resetAll()
settings_table.server = "http://books.example.com"
local http_menu = SettingsMenu:new{}
http_menu:onMenuSelect({ type = "sign_in" })
local http_dialog = multiinput_calls[#multiinput_calls]
assert(http_dialog.fields[2].description ~= nil)

-- Each sign-in failure reason gets its own message.
local seen_texts = {}
for _, reason in ipairs({ "unconfigured", "invalid_credentials", "rate_limited", "connection",
        "redirect", "server", "unreadable", "unsupported", "totally_unknown" }) do
    local text = SettingsMenu.signInFailureText(reason, "detail")
    assert(type(text) == "string" and #text > 0, reason)
    assert(not seen_texts[text], "duplicate message for " .. reason)
    seen_texts[text] = true
end
print("PASS: Settings rows, the sign-in dialog, and per-reason failure messages")

-- 7. Sign out ordering and gating ----------------------------------------

signInFreshSession()
local signed_in_menu = SettingsMenu:new{}
assert(rowOfType(signed_in_menu.item_table, "sign_out"))
NETWORK_MODE = "connected"
LOGOUT_MODE = "ok"
ui_events = {}
infomessage_calls = {}
confirmbox_calls = {}
signed_in_menu:onMenuSelect({ type = "sign_out" })
local confirm = confirmbox_calls[#confirmbox_calls]
assert(confirm.text and confirm.ok_text == "Sign out")
confirm.ok_callback()
assert(settings_table.auth == nil, "the session must be cleared before the /logout call is even attempted")
assert(#logout_requests == 1)
assert(logout_requests[1].headers["x-refresh-token"] == "REFRESH-ONE")
-- The "Signed out" message and the forceRePaint must both precede the
-- /logout call in ui_events order; there is no direct event for the
-- logout call itself, so this is checked by controlling MODE so signOut's
-- work happens synchronously inside nextTick, after the InfoMessage show.
local show_idx, repaint_idx
for i, ev in ipairs(ui_events) do
    if ev[1] == "show" and ev[2] and ev[2].text == "Signed out" then show_idx = i end
    if ev[1] == "forceRePaint" then repaint_idx = i end
end
assert(show_idx and repaint_idx and show_idx < repaint_idx,
    "the result message must be shown before the best-effort revoke runs")
print("PASS: sign out clears locally and shows its message before the best-effort /logout call")

-- Sign out best-effort failures: session stays cleared, no new ErrorLog
-- entries, same message shown.
for _, logout_mode in ipairs({ "timeout", "redirect", "server", "raised" }) do
    signInFreshSession()
    NETWORK_MODE = "connected"
    LOGOUT_MODE = logout_mode
    local before_errors = #error_log
    infomessage_calls = {}
    local m = SettingsMenu:new{}
    m:onMenuSelect({ type = "sign_out" })
    confirmbox_calls[#confirmbox_calls].ok_callback()
    assert(settings_table.auth == nil, logout_mode)
    assert(#error_log == before_errors, logout_mode .. ": logout failures must never reach Recent errors")
    assert(infomessage_calls[1].text == "Signed out", logout_mode)
end
LOGOUT_MODE = "ok"
print("PASS: every best-effort logout failure is silent to the user and to Recent errors")

-- Sign out while not connected, and while the check itself raises: zero
-- requests, session still cleared, message still shown.
for _, network_mode in ipairs({ "disconnected", "raise" }) do
    signInFreshSession()
    NETWORK_MODE = network_mode == "disconnected" and "disconnected" or "raise"
    logout_requests = {}
    infomessage_calls = {}
    local m = SettingsMenu:new{}
    m:onMenuSelect({ type = "sign_out" })
    confirmbox_calls[#confirmbox_calls].ok_callback()
    assert(#logout_requests == 0, network_mode)
    assert(settings_table.auth == nil, network_mode)
    assert(infomessage_calls[1].text == "Signed out", network_mode)
end
NETWORK_MODE = "connected"
print("PASS: sign out with no connectivity (or a raising check) sends no request and never prompts for Wi-Fi")

-- No valid session: signOut returns nil, nothing is ever sent.
resetAll()
settings_table.server = "https://books.example.com"
settings_table.token = "APITOKEN-SECRET"
assert(Api:signOut() == nil)
assert(#logout_requests == 0)
print("PASS: signOut with no session to revoke sends nothing")

-- 8. Task 2: every remaining request, both file sinks, and Test connection
--    renew an expired session exactly once and retry exactly once. -------

-- getLibraryItem (representative of getAuthorItems/getSearchResults/
-- getLibraryItemsMetadata, which all share the exact same withAuth +
-- sendTable attempt shape already proven end-to-end via getLibraries).
signInFreshSession()
ITEM_RESPONSES = { { mode = "401" }, { mode = "ok" } }
REFRESH_MODE = "ok"
local item_result = Api:getLibraryItem("item1")
assert(item_result and item_result.id == "item1")
assert(#item_requests == 2 and #refresh_requests == 1)
assert(item_requests[1].headers["Authorization"] == "Bearer ACCESS-ONE")
assert(item_requests[2].headers["Authorization"] == "Bearer ACCESS-TWO")
print("PASS: getLibraryItem renews an expired access token once and retries once")

-- downloadFile: first-attempt 401, discarded before the refresh, retry
-- writes the real file, no staging file survives.
signInFreshSession()
DOWNLOAD_MODE = "unauthorized"
REFRESH_MODE = "ok"
local dest_path = STAGING_DIR .. "/book.epub"
local expected_temp = DownloadStaging.tempPathFor(STAGING_DIR, "item1", "ino1")
EXPECT_STAGING_GONE = expected_temp
download_requests = {}
-- Flip to "ok" only for the retry: the http stub dispatch already routed
-- the first attempt through "unauthorized" above by the time this line
-- runs (both attempts share DOWNLOAD_MODE, so the retry must see "ok").
-- Since withAuth's retry happens synchronously inside this one call, set
-- the mode to a sequence instead of a bare string.
local DOWNLOAD_SEQUENCE = { "unauthorized", "ok" }
local original_download_dispatch = downloadResponse
downloadResponse = function(request)
    DOWNLOAD_MODE = table.remove(DOWNLOAD_SEQUENCE, 1) or "ok"
    return original_download_dispatch(request)
end
local dl_ok, dl_code = Api:downloadFile("item1", "ino1", "book.epub", STAGING_DIR)
downloadResponse = original_download_dispatch
EXPECT_STAGING_GONE = nil
assert(dl_ok == true and dl_code == 200)
assert(#download_requests == 2 and #refresh_requests == 1)
local committed = io.open(dest_path, "rb")
assert(committed, "the destination file must exist after a successful retry")
assert(committed:read("*a") == "EPUBDATA")
committed:close()
assert(not io.open(expected_temp, "r"), "no staging file must remain after a successful commit")
os.remove(dest_path)
print("PASS: downloadFile discards the staging file before the refresh, then retries into a fresh file")

-- downloadFile: refresh 401 -- session_expired, staging gone, a
-- pre-existing destination survives untouched.
signInFreshSession()
DOWNLOAD_MODE = "unauthorized"
REFRESH_MODE = "401"
local preexisting = io.open(dest_path, "w")
preexisting:write("ORIGINAL-BYTES")
preexisting:close()
local dl2_ok, dl2_reason = Api:downloadFile("item1", "ino1", "book.epub", STAGING_DIR)
assert(dl2_ok == false and dl2_reason == "session_expired")
assert(settings_table.auth == nil, "refresh 401 must clear the session")
local kept = io.open(dest_path, "rb")
assert(kept:read("*a") == "ORIGINAL-BYTES", "a failed retry must never touch the pre-existing destination")
kept:close()
os.remove(dest_path)
print("PASS: downloadFile refresh-401 clears the session and leaves a pre-existing destination untouched")

-- downloadFile: refresh timeout -- connection, session kept.
signInFreshSession()
DOWNLOAD_MODE = "unauthorized"
REFRESH_MODE = "timeout"
local dl3_ok, dl3_reason, dl3_detail = Api:downloadFile("item1", "ino1", "book.epub", STAGING_DIR)
assert(dl3_ok == false and dl3_reason == "connection" and dl3_detail == "timeout")
assert(settings_table.auth == "session", "a flaky refresh must keep the session")
REFRESH_MODE = "ok"
print("PASS: downloadFile refresh-timeout reports connection and keeps the session")

-- downloadFile: no credentials at all -- unconfigured, no file created.
resetAll()
local dl4_ok, dl4_reason = Api:downloadFile("item1", "ino1", "book.epub", STAGING_DIR)
assert(dl4_ok == false and dl4_reason == "unconfigured")
assert(not io.open(dest_path, "r"))
print("PASS: downloadFile with no credentials creates no file")

-- downloadCover: 401 then refresh then retry succeeds; a refresh 401
-- leaves no cover file behind.
signInFreshSession()
local cover_path = STAGING_DIR .. "/cover.webp"
local COVER_SEQUENCE = { "unauthorized", "ok" }
local original_cover_dispatch = coverResponse
coverResponse = function(request)
    COVER_MODE = table.remove(COVER_SEQUENCE, 1) or "ok"
    return original_cover_dispatch(request)
end
REFRESH_MODE = "ok"
local cov_ok = Api:downloadCover("item1", cover_path)
coverResponse = original_cover_dispatch
assert(cov_ok == true)
local cov_file = io.open(cover_path, "rb")
assert(cov_file:read("*a") == "COVERBYTES")
cov_file:close()
os.remove(cover_path)

signInFreshSession()
COVER_MODE = "unauthorized"
REFRESH_MODE = "401"
local cov2_ok = Api:downloadCover("item1", cover_path)
assert(cov2_ok == false)
assert(not io.open(cover_path, "r"), "a refresh failure must leave no cover file behind")
REFRESH_MODE = "ok"
print("PASS: downloadCover renews and retries on a 401, and a refresh failure leaves no file behind")

-- testConnection: every mode in both session and token configurations.
signInFreshSession()
ME_MODE = "ok"
local tc1_ok = Api:testConnection()
assert(tc1_ok == true)

signInFreshSession()
local ME_SEQUENCE = { "401", "ok" }
local original_me_dispatch = meResponse
meResponse = function(request)
    ME_MODE = table.remove(ME_SEQUENCE, 1) or "ok"
    return original_me_dispatch(request)
end
REFRESH_MODE = "ok"
local tc2_ok = Api:testConnection()
meResponse = original_me_dispatch
assert(tc2_ok == true, "a 401 then a successful refresh must still report success")

signInFreshSession()
ME_MODE = "401"
REFRESH_MODE = "401"
local tc3_ok, tc3_msg = Api:testConnection()
assert(tc3_ok == false and tc3_msg:lower():find("sign in", 1, true))

signInFreshSession()
ME_MODE = "401"
REFRESH_MODE = "timeout"
local tc4_ok, tc4_msg = Api:testConnection()
assert(tc4_ok == false and tc4_msg:find("Could not reach the server", 1, true))
REFRESH_MODE = "ok"

-- A second 401 on the retry itself (session mode) is a genuine rejection.
signInFreshSession()
local ME_SEQUENCE2 = { "401", "401" }
local original_me_dispatch2 = meResponse
meResponse = function(request)
    ME_MODE = table.remove(ME_SEQUENCE2, 1) or "401"
    return original_me_dispatch2(request)
end
REFRESH_MODE = "ok"
local tc5_ok, tc5_msg = Api:testConnection()
meResponse = original_me_dispatch2
assert(tc5_ok == false and tc5_msg:lower():find("sign in", 1, true))

resetAll()
settings_table.server = "https://books.example.com"
local tc6_ok, tc6_msg = Api:testConnection()
assert(tc6_ok == false and tc6_msg:lower():find("sign in", 1, true) and tc6_msg:lower():find("token", 1, true))

resetAll()
settings_table.server = "https://books.example.com"
settings_table.token = "APITOKEN-SECRET"
ME_MODE = "401"
local tc7_ok, tc7_msg = Api:testConnection()
assert(tc7_ok == false and tc7_msg == "Invalid or expired API token")
print("PASS: testConnection renews an expired access token and reports a distinct message per failure")

-- 9. Browser session_expired / unconfigured routing ------------------------

package.loaded["audiobookshelfbridge/settingsmenu"] = {
    new = function(_self, t) return t end,
}
for _, name in ipairs({ "bookdetailswidget", "titlebar", "librarytabs", "covergrid" }) do
    package.loaded["audiobookshelfbridge/" .. name] = {}
end
local Browser = require("audiobookshelfbridge/browser")
local browser = Browser:extend{}
ui_events = {}
infomessage_calls = {}
browser:showApiFailure("session_expired", "fallback")
assert(#infomessage_calls == 1 and infomessage_calls[1].text:lower():find("sign in", 1, true))
ui_events = {}
infomessage_calls = {}
browser:showApiFailure("unconfigured", "fallback")
assert(#infomessage_calls == 1)
print("PASS: browser routes session_expired and unconfigured to Settings with a matching message")

-- 10. API-token fallback (quick-260928-gkc) ---------------------------------

local fallback_texts = {}

local function recordFallbackText(text)
    if text then
        table.insert(fallback_texts, text)
    end
end

-- Same session setup as signInFreshSession, plus a stored API token to
-- fall back to.
local function signInWithToken()
    signInFreshSession()
    settings_table.token = "APITOKEN-SECRET"
end

-- Counts error_log entries equal to `text` -- used to prove a line is
-- never added twice across scenarios that share the log (GKC-D6).
local function countLog(text)
    local count = 0
    for _, entry in ipairs(error_log) do
        if entry == text then count = count + 1 end
    end
    return count
end

-- Fallback success (GKC-D1): a session-mode 401 whose refresh is itself
-- rejected (401), with a token stored, completes on the token.
for _, refresh_mode in ipairs({ "401", "403" }) do
    signInWithToken()
    LIBS_RESPONSES = { { mode = "401" }, { mode = "ok" } }
    REFRESH_MODE = refresh_mode
    local before = #error_log
    local fb_libs = Api:getLibraries()
    assert(fb_libs and fb_libs[1].id == "lib1", refresh_mode)
    assert(#libs_requests == 2 and #refresh_requests == 1, refresh_mode .. ": expected exactly 3 HTTP calls")
    assert(libs_requests[1].headers["Authorization"] == "Bearer ACCESS-ONE", refresh_mode)
    assert(libs_requests[2].headers["Authorization"] == "Bearer APITOKEN-SECRET", refresh_mode)
    assert(settings_table.auth == nil and settings_table.access_token == nil
        and settings_table.refresh_token == nil and settings_table.session_host == nil, refresh_mode)
    assert(settings_table.token == "APITOKEN-SECRET" and settings_table.username == "alice", refresh_mode)
    assert(#error_log - before == 1, refresh_mode .. ": exactly one error_log entry per expiry event")
    assert(error_log[#error_log] == "Sign-in expired; now using the API token", refresh_mode)
end
print("PASS: a session-mode 401 whose refresh is rejected (401/403) falls back to the stored API token in exactly 3 HTTP calls")
-- Baseline for later "never added again" checks: the loop above ran the
-- fallback twice (401, then 403), so the line legitimately appears twice
-- already.
local FALLBACK_LINE = "Sign-in expired; now using the API token"
local fallback_line_baseline = countLog(FALLBACK_LINE)

-- Notice consumed once (GKC-D3), from the fallback above.
local fb_notice = Api:takeFallbackNotice()
assert(fb_notice == "Your sign-in expired. Using your API token instead.")
recordFallbackText(fb_notice)
assert(Api:takeFallbackNotice() == nil, "a second call must return nil")

-- After the fallback, the next request runs in plain token mode: one
-- request, no refresh, no new error_log entries.
libs_requests, refresh_requests = {}, {}
LIBS_RESPONSES = { { mode = "ok" } }
local before_next = #error_log
local fb_libs2 = Api:getLibraries()
assert(fb_libs2 and fb_libs2[1].id == "lib1")
assert(#libs_requests == 1 and #refresh_requests == 0)
assert(libs_requests[1].headers["Authorization"] == "Bearer APITOKEN-SECRET")
assert(#error_log - before_next == 0, "a plain token-mode success adds no log entries")
assert(Api:takeFallbackNotice() == nil, "a follow-up request must never re-set the notice")

-- A later plain 401 (token mode) reports its own reason, and the fallback
-- line is never added again.
libs_requests, refresh_requests = {}, {}
LIBS_RESPONSES = { { mode = "401" } }
local fb_libs3, fb_libs3_reason = Api:getLibraries()
assert(fb_libs3 == nil and fb_libs3_reason == "server")
assert(#libs_requests == 1 and #refresh_requests == 0)
assert(countLog(FALLBACK_LINE) == fallback_line_baseline,
    "the fallback line must not be added again on a later plain 401")
print("PASS: after the fallback, later requests run in plain token mode and the notice is consumed exactly once")

-- A successful sign-in clears a pending notice even if it was never shown.
signInWithToken()
LIBS_RESPONSES = { { mode = "401" }, { mode = "ok" } }
REFRESH_MODE = "401"
Api:getLibraries()
LOGIN_MODE = "ok"
assert(Api:login("alice", "PASSWORD-SECRET"))
assert(Api:takeFallbackNotice() == nil, "a fresh sign-in must clear a still-pending notice")
-- That getLibraries() call above was itself a fallback event, so the
-- baseline used by every later "never added again" check moves up by one.
fallback_line_baseline = countLog(FALLBACK_LINE)
print("PASS: a successful sign-in clears a pending fallback notice")

-- Token retry rejected (GKC-D2): the token is bad too.
signInWithToken()
LIBS_RESPONSES = { { mode = "401" }, { mode = "401" } }
REFRESH_MODE = "401"
libs_requests, refresh_requests = {}, {}
local before_rejected = #error_log
local rej_libs, rej_reason = Api:getLibraries()
assert(rej_libs == nil and rej_reason == "token_rejected", "not session_expired")
assert(#libs_requests == 2 and #refresh_requests == 1, "exactly 3 HTTP calls")
assert(settings_table.auth == nil and settings_table.access_token == nil
    and settings_table.refresh_token == nil and settings_table.session_host == nil)
assert(settings_table.token == "APITOKEN-SECRET")
assert(Api:takeFallbackNotice() == nil)
assert(#error_log - before_rejected == 1)
assert(error_log[#error_log] == "Sign-in expired and the API token was rejected (401)")
print("PASS: a rejected token retry reports token_rejected and records the combined rejection line")

-- No token stored: today's session_expired behavior, unchanged.
for _, refresh_mode in ipairs({ "401", "403" }) do
    signInFreshSession()
    LIBS_RESPONSES = { { mode = "401" } }
    REFRESH_MODE = refresh_mode
    local before_notoken = #error_log
    local nt_libs, nt_reason = Api:getLibraries()
    assert(nt_libs == nil and nt_reason == "session_expired", refresh_mode)
    assert(#libs_requests == 1 and #refresh_requests == 1, refresh_mode)
    assert(Api:takeFallbackNotice() == nil, refresh_mode)
    assert(#error_log - before_notoken == 1, refresh_mode)
    assert(error_log[#error_log] == "refreshSession: session expired, sign in again", refresh_mode)
end
REFRESH_MODE = "ok"
print("PASS: with no API token stored, refresh 401/403 still reports session_expired with the unchanged Recent-errors line")

-- A flaky refresh (connection/server) with a token stored never falls
-- back -- the session is kept and the fallback line is not added again.
local NO_FALLBACK_REASONS = { timeout = "connection", ["429"] = "server" }
for refresh_mode, expected_reason in pairs(NO_FALLBACK_REASONS) do
    signInWithToken()
    LIBS_RESPONSES = { { mode = "401" } }
    REFRESH_MODE = refresh_mode
    libs_requests, refresh_requests = {}, {}
    local flaky_result, flaky_reason = Api:getLibraries()
    assert(flaky_result == nil and flaky_reason == expected_reason, refresh_mode)
    assert(#libs_requests == 1 and #refresh_requests == 1, refresh_mode)
    assert(settings_table.auth == "session", refresh_mode .. ": session must be kept")
    for _, req in ipairs(libs_requests) do
        assert(req.headers["Authorization"] ~= "Bearer APITOKEN-SECRET", refresh_mode)
    end
    assert(Api:takeFallbackNotice() == nil, refresh_mode)
    assert(countLog(FALLBACK_LINE) == fallback_line_baseline, refresh_mode)
end
REFRESH_MODE = "ok"
print("PASS: a flaky refresh (connection/server) with a token stored keeps the session and never falls back")

-- A successful refresh whose retry then gets 401 never falls back either.
signInWithToken()
LIBS_RESPONSES = { { mode = "401" }, { mode = "401" } }
REFRESH_MODE = "ok"
libs_requests, refresh_requests = {}, {}
local retry401_result, retry401_reason = Api:getLibraries()
assert(retry401_result == nil and retry401_reason == "server")
assert(#libs_requests == 2 and #refresh_requests == 1)
for _, req in ipairs(libs_requests) do
    assert(req.headers["Authorization"] ~= "Bearer APITOKEN-SECRET")
end
assert(settings_table.auth == "session")
print("PASS: a successful refresh whose own retry gets 401 is never followed by an API-token fallback")

-- downloadFile fallback (FALLBACK-03/FALLBACK-04): the staging file is
-- discarded and empty before the token retry, which then completes.
signInWithToken()
DOWNLOAD_MODE = "unauthorized"
REFRESH_MODE = "401"
local fb_dl_dest = STAGING_DIR .. "/book-fallback.epub"
local fb_dl_temp = DownloadStaging.tempPathFor(STAGING_DIR, "item1", "ino1")
EXPECT_STAGING_GONE = fb_dl_temp
download_requests = {}
local FB_DOWNLOAD_SEQUENCE = { "unauthorized", "ok" }
local original_download_dispatch_fb = downloadResponse
downloadResponse = function(request)
    DOWNLOAD_MODE = table.remove(FB_DOWNLOAD_SEQUENCE, 1) or "ok"
    if request.headers["Authorization"] == "Bearer APITOKEN-SECRET" then
        local staged = io.open(fb_dl_temp, "rb")
        assert(staged, "the staging file must exist before the token retry")
        assert(staged:read("*a") == "", "the staging file must be empty before the token retry")
        staged:close()
    end
    return original_download_dispatch_fb(request)
end
local before_dl_fb = #error_log
local fb_dl_ok, fb_dl_code = Api:downloadFile("item1", "ino1", "book-fallback.epub", STAGING_DIR)
downloadResponse = original_download_dispatch_fb
EXPECT_STAGING_GONE = nil
assert(fb_dl_ok == true and fb_dl_code == 200)
local fb_committed = io.open(fb_dl_dest, "rb")
assert(fb_committed, "the destination must exist after a successful token retry")
assert(fb_committed:read("*a") == "EPUBDATA")
fb_committed:close()
assert(not io.open(fb_dl_temp, "r"), "no staging file must remain")
assert(#download_requests == 2 and #refresh_requests == 1)
assert(download_requests[2].headers["Authorization"] == "Bearer APITOKEN-SECRET")
assert(#error_log - before_dl_fb == 1)
assert(error_log[#error_log] == "Sign-in expired; now using the API token")
os.remove(fb_dl_dest)
print("PASS: downloadFile starts the token retry from an empty staging file and commits its transfer")

-- downloadFile rejected token: a pre-existing destination survives
-- untouched.
signInWithToken()
DOWNLOAD_MODE = "unauthorized"
REFRESH_MODE = "401"
local fb_dl_dest2 = STAGING_DIR .. "/book-fallback2.epub"
local fb_dl_pre = io.open(fb_dl_dest2, "w")
fb_dl_pre:write("ORIGINAL-BYTES")
fb_dl_pre:close()
download_requests = {}
local FB_DOWNLOAD_SEQUENCE_REJ = { "unauthorized", "unauthorized" }
local original_download_dispatch_rej = downloadResponse
downloadResponse = function(request)
    DOWNLOAD_MODE = table.remove(FB_DOWNLOAD_SEQUENCE_REJ, 1) or "unauthorized"
    return original_download_dispatch_rej(request)
end
local before_dl_rej = #error_log
local rej_dl_ok, rej_dl_reason = Api:downloadFile("item1", "ino1", "book-fallback2.epub", STAGING_DIR)
downloadResponse = original_download_dispatch_rej
assert(rej_dl_ok == false and rej_dl_reason == "token_rejected")
local fb_dl_kept = io.open(fb_dl_dest2, "rb")
assert(fb_dl_kept:read("*a") == "ORIGINAL-BYTES", "a rejected token retry must never touch a pre-existing destination")
fb_dl_kept:close()
local fb_dl_temp2 = DownloadStaging.tempPathFor(STAGING_DIR, "item1", "ino1")
assert(not io.open(fb_dl_temp2, "r"), "no staging file must remain")
assert(#error_log - before_dl_rej == 1)
assert(error_log[#error_log] == "Sign-in expired and the API token was rejected (401)")
os.remove(fb_dl_dest2)
print("PASS: downloadFile reports token_rejected and leaves a pre-existing destination untouched")

-- downloadCover fallback: the second (token) request completes the write.
signInWithToken()
REFRESH_MODE = "401"
local fb_cover_path = STAGING_DIR .. "/cover-fallback.webp"
cover_requests = {}
local FB_COVER_SEQUENCE = { "unauthorized", "ok" }
local original_cover_dispatch_fb = coverResponse
coverResponse = function(request)
    COVER_MODE = table.remove(FB_COVER_SEQUENCE, 1) or "ok"
    return original_cover_dispatch_fb(request)
end
local before_cov_fb = #error_log
local fb_cov_ok = Api:downloadCover("item1", fb_cover_path)
coverResponse = original_cover_dispatch_fb
assert(fb_cov_ok == true)
local fb_cov_file = io.open(fb_cover_path, "rb")
assert(fb_cov_file:read("*a") == "COVERBYTES")
fb_cov_file:close()
assert(#cover_requests == 2)
assert(cover_requests[2].headers["Authorization"] == "Bearer APITOKEN-SECRET")
assert(#error_log - before_cov_fb == 1)
assert(error_log[#error_log] == "Sign-in expired; now using the API token")
os.remove(fb_cover_path)
print("PASS: downloadCover falls back to the API token and adds no error_log entry of its own")

-- testConnection (GKC-D5): names the method, and reports the fallback.
signInFreshSession()
ME_MODE = "ok"
local tc_session_ok, tc_session_mode, tc_session_fb = Api:testConnection()
assert(tc_session_ok == true and tc_session_mode == "session" and tc_session_fb == false)

resetAll()
settings_table.server = "https://books.example.com"
settings_table.token = "APITOKEN-SECRET"
ME_MODE = "ok"
local tc_token_ok, tc_token_mode, tc_token_fb = Api:testConnection()
assert(tc_token_ok == true and tc_token_mode == "token" and tc_token_fb == false)

signInWithToken()
local FB_ME_SEQUENCE = { "401", "ok" }
local original_me_dispatch_fb = meResponse
meResponse = function(request)
    ME_MODE = table.remove(FB_ME_SEQUENCE, 1) or "ok"
    return original_me_dispatch_fb(request)
end
REFRESH_MODE = "401"
me_requests, refresh_requests = {}, {}
local before_tc_fb = #error_log
local tc_fb_ok, tc_fb_mode, tc_fb_fell = Api:testConnection()
meResponse = original_me_dispatch_fb
assert(tc_fb_ok == true and tc_fb_mode == "token" and tc_fb_fell == true)
assert(#me_requests == 2 and #refresh_requests == 1)
assert(settings_table.auth == nil)
local tc_fb_notice = Api:takeFallbackNotice()
assert(tc_fb_notice == "Your sign-in expired. Using your API token instead.",
    "testConnection must not consume the notice itself")
recordFallbackText(tc_fb_notice)
assert(#error_log - before_tc_fb == 1)
assert(error_log[#error_log] == "Sign-in expired; now using the API token")

signInWithToken()
local FB_ME_SEQUENCE_REJ = { "401", "401" }
local original_me_dispatch_rej = meResponse
meResponse = function(request)
    ME_MODE = table.remove(FB_ME_SEQUENCE_REJ, 1) or "401"
    return original_me_dispatch_rej(request)
end
REFRESH_MODE = "401"
me_requests, refresh_requests = {}, {}
local before_tc_rej = #error_log
local tc_rej_ok, tc_rej_msg = Api:testConnection()
meResponse = original_me_dispatch_rej
assert(tc_rej_ok == false and tc_rej_msg == "Invalid or expired API token")
assert(settings_table.auth == nil)
assert(Api:takeFallbackNotice() == nil)
assert(#error_log - before_tc_rej == 1)
assert(error_log[#error_log] == "Sign-in expired and the API token was rejected (401)")
recordFallbackText(tc_rej_msg)

signInFreshSession()
ME_MODE = "401"
REFRESH_MODE = "401"
local before_tc_notoken = #error_log
local tc_notoken_ok, tc_notoken_msg = Api:testConnection()
assert(tc_notoken_ok == false and tc_notoken_msg:lower():find("sign in", 1, true))
assert(#error_log - before_tc_notoken == 1)
assert(error_log[#error_log] == "refreshSession: session expired, sign in again")
recordFallbackText(tc_notoken_msg)
REFRESH_MODE = "ok"

resetAll()
settings_table.server = "https://books.example.com"
settings_table.token = "APITOKEN-SECRET"
ME_MODE = "401"
local tc_tokenonly_ok, tc_tokenonly_msg = Api:testConnection()
assert(tc_tokenonly_ok == false and tc_tokenonly_msg == "Invalid or expired API token")
recordFallbackText(tc_tokenonly_msg)
print("PASS: testConnection names the method that answered and reports a fallback on its own request")

-- Browser (GKC-D4): showFallbackNotice shows the notice once; showApiFailure
-- routes token_rejected to Settings with an API-token-specific message.
signInWithToken()
LIBS_RESPONSES = { { mode = "401" }, { mode = "ok" } }
REFRESH_MODE = "401"
Api:getLibraries()
infomessage_calls = {}
browser:showFallbackNotice()
assert(#infomessage_calls == 1)
recordFallbackText(infomessage_calls[1].text)
browser:showFallbackNotice()
assert(#infomessage_calls == 1, "a second call must show nothing new")

infomessage_calls = {}
browser:showApiFailure("token_rejected", "fallback")
assert(#infomessage_calls == 1 and infomessage_calls[1].text:find("API token", 1, true))
recordFallbackText(infomessage_calls[1].text)
print("PASS: the browser shows the fallback notice exactly once and routes token_rejected to Settings")

REFRESH_MODE = "ok"

-- 11. Secret scan -----------------------------------------------------------

local FORBIDDEN = { "PASSWORD-SECRET", "ACCESS-ONE", "ACCESS-TWO", "REFRESH-ONE", "REFRESH-TWO", "APITOKEN-SECRET" }

local function scanForSecrets(value, path, seen)
    if type(value) == "string" then
        for _, secret in ipairs(FORBIDDEN) do
            assert(not value:find(secret, 1, true), "secret " .. secret .. " leaked via " .. path)
        end
    elseif type(value) == "table" then
        seen = seen or {}
        if seen[value] then return end
        seen[value] = true
        for k, v in pairs(value) do
            scanForSecrets(v, path .. "." .. tostring(k), seen)
        end
    end
end

scanForSecrets(error_log, "error_log")
scanForSecrets(logger_calls, "logger_calls")
for i, t in ipairs(infomessage_calls) do
    scanForSecrets(t.text, "infomessage_calls[" .. i .. "].text")
end
for i, t in ipairs(confirmbox_calls) do
    scanForSecrets(t.text, "confirmbox_calls[" .. i .. "].text")
end
-- GKC-D6/T-gkc-01: every message the fallback section collected --
-- InfoMessage texts, testConnection messages, and takeFallbackNotice
-- results.
scanForSecrets(fallback_texts, "fallback_texts")
-- Settings storage legitimately holds the access/refresh/API tokens; only
-- the password must never appear there.
assert(not tostring(settings_table.access_token or ""):find("PASSWORD-SECRET", 1, true))
assert(not tostring(settings_table.refresh_token or ""):find("PASSWORD-SECRET", 1, true))
for _, v in pairs(settings_table) do
    if type(v) == "string" then
        assert(not v:find("PASSWORD-SECRET", 1, true), "the password must never reach Settings")
    end
end
print("PASS: no secret (password, access/refresh tokens, API token) ever reaches a log, error, or on-screen message")

-- Cleanup: remove the throwaway staging directory used by the download
-- tests above.
os.execute("rm -rf " .. STAGING_DIR)

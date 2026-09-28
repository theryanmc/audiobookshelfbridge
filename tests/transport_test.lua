-- Run: luajit tests/transport_test.lua
--
-- Drives the real audiobookshelfbridge/api and audiobookshelfbridge/
-- ebookfilewidget against a stubbed socket.http, in the style of
-- tests/api_metadata_test.lua. Covers CR-F4 (server URL normalization),
-- CR-F5/CR-F6 (download failure reporting and progress lifecycle), CR-F7
-- (cover failures never reach Recent errors), and CR-L1 (transport
-- failures classified as "connection" everywhere).

package.loaded["ffi/util"] = {
    template = function(text, ...)
        local args = { ... }
        return (text:gsub("%%(%d)", function(d)
            return tostring(args[tonumber(d)])
        end))
    end,
}

package.loaded.json = {
    -- decode must be callable (pcall(JSON.decode, ...)) and carry a
    -- `simple` field (JSON.decode.simple, passed as decode's second
    -- argument). Success paths are never exercised in this file -- every
    -- scenario below either fails before decoding or fails at decode.
    decode = setmetatable({ simple = true }, {
        __call = function() return {} end,
    }),
    encode = function() return "{}" end,
}

package.loaded.ltn12 = {
    source = { string = function(body) return function() return body end end },
}

package.loaded.socket = { skip = function(_, ...) return select(2, ...) end }

package.loaded.socketutil = {
    set_timeout = function() end,
    reset_timeout = function() end,
    table_sink = function(t)
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
package.loaded.logger = { warn = function() end, dbg = function() end }
package.loaded.gettext = function(text) return text end

-- Settings: a fixed table, server carrying trailing slashes (CR-F4).
local settings_table = {
    server = "https://example.invalid//",
    token = "test-token",
    download_dir = os.getenv("TMPDIR") or "/tmp",
}
package.loaded["audiobookshelfbridge/settings"] = {
    read = function(_self, key, default)
        local v = settings_table[key]
        if v == nil then return default end
        return v
    end,
    write = function(_self, key, value) settings_table[key] = value end,
}

-- ErrorLog: unbounded list, unlike the real 20-entry ring buffer -- this
-- file wants to see every record, not just the most recent 20.
local error_log = {}
package.loaded["audiobookshelfbridge/errorlog"] = {
    record = function(_self, message) table.insert(error_log, tostring(message)) end,
    getRecent = function(_self) return error_log end,
}

-- DownloadStaging: only the two functions downloadFile's failure paths
-- reach (they all return before fileSize/isCompleteTransfer/commit).
local discard_calls = {}
package.loaded["audiobookshelfbridge/downloadstaging"] = {
    tempPathFor = function(_local_path, _id, _ino) return os.tmpname() end,
    discard = function(path)
        table.insert(discard_calls, path)
        os.remove(path)
    end,
}

-- The http stub. MODE selects what http.request returns/does; every call
-- records its URL so CR-F4 can be checked across every method.
local MODE = "timeout"
local captured_urls = {}
package.loaded["socket.http"] = {
    request = function(request)
        table.insert(captured_urls, request.url)
        if MODE == "timeout" then
            -- socket.protect's real shape for a transport failure: a
            -- normal return, not a raise (CR-L1).
            return nil, "timeout"
        elseif MODE == "raised" then
            error("transport failed")
        elseif MODE == "redirect" then
            return 1, 302
        elseif MODE == "404" then
            if request.sink then request.sink("") end
            return 1, 404
        elseif MODE == "200-empty" then
            if request.sink then request.sink("{}") end
            return 1, 200
        end
        error("transport_test: unhandled MODE " .. tostring(MODE))
    end,
}

local Api = require("audiobookshelfbridge/api")

-- 1. normalizeServerUrl -------------------------------------------------

assert(Api.normalizeServerUrl("https://h/") == "https://h")
assert(Api.normalizeServerUrl("https://h///") == "https://h")
assert(Api.normalizeServerUrl("https://h/abs/") == "https://h/abs")
assert(Api.normalizeServerUrl("https://h") == "https://h")
assert(Api.normalizeServerUrl(nil) == nil)
print("PASS: normalizeServerUrl strips trailing slashes, leaves nil and clean values alone")

-- 2. Every request URL is built from the normalized server -------------

captured_urls = {}
MODE = "timeout"
Api:getLibraries()
Api:getLibraryItems("lib1")
Api:getAuthorItems("author1")
Api:getLibraryItem("item1")
Api:getSearchResults("lib1", "query")
Api:getLibraryItemsMetadata({ { id = "x" } })
Api:downloadFile("item1", "ino1", "file.epub", settings_table.download_dir)
Api:getLibraryItemCover("item1")
Api:downloadCover("item1", os.tmpname())
Api:testConnection()

assert(#captured_urls >= 9, "expected every method to have issued a request")
for _, url in ipairs(captured_urls) do
    assert(url:match("^https://example%.invalid/api/"), url)
    assert(not url:find("//api", 1, true), url)
end
print("PASS: every request URL is built from the normalized server, no //api anywhere")

-- 3. Connection-failure classification, every listing/search/item method

local METHOD_CALLS = {
    getLibraries = function() return Api:getLibraries() end,
    getLibraryItems = function() return Api:getLibraryItems("lib1") end,
    getAuthorItems = function() return Api:getAuthorItems("author1") end,
    getLibraryItem = function() return Api:getLibraryItem("item1") end,
    getSearchResults = function() return Api:getSearchResults("lib1", "q") end,
    getLibraryItemsMetadata = function() return Api:getLibraryItemsMetadata({ { id = "x" } }) end,
}

for name, call in pairs(METHOD_CALLS) do
    MODE = "timeout"
    local result, reason = call()
    assert(result == nil, name .. ": expected nil result on timeout")
    assert(reason == "connection", name .. ": expected reason connection, got " .. tostring(reason))
    local last = error_log[#error_log]
    assert(last == name .. ": connection failed: timeout", name .. ": got " .. tostring(last))
end
print("PASS: every listing/search/item method classifies a socket.protect timeout as connection")

for name, call in pairs(METHOD_CALLS) do
    MODE = "raised"
    local result, reason = call()
    assert(result == nil and reason == "connection", name .. " (raised)")
end
print("PASS: a raised transport error is still classified as connection")

-- 4. downloadFile: connection and server failures, staging discarded ----

discard_calls = {}
MODE = "timeout"
local dl_ok1, dl_reason1, dl_detail1 = Api:downloadFile("item1", "ino1", "file.epub", settings_table.download_dir)
assert(dl_ok1 == false and dl_reason1 == "connection" and dl_detail1 == "timeout")
assert(#discard_calls == 1, "staging file must be discarded on a connection failure")

discard_calls = {}
MODE = "404"
local dl_ok2, dl_reason2, dl_detail2 = Api:downloadFile("item1", "ino1", "file.epub", settings_table.download_dir)
assert(dl_ok2 == false and dl_reason2 == "server" and dl_detail2 == 404)
assert(#discard_calls == 1, "staging file must be discarded on a server error")
print("PASS: downloadFile reports connection/timeout and server/404, discarding staging either way")

-- 5. getLibraryItemCover / downloadCover: no ErrorLog record, ever -------

MODE = "timeout"
local before_len = #error_log
local cover1, cover1_code = Api:getLibraryItemCover("item1")
assert(cover1 == nil and cover1_code == "timeout")
assert(#error_log == before_len, "getLibraryItemCover must not record a timeout")

MODE = "404"
before_len = #error_log
local cover2, cover2_code = Api:getLibraryItemCover("item1")
assert(cover2 == nil and cover2_code == 404)
assert(#error_log == before_len, "getLibraryItemCover must not record a 404")

MODE = "timeout"
local cover_path = os.tmpname()
before_len = #error_log
local dc_ok, dc_code = Api:downloadCover("item1", cover_path)
assert(dc_ok == false and dc_code == "timeout")
assert(#error_log == before_len, "downloadCover must not record a timeout")
assert(not io.open(cover_path, "r"), "downloadCover must remove its file on failure")
print("PASS: cover failures (timeout, 404) are logger-only, never Recent errors (OD-2/CR-F7)")

-- 6. testConnection -------------------------------------------------------

MODE = "timeout"
local tc_ok, tc_msg = Api:testConnection()
assert(tc_ok == false)
assert(tostring(tc_msg):find("Could not reach the server", 1, true), tostring(tc_msg))
assert(error_log[#error_log] == "testConnection: connection failed: timeout")
print("PASS: testConnection reports a connection failure with a Wi-Fi-facing message")

-- 7. EbookFileWidget.downloadFailureText and the full download flow -----

package.loaded["ui/bidi"] = {
    filepath = function(p) return p end,
    dirpath = function(p) return p end,
}
package.loaded["ffi/blitbuffer"] = {}
package.loaded["ui/widget/buttondialog"] = {
    new = function(_self, t)
        t.setTitle = function() end
        return t
    end,
}
package.loaded["ui/widget/container/centercontainer"] = {}
local confirmbox_calls = {}
package.loaded["ui/widget/confirmbox"] = {
    new = function(_self, t)
        table.insert(confirmbox_calls, t)
        return t
    end,
}
package.loaded["ui/font"] = {}
package.loaded["ui/widget/container/framecontainer"] = {}
package.loaded["ui/geometry"] = {}
package.loaded["ui/gesturerange"] = {}
local infomessage_calls = {}
package.loaded["ui/widget/infomessage"] = {
    new = function(_self, t)
        table.insert(infomessage_calls, t)
        return t
    end,
}
package.loaded["ui/widget/container/inputcontainer"] = {
    extend = function(_self, t) return t end,
}
package.loaded["ui/widget/inputdialog"] = {}
package.loaded["ui/widget/container/leftcontainer"] = {}
package.loaded["audiobookshelfbridge/metadatawriter"] = {
    writeAll = function() end,
}
package.loaded["ui/network/manager"] = {
    runWhenOnline = function(_self, callback) callback() end,
}
package.loaded["ui/widget/overlapgroup"] = {}
package.loaded["apps/reader/readerui"] = {}
package.loaded["ui/widget/container/rightcontainer"] = {}
package.loaded["ui/size"] = {
    padding = { fullscreen = 0 },
}
package.loaded["ui/widget/textboxwidget"] = {}
package.loaded["ui/widget/textwidget"] = {}

local ui_events = {}
package.loaded["ui/uimanager"] = {
    show = function(_self, widget, _refresh) table.insert(ui_events, { "show", widget }) end,
    close = function(_self, widget) table.insert(ui_events, { "close", widget }) end,
    forceRePaint = function(_self) table.insert(ui_events, { "forceRePaint" }) end,
    nextTick = function(_self, fn) fn() end,
    scheduleIn = function(_self, _delay, fn) fn() end,
    broadcastEvent = function(_self, _event) end,
    setDirty = function(_self, ...) end,
}
package.loaded["ui/widget/container/underlinecontainer"] = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
}

local EbookFileWidget = require("audiobookshelfbridge/ebookfilewidget")

-- downloadFailureText: every reason gets its own message.
assert(EbookFileWidget.downloadFailureText("open_failed", nil, "/x"):find("Could not save file", 1, true))
assert(EbookFileWidget.downloadFailureText("commit_failed", nil, "/x"):find("Could not save file", 1, true))
for _, reason in ipairs({ "unconfigured", "redirect", "connection", "server", "incomplete", "totally_unknown" }) do
    local msg = EbookFileWidget.downloadFailureText(reason, "detail", "/x")
    assert(type(msg) == "string" and #msg > 0, reason)
    assert(not msg:find("Could not save file", 1, true), reason)
end
assert(EbookFileWidget.downloadFailureText("server", 404, "/x"):find("404", 1, true))
local timeout_msg = EbookFileWidget.downloadFailureText("connection", "timeout", "/x")
local refused_msg = EbookFileWidget.downloadFailureText("connection", "connection refused", "/x")
assert(timeout_msg ~= refused_msg)
local distinct = {}
for _, reason in ipairs({ "unconfigured", "redirect", "incomplete", "server" }) do
    distinct[reason] = EbookFileWidget.downloadFailureText(reason, 1, "/x")
end
assert(distinct.unconfigured ~= distinct.redirect)
assert(distinct.redirect ~= distinct.incomplete)
assert(distinct.incomplete ~= distinct.server)
assert(distinct.unconfigured ~= distinct.incomplete)
assert(distinct.unconfigured ~= distinct.server)
assert(distinct.redirect ~= distinct.server)
local default_msg = EbookFileWidget.downloadFailureText("totally_unknown", nil, "/x")
assert(type(default_msg) == "string" and #default_msg > 0)
print("PASS: downloadFailureText gives every reason its own message, unknown reasons get a default")

-- AUTH-03/AUTH-06: session_expired gets its own message, distinct from
-- every other reason above.
local session_expired_msg = EbookFileWidget.downloadFailureText("session_expired", nil, "/x")
assert(type(session_expired_msg) == "string" and #session_expired_msg > 0)
assert(session_expired_msg ~= distinct.unconfigured)
assert(session_expired_msg ~= distinct.redirect)
assert(session_expired_msg ~= distinct.incomplete)
assert(session_expired_msg ~= distinct.server)
assert(session_expired_msg ~= timeout_msg)
print("PASS: downloadFailureText(session_expired) is its own message, distinct from every other reason")

-- GKC-D2: token_rejected gets its own message too, distinct from every
-- other reason above, including session_expired.
local token_rejected_msg = EbookFileWidget.downloadFailureText("token_rejected", nil, "/x")
assert(type(token_rejected_msg) == "string" and #token_rejected_msg > 0)
assert(token_rejected_msg ~= distinct.unconfigured)
assert(token_rejected_msg ~= distinct.redirect)
assert(token_rejected_msg ~= distinct.incomplete)
assert(token_rejected_msg ~= distinct.server)
assert(token_rejected_msg ~= timeout_msg)
assert(token_rejected_msg ~= session_expired_msg)
print("PASS: downloadFailureText(token_rejected) is its own message, distinct from every other reason")

-- Full download flow: http stub times out.
ui_events = {}
infomessage_calls = {}
MODE = "timeout"

local widget = setmetatable({
    filename = "book.epub",
    ino = "ino1",
    book_id = "item1",
    size_in_bytes = 1000,
    book_info = { id = "item1" },
}, { __index = EbookFileWidget })

widget:downloadFile()
assert(widget.download_dialog and widget.download_dialog.buttons, "downloadFile must build the button dialog")

local download_button
for _, row in ipairs(widget.download_dialog.buttons) do
    for _, button in ipairs(row) do
        if button.text == "Download" then download_button = button end
    end
end
assert(download_button, "Download button not found in dialog")
download_button.callback()

assert(#infomessage_calls == 2, "expected a progress message and a failure message")
local progress_widget = infomessage_calls[1]
local failure_widget = infomessage_calls[2]
assert(progress_widget.timeout == nil, "progress message must have no timeout")
assert(progress_widget.text:find("Downloading", 1, true))
assert(failure_widget.timeout == nil, "failure message must have no timeout")
assert(failure_widget.text == EbookFileWidget.downloadFailureText("connection", "timeout", settings_table.download_dir),
    failure_widget.text)

local function eventIndex(kind, widget_ref)
    for i, ev in ipairs(ui_events) do
        if ev[1] == kind and (widget_ref == nil or ev[2] == widget_ref) then
            return i
        end
    end
    return nil
end

local show_progress_idx = eventIndex("show", progress_widget)
local force_repaint_idx = eventIndex("forceRePaint")
local close_progress_idx = eventIndex("close", progress_widget)
local show_failure_idx = eventIndex("show", failure_widget)
assert(show_progress_idx and force_repaint_idx and close_progress_idx and show_failure_idx,
    "expected show(progress), forceRePaint, close(progress) and show(failure) to all occur")
assert(show_progress_idx < force_repaint_idx, "progress must be shown before the repaint")
assert(force_repaint_idx < close_progress_idx, "the repaint must happen before the progress message closes")
assert(close_progress_idx < show_failure_idx, "the progress message must close before the failure message shows")

print("PASS: download flow shows progress with no timeout, repaints, closes, then shows the failure reason")

-- GKC-D4: the download flow shows the fallback notice once, after the
-- failure result, using a consume-once stub for takeFallbackNotice so this
-- file need not drive api.lua's own withAuth fallback machinery to prove
-- it.
local saved_take_fallback_notice = Api.takeFallbackNotice
local NOTICE_SEQUENCE = { "NOTICE-TEXT" }
Api.takeFallbackNotice = function(_self)
    return table.remove(NOTICE_SEQUENCE, 1)
end

local function runDownloadFlow()
    local flow_widget = setmetatable({
        filename = "book.epub",
        ino = "ino1",
        book_id = "item1",
        size_in_bytes = 1000,
        book_info = { id = "item1" },
    }, { __index = EbookFileWidget })
    flow_widget:downloadFile()
    local flow_button
    for _, row in ipairs(flow_widget.download_dialog.buttons) do
        for _, button in ipairs(row) do
            if button.text == "Download" then flow_button = button end
        end
    end
    flow_button.callback()
end

MODE = "timeout"
ui_events = {}
infomessage_calls = {}
runDownloadFlow()
assert(#infomessage_calls == 3, "expected progress, failure, and the fallback notice")
local notice_widget = infomessage_calls[3]
assert(notice_widget.text == "NOTICE-TEXT")
assert(notice_widget.timeout == 3)
local show_failure_idx2 = eventIndex("show", infomessage_calls[2])
local show_notice_idx = eventIndex("show", notice_widget)
assert(show_failure_idx2 and show_notice_idx and show_failure_idx2 < show_notice_idx,
    "the notice must show after the failure message")

ui_events = {}
infomessage_calls = {}
runDownloadFlow()
assert(#infomessage_calls == 2, "the consume-once stub returns nil on the second run")

Api.takeFallbackNotice = saved_take_fallback_notice
print("PASS: the download flow shows the fallback notice once, after the failure result")

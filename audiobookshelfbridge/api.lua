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

-- S1: the single place credentials are read. On a fresh install the config
-- file does not exist, LuaSettings hands back an empty table, and both reads
-- return nil. Every request used to concatenate those values outside its
-- pcall, so the first tap on the plugin raised "attempt to concatenate a nil
-- value" and took KOReader down -- before the user could ever reach Settings
-- to fix it. Returns nil when either value is missing; callers turn that into
-- an "unconfigured" result the browser routes to Settings.
local function credentials()
    local server = Settings:read("server")
    local token = Settings:read("token")
    if type(server) ~= "string" or server == "" or type(token) ~= "string" or token == "" then
        return nil
    end
    return server, token
end

function AudiobookshelfApi:isConfigured()
    return credentials() ~= nil
end

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

function AudiobookshelfApi:getLibraries()
    local server, token = credentials()
    if not server then
        return unconfigured("getLibraries")
    end
    local sink = {}
    local request = buildRequest(server, token, "/api/libraries", ltn12.sink.table(sink))
    socketutil:set_timeout()
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local response = table.concat(sink)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("AudiobookshelfApi: http request failed in getLibraries:", code)
        ErrorLog:record(T("getLibraries: connection failed: %1", tostring(code)))
        return nil, "connection"
    end
    if isRedirect(code) then
        return redirected("getLibraries", code, status)
    end
    if code == 200 and response ~= "" then
        local result = self:decodeResponse(response, "getLibraries", "libraries")
        if not result then
            return nil, "unreadable"
        end
        return result
    end
    logger.warn("AudiobookshelfApi: cannot get libraries", status or code)
    ErrorLog:record(T("getLibraries: server error: %1", tostring(status or code)))
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
-- methods: the results array, or nil plus a reason.
local function fetchAllPages(self, server, token, base_path, method_name)
    local all = {}
    for page = 0, ITEMS_MAX_PAGES - 1 do
        local sink = {}
        local request = buildRequest(server, token,
            base_path .. "&limit=" .. ITEMS_PAGE_SIZE .. "&page=" .. page,
            ltn12.sink.table(sink))
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
        local response = table.concat(sink)
        socketutil:reset_timeout()
        if not ok then
            logger.warn("AudiobookshelfApi: http request failed in " .. method_name .. ":", code)
            ErrorLog:record(T("%1: connection failed: %2", method_name, tostring(code)))
            return nil, "connection"
        end
        if isRedirect(code) then
            return redirected(method_name, code, status)
        end
        if code ~= 200 or response == "" then
            logger.warn("AudiobookshelfApi: " .. method_name .. " page", page, "failed:", status or code)
            ErrorLog:record(T("%1: server error: %2", method_name, tostring(status or code)))
            return nil, "server"
        end
        -- Whole object, not just `results`: `total` is needed to know when to
        -- stop. The shape check on `results` mirrors decodeResponse's own
        -- missing-field branch so a malformed page is reported the same way.
        local decoded = self:decodeResponse(response, method_name)
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
    local server, token = credentials()
    if not server then
        return unconfigured("getLibraryItems")
    end
    -- this is "ebooks" base64 encoded, and the URL encoded, to only return library items with ebooks
    local filters = "ebooks." .. "ZWJvb2s%3D"
    return fetchAllPages(self, server, token,
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
    local server, token = credentials()
    if not server then
        return unconfigured("getSeriesItems")
    end
    local filters = "series." .. util.urlEncode(sha2.bin_to_base64(series_id))
    return fetchAllPages(self, server, token,
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
    local server, token = credentials()
    if not server then
        return unconfigured("getAuthorItems")
    end
    local sink = {}
    local request = buildRequest(server, token,
        "/api/authors/" .. util.urlEncode(author_id) .. "?include=items,series",
        ltn12.sink.table(sink))
    -- This endpoint takes no limit parameter -- bounded only by the
    -- author's whole bibliography -- so it belongs with the other
    -- unbounded list calls at the large-content timeouts rather than the
    -- argument-less 5s/15s default.
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local response = table.concat(sink)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("AudiobookshelfApi: http request failed in getAuthorItems:", code)
        ErrorLog:record(T("getAuthorItems: connection failed: %1", tostring(code)))
        return nil, "connection"
    end
    if isRedirect(code) then
        return redirected("getAuthorItems", code, status)
    end
    if code == 200 and response ~= "" then
        -- Keyed on "libraryItems": when `items` is included the server
        -- always sets that field, to an empty array for an author with no
        -- items, so a missing field genuinely is a malformed response
        -- (verified against server source).
        local result = self:decodeResponse(response, "getAuthorItems", "libraryItems")
        if not result then
            return nil, "unreadable"
        end
        return result
    end
    logger.warn("AudiobookshelfApi: cannot get author items", author_id, status or code)
    ErrorLog:record(T("getAuthorItems: server error: %1", tostring(status or code)))
    return nil, "server"
end

function AudiobookshelfApi:getLibraryItem(id)
    local server, token = credentials()
    if not server then
        return unconfigured("getLibraryItem")
    end
    local sink = {}
    local request = buildRequest(server, token,
        "/api/items/" .. util.urlEncode(id) .. "?expanded=1",
        ltn12.sink.table(sink))
    socketutil:set_timeout()
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local response = table.concat(sink)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("AudiobookshelfApi: http request failed in getLibraryItem:", code)
        ErrorLog:record(T("getLibraryItem: connection failed: %1", tostring(code)))
        return nil, "connection"
    end
    if isRedirect(code) then
        return redirected("getLibraryItem", code, status)
    end
    if code == 200 and response ~= "" then
        local result = self:decodeResponse(response, "getLibraryItem")
        if not result then
            return nil, "unreadable"
        end
        return result
    end
    logger.warn("AudiobookshelfApi: cannot get library item", id ,status or code)
    ErrorLog:record(T("getLibraryItem: server error: %1", tostring(status or code)))
    return nil, "server"
end

function AudiobookshelfApi:downloadFile(id, ino, filename, local_path)
    -- Before the staging file is opened, so an unconfigured plugin leaves
    -- nothing behind on disk.
    local server, token = credentials()
    if not server then
        unconfigured("downloadFile")
        return false, "unconfigured"
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local fullpath = local_path .. "/" .. filename
    -- A-07 gap closure: the destination (fullpath) is never opened for
    -- writing and never removed anywhere in this function. The transfer
    -- streams into a staging file beside it instead, and is renamed onto
    -- the destination only after a verified-complete transfer via the
    -- staging module's commit step -- so a pre-existing good copy survives
    -- every failure mode untouched, which is what 04-UAT.md test 6 found
    -- missing.
    local temp_path = DownloadStaging.tempPathFor(local_path, id, ino)
    local outfile, err
    if temp_path then
        outfile, err = io.open(temp_path, "w")
    else
        err = "no_staging_path"
    end
    if not outfile then
        -- An undrivable staging path and an unopenable staging file are the
        -- same fact from the caller's side (nothing could be opened), so
        -- both fold into this one existing failure exit. The message now
        -- names the staging path rather than the destination.
        logger.warn("AudiobookshelfApi: cannot open local file for writing:", temp_path or fullpath, err)
        ErrorLog:record(T("downloadFile: could not open local file: %1", tostring(err)))
        socketutil:reset_timeout()
        return false, "open_failed"
    end
    local request = buildRequest(server, token,
        "/api/items/" .. util.urlEncode(id) .. "/file/" .. util.urlEncode(ino) .. "/download",
        ltn12.sink.file(outfile))
    local ok, code, headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok or code ~= 200 then
        -- ltn12.sink.file only closes outfile on a clean end-of-stream (a
        -- chunk == nil signal from the pump); socket/http.lua's own `try`
        -- wrapper raises a Lua error mid-transfer before the pump ever gets
        -- there, so a caught error or a non-200 status both leave the
        -- handle open and a truncated/error-page body on disk. Close inside
        -- its own pcall -- the handle may already be invalid -- then
        -- discard the staging file, and only the staging file. The
        -- pre-existing destination, if any, is never touched by this
        -- branch (A-07).
        pcall(function() outfile:close() end)
        DownloadStaging.discard(temp_path)
        if ok and isRedirect(code) then
            redirected("downloadFile", code, status)
            return false, "redirect"
        end
        logger.warn("AudiobookshelfApi: cannot download file:", id , ino, status or code)
        ErrorLog:record(T("downloadFile: transfer failed: %1", tostring(status or code)))
        return false, ok and tostring(status or code) or tostring(code)
    end
    -- Belt-and-braces close on the success path too. The sink already
    -- closed the handle on its own clean end-of-stream signal, so this
    -- will normally raise "attempt to use a closed file" -- which is
    -- exactly why it is wrapped in its own pcall (a double close is
    -- harmless). This guarantees the bytes are flushed before anything
    -- measures or renames the staging file.
    pcall(function() outfile:close() end)
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
    local declared_length = tonumber(headers and headers["content-length"])
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
    return true, code
end

function AudiobookshelfApi:getLibraryItemCover(id)
    local server, token = credentials()
    if not server then
        unconfigured("getLibraryItemCover")
        return nil
    end
    local sink = {}
    local request = buildRequest(server, token,
        "/api/items/" .. util.urlEncode(id) .. "/cover?format=webp",
        ltn12.sink.table(sink))
    -- Same endpoint/headers as downloadCover, which correctly uses the
    -- larger file-transfer timeouts; align this call so the Book Details
    -- cover thumbnail doesn't time out sooner than the sidecar cover write.
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local response = table.concat(sink)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("AudiobookshelfApi: http request failed in getLibraryItemCover:", code)
        ErrorLog:record(T("getLibraryItemCover: connection failed: %1", tostring(code)))
        return nil
    end
    if isRedirect(code) then
        -- logger only, no ErrorLog (OD-2): a cover that cannot be fetched
        -- must never surface in Settings -> Recent errors.
        logger.warn("AudiobookshelfApi: server redirected in getLibraryItemCover:", status or code)
        return nil
    end
    if code == 200 and response ~= "" then
        local result = RenderImage:renderImageData(response, #response)
        return result
    end
    logger.warn("AudiobookshelfApi: cannot get library item cover", id ,status or code)
    ErrorLog:record(T("getLibraryItemCover: server error: %1", tostring(status or code)))
    return nil
end

-- Mirrors downloadFile's file-sink shape (raw bytes to disk), not
-- getLibraryItemCover's table-sink + RenderImage decode above -- the sidecar
-- cover write needs an image *file*, and decoding to a BlitBuffer and
-- re-encoding back to webp is both lossy and unsolved in this codebase
-- (META-03/META-04). Same URL, same headers as getLibraryItemCover.
function AudiobookshelfApi:downloadCover(id, local_path)
    local server, token = credentials()
    if not server then
        -- Same guard testConnection uses, but no ErrorLog:record (OD-2): a
        -- missing/failed cover must never surface in Settings -> Recent
        -- errors, which is a user-facing buffer. logger.warn only.
        logger.warn("AudiobookshelfApi: cannot download cover, server/token not configured:", id)
        return false
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local outfile, err = io.open(local_path, "w")
    if not outfile then
        -- No ErrorLog:record here (OD-2): a missing/failed cover must never
        -- surface in Settings -> Recent errors, which is a user-facing
        -- buffer. logger.warn only, with the item id and reason.
        logger.warn("AudiobookshelfApi: cannot open local cover file for writing:", local_path, err)
        socketutil:reset_timeout()
        return false
    end
    local request = buildRequest(server, token,
        "/api/items/" .. util.urlEncode(id) .. "/cover?format=webp",
        ltn12.sink.file(outfile))
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok or code ~= 200 then
        -- Same close+remove cleanup as downloadFile, for the same reason:
        -- the sink only closes the handle on a clean end-of-stream.
        pcall(function() outfile:close() end)
        os.remove(local_path)
        logger.warn("AudiobookshelfApi: cannot download cover:", id, ok and (status or code) or "error")
        return false
    end
    return true
end

function AudiobookshelfApi:getSearchResults(id, search_query)
    local server, token = credentials()
    if not server then
        return unconfigured("getSearchResults")
    end
    local sink = {}
    local url_encoded_search_string = util.urlEncode(search_query)
    -- The `filter` parameter that used to sit here is dead: the search
    -- controller behind this endpoint reads only the query text and the
    -- limit (verified against server source at release v2.36.0), so the
    -- plugin was paying for a parameter that did nothing. The ebook test is
    -- applied client-side against the frame-cached snapshot instead
    -- (D-15/SRCH-07).
    local request = buildRequest(server, token,
        "/api/libraries/" .. util.urlEncode(id) .. "/search?q=" .. url_encoded_search_string .. "&limit=" .. SEARCH_GROUP_LIMIT,
        ltn12.sink.table(sink))
    -- This is a raised-limit search response on possibly-weak Wi-Fi -- use
    -- the large-content timeouts rather than the argument-less 5s/15s
    -- default.
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local response = table.concat(sink)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("AudiobookshelfApi: http request failed in getSearchResults:", code)
        ErrorLog:record(T("getSearchResults: connection failed: %1", tostring(code)))
        return nil, "connection"
    end
    if isRedirect(code) then
        return redirected("getSearchResults", code, status)
    end
    if code == 200 and response ~= "" then
        -- D-13's derived rule: a search response is malformed only when the
        -- top-level decode fails or is not a table. An absent or empty
        -- group key is not malformed -- it means only that the group
        -- matched nothing -- so no key is validated here.
        local result = self:decodeResponse(response, "getSearchResults")
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
    logger.warn("AudiobookshelfApi: cannot search library", id, status or code)
    ErrorLog:record(T("getSearchResults: server error: %1", tostring(status or code)))
    return nil, "server"
end

function AudiobookshelfApi:testConnection()
    local server = Settings:read("server")
    local token = Settings:read("token")
    if not server or server == "" then
        local message = _("Server URL is not set")
        logger.warn("AudiobookshelfApi: testConnection called with no server URL configured")
        ErrorLog:record(message)
        return false, message
    end
    if not token or token == "" then
        local message = _("API token is not set")
        logger.warn("AudiobookshelfApi: testConnection called with no API token configured")
        ErrorLog:record(message)
        return false, message
    end
    local sink = {}
    local request = buildRequest(server, token, "/api/me", ltn12.sink.table(sink))
    socketutil:set_timeout()
    local ok, code, _headers, status = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("AudiobookshelfApi: http request failed in testConnection:", code)
        local message = tostring(code)
        ErrorLog:record(T("testConnection: connection failed: %1", message))
        return false, message
    end
    if code == 200 then
        return true, nil
    end
    if isRedirect(code) then
        -- The one place a redirect gets a full sentence: this is the check a
        -- user runs when something is wrong, so name the two usual causes.
        local message = _("The server redirected the request instead of answering it. Check the URL (http vs https, extra path), or sign in to the Wi-Fi network first.")
        logger.warn("AudiobookshelfApi: testConnection redirected:", status or code)
        ErrorLog:record(message)
        return false, message
    end
    if code == 401 then
        local message = _("Invalid or expired API token")
        logger.warn("AudiobookshelfApi: testConnection unauthorized:", status or code)
        ErrorLog:record(message)
        return false, message
    end
    if code == 404 then
        local message = _("Server reached, but it does not support this connection check. Try browsing a library instead.")
        logger.warn("AudiobookshelfApi: testConnection endpoint not found:", status or code)
        ErrorLog:record(message)
        return false, message
    end
    local message = tostring(status or code)
    logger.warn("AudiobookshelfApi: testConnection failed:", status or code)
    ErrorLog:record(T("testConnection: unexpected error: %1", message))
    return false, message
end

return AudiobookshelfApi

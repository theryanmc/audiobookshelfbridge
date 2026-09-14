local AudiobookshelfApi = require("audiobookshelfbridge/audiobookshelfbridgeapi")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")

-- Plugin-scoped prefix for the temp cover file's name (T-04-09): the
-- filename is built only from this literal plus the item id plus ".webp" --
-- never from anything server-supplied (title, filename) -- so response
-- content has no path-traversal or collision vector into the temp path.
local TEMP_COVER_PREFIX = "audiobookshelfbridge-cover-"

-- Maps an Audiobookshelf library-item record onto KOReader's custom_props
-- sidecar (`<book>.sdr/custom_metadata.lua`) so the file browser and reader
-- display Audiobookshelf's title/author/series instead of the downloaded
-- EPUB's own (frequently wrong or missing) internal metadata (META-01,
-- META-02, META-05, META-06). See T-04-01/T-04-02 in 04-01-PLAN.md's
-- threat_model for why every value is type-guarded and why the sidecar is
-- always written through DocSettings rather than hand-built.
local MetadataWriter = {}

-- Type guard (T-04-02): a value is written into custom_props only when it
-- is exactly the Lua type KOReader's own consumers expect -- a non-empty
-- string. No trimming, no case change, no truncation, no UTF-8 repair: the
-- value passes through byte-for-byte or not at all. Keeps a nested JSON
-- object/array out of custom_props, where dump() would serialize it as a
-- Lua table and KOReader's consumers would then crash calling prop:find()
-- on it.
function MetadataWriter.stringProp(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- Type guard: a value is written into the series_index slot only when
-- tonumber() yields an actual number. Audiobookshelf sequences are strings
-- and are not always numeric (an omnibus can carry "1-3", a box set an
-- empty string) -- KOReader's schema requires a Lua number here
-- (document.lua:183 coerces with tonumber, and the native edit dialog
-- declares input_type = "number"). A non-numeric sequence therefore yields
-- no series_index key at all, never a string and never a zero.
function MetadataWriter.numberProp(value)
    local n = tonumber(value)
    if type(n) == "number" then
        return n
    end
    return nil
end

-- Returns a table with at most four keys -- title, authors, series,
-- series_index -- or nil when none apply. Every value is routed through
-- stringProp/numberProp: no UTF-8 repair, no Unicode normalization, no case
-- change, no truncation. A non-ASCII name reaches the sidecar as the exact
-- bytes Audiobookshelf sent.
function MetadataWriter.buildCustomProps(book_info)
    local metadata = book_info and book_info.media and book_info.media.metadata
    if not metadata then
        return nil
    end

    local props = {}

    local title = MetadataWriter.stringProp(metadata.title)
    if title then
        props.title = title
    end

    -- Newline-separated, not comma-joined: bookdetailswidget.lua's
    -- table.concat(book_authors, ", ") is for on-screen display only.
    -- KOReader's own multi-author convention splits an `authors` prop on
    -- "\n" (filemanagerbookinfo.lua:147-156) -- a comma-joined string
    -- renders as one garbled name everywhere else. Zero collected names
    -- means the key is omitted entirely, never an empty string.
    local authors = {}
    for _, author in ipairs(metadata.authors or {}) do
        if type(author) == "table" then
            local name = MetadataWriter.stringProp(author.name)
            if name then
                table.insert(authors, name)
            end
        end
    end
    if #authors > 0 then
        props.authors = table.concat(authors, "\n")
    end

    -- series / series_index: one unconditional defensive chain, not a
    -- branch selected by a prior check of the server's response shape --
    -- the array form (metadata.series = {{name, sequence}, ...}) and the
    -- flat form (metadata.seriesName = "Name #N") are both handled on every
    -- call, because the response may legitimately carry either. Only the
    -- first series entry is used: a book in several series has no single
    -- position, and KOReader's schema has one series_index slot.
    local series_entry = type(metadata.series) == "table" and metadata.series[1]
    if type(series_entry) == "table" then
        local series_name = MetadataWriter.stringProp(series_entry.name)
        if series_name then
            props.series = series_name
        end
        local series_index = MetadataWriter.numberProp(series_entry.sequence)
        if series_index then
            props.series_index = series_index
        end
    else
        local series_name_str = MetadataWriter.stringProp(metadata.seriesName)
        if series_name_str then
            -- Same split KOReader itself uses (document.lua:180-184) for a
            -- flat "Name #N" string.
            local name, idx = series_name_str:match("(.*) #(%d+%.?%d-)$")
            if name then
                props.series = name
                local series_index = MetadataWriter.numberProp(idx)
                if series_index then
                    props.series_index = series_index
                end
            else
                props.series = series_name_str
            end
        end
    end

    if next(props) == nil then
        return nil
    end
    return props
end

function MetadataWriter.writeMetadata(fullpath, book_info)
    local props = MetadataWriter.buildCustomProps(book_info)
    if not props then
        -- Nothing to write is not a failure.
        return true
    end

    -- policy: always-fresh (chosen at 04-01 checkpoint) -- Audiobookshelf is
    -- sole source of truth for the keys this plugin manages; any
    -- pre-existing custom_metadata.lua is replaced wholesale on every
    -- (re-)download, with no attempt to load or preserve it. The no-argument
    -- form starts from a blank in-memory object (frontend/docsettings.lua:301).
    local doc_settings = DocSettings.openSettingsFile()

    -- filemanagerbookinfo.lua's own BookInfo:setCustomMetadata later indexes
    -- doc_props unconditionally when the user edits a field by hand; a
    -- sidecar with no doc_props key makes that index into nil. Always write
    -- the key, even empty.
    doc_settings:saveSetting("doc_props", {})
    doc_settings:saveSetting("custom_props", props)

    local ok = doc_settings:flushCustomMetadata(fullpath)
    return ok and true or false
end

-- Fetches the Audiobookshelf cover as raw bytes to a temp file, then copies
-- it into the book's sidecar as cover.webp via DocSettings:flushCustomCover
-- (META-03). Never opens, decodes, or re-encodes the image (META-04
-- Anti-Patterns) -- downloadCover streams the response body straight to
-- disk, and flushCustomCover copies that file untouched. The temp file is
-- removed unconditionally on every path (T-04-10): flushCustomCover copies
-- rather than moves, so nothing else will ever clean it up.
function MetadataWriter.writeCover(fullpath, book_id)
    if not book_id then
        return false
    end

    -- T-04-09 hardening: book_id is read back out of the parsed JSON
    -- response body (server-supplied), so it's validated against an
    -- allowlist here rather than relying on TEMP_COVER_PREFIX's shape to
    -- incidentally block path-traversal/collision sequences (WR-02).
    -- WR-01 gap closure (GC-14): the class admits `_` because Audiobookshelf
    -- item ids are UUID-shaped on current servers but `li_`-prefixed on
    -- older ones, and this is the same rule downloadstaging.lua's
    -- safeComponent uses -- one rule, two call sites, deliberately written
    -- identically. The widening does not admit anything else: the pattern
    -- stays anchored at both ends, so the class still excludes the path
    -- separator, the backslash, the dot (hence any dot-segment), and
    -- whitespace, and the `+` quantifier still requires at least one
    -- character, so an empty id still fails.
    if not tostring(book_id):match("^[%w_%-]+$") then
        logger.warn("MetadataWriter: refusing to write cover for suspicious book id", tostring(book_id))
        return false
    end

    local temp_path = DataStorage:getDataDir() .. "/" .. TEMP_COVER_PREFIX .. tostring(book_id) .. ".webp"

    local fetch_ok = AudiobookshelfApi:downloadCover(book_id, temp_path)
    if not fetch_ok then
        -- Nothing was written (downloadCover cleans up its own partial
        -- file on failure) -- no temp file to remove here.
        return false
    end

    -- Colon call on the module table itself, exactly as
    -- BookInfo:setCustomCover does (filemanagerbookinfo.lua:524).
    local flush_ok = DocSettings:flushCustomCover(fullpath, temp_path)

    -- flushCustomCover copies temp_path; it never removes the source, and
    -- the caller owns cleanup. Unconditional so an early return above this
    -- point can never be the reason the temp file survives.
    os.remove(temp_path)

    return flush_ok and true or false
end

-- Mirrors KOReader's own post-edit flow (filemanagerbookinfo.lua:284-288,
-- 542-543) so coverbrowser.koplugin's list cache picks up the new metadata
-- on a re-download. A cheap no-op on a first download, where nothing is
-- cached yet.
function MetadataWriter.invalidateCache(fullpath)
    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", fullpath))
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
end

-- The single seam the download-success path calls. Never propagates an
-- error into the download flow (OD-2): a sidecar-write failure changes
-- nothing the user sees and leaves exactly one logger.warn line naming
-- only the book id and a short reason -- never the token, the metadata
-- table, the response body, or the props table, and never ErrorLog:record
-- or an InfoMessage (ErrorLog renders on screen in Settings -> Recent
-- errors, which OD-2 explicitly forbids for this path).
function MetadataWriter.writeAll(fullpath, book_info)
    local book_id = book_info and book_info.id

    local write_ok, write_result = pcall(MetadataWriter.writeMetadata, fullpath, book_info)
    if not write_ok then
        logger.warn("MetadataWriter: sidecar write raised an error for book", book_id, write_result)
        return
    end
    if not write_result then
        logger.warn("MetadataWriter: sidecar write reported failure for book", book_id)
        return
    end

    -- Cover failure is non-fatal and silent (OD-2): a 404 (no cover in
    -- Audiobookshelf -- the ordinary case) must leave the download's
    -- success reporting completely unchanged. pcall-wrapped like the
    -- metadata write above, but its own failure never stops the cache
    -- invalidation below -- the metadata write already succeeded and
    -- still needs the browser to pick it up.
    local cover_ok, cover_result = pcall(MetadataWriter.writeCover, fullpath, book_id)
    if not cover_ok then
        logger.warn("MetadataWriter: cover write raised an error for book", book_id, cover_result)
    elseif not cover_result then
        logger.warn("MetadataWriter: cover write reported failure for book", book_id)
    end

    local cache_ok, cache_err = pcall(MetadataWriter.invalidateCache, fullpath)
    if not cache_ok then
        logger.warn("MetadataWriter: cache invalidation raised an error for book", book_id, cache_err)
    end
end

return MetadataWriter

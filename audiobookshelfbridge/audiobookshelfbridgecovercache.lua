local AudiobookshelfApi = require("audiobookshelfbridge/audiobookshelfbridgeapi")
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- Disk cache for library-item covers.
--
-- Cover fetches are synchronous blocking HTTP on KOReader's single UI thread,
-- so a grid of tiles would otherwise stall the UI once per tile on every
-- visit. Caching the encoded bytes means a page pays that cost once; repeat
-- visits decode from local storage.
--
-- Deliberately caches the encoded file rather than a decoded BlitBuffer:
-- AudiobookshelfApi:downloadCover already writes raw bytes to a path (and
-- carries the zero-byte and timeout handling from META-03/CR-01), and a
-- BlitBuffer cache would pin far more memory than an e-reader has to spare.
local CoverCache = {}

local CACHE_SUBDIR = "cache/audiobookshelfbridge"
-- Covers are ~10-40KB each as webp; 256 entries is a few libraries' worth of
-- browsing and still small on the smallest device this runs on.
local MAX_ENTRIES = 256

-- lfs.mkdir creates a single level, so walk the segments. Returns the
-- directory path, or nil when it could not be created -- every caller treats
-- that as "no cache available" and falls back to a direct fetch.
local function ensureDir()
    local dir = DataStorage:getDataDir()
    for segment in string.gmatch(CACHE_SUBDIR, "[^/]+") do
        dir = dir .. "/" .. segment
        if lfs.attributes(dir, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(dir)
            if not ok and lfs.attributes(dir, "mode") ~= "directory" then
                -- Racing with another mkdir is fine; a real failure is not.
                logger.warn("CoverCache: cannot create cache dir:", dir, err)
                return nil
            end
        end
    end
    return dir
end

-- Item ids come from the server, so they never reach the filesystem raw.
-- Anything outside the allowlist collapses to "_", which keeps traversal
-- (".." , "/") and shell-significant characters out of the path entirely.
local function safeName(id)
    return (tostring(id):gsub("[^A-Za-z0-9_%-]", "_"))
end

function CoverCache:pathFor(id)
    local dir = ensureDir()
    if not dir then
        return nil
    end
    return dir .. "/" .. safeName(id) .. ".webp"
end

-- A zero-byte file is what a failed or empty transfer leaves behind. Treat it
-- as absent and remove it, so a transient failure cannot poison the cache for
-- an item permanently (the same reasoning as CR-01 on the download path).
local function usableFile(path)
    local size = lfs.attributes(path, "size")
    if size == nil then
        return false
    end
    if size == 0 then
        os.remove(path)
        return false
    end
    return true
end

-- Keeps the directory under MAX_ENTRIES by removing least-recently-modified
-- files first. Runs after a successful store, so the cache is trimmed on the
-- path that grows it rather than on the read path.
function CoverCache:evict()
    local dir = ensureDir()
    if not dir then
        return
    end
    local entries = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attrs = lfs.attributes(path)
            if attrs and attrs.mode == "file" then
                table.insert(entries, { path = path, time = attrs.modification or 0 })
            end
        end
    end
    if #entries <= MAX_ENTRIES then
        return
    end
    table.sort(entries, function(a, b) return a.time < b.time end)
    for i = 1, #entries - MAX_ENTRIES do
        os.remove(entries[i].path)
    end
end

-- Returns a BlitBuffer for the item's cover, or nil.
--
-- `width`/`height` are passed through to the decoder so scaling happens during
-- decode rather than by allocating full size and scaling after.
--
-- A cache miss is a blocking network fetch -- callers rendering more than one
-- tile should expect to pay for it and show progress.
function CoverCache:get(id, width, height)
    if id == nil then
        return nil
    end
    local path = self:pathFor(id)
    if not path then
        -- No writable cache: fall back to the uncached in-memory fetch so the
        -- caller still gets an image.
        return AudiobookshelfApi:getLibraryItemCover(id)
    end

    if not usableFile(path) then
        local ok = AudiobookshelfApi:downloadCover(id, path)
        if not ok or not usableFile(path) then
            -- downloadCover logs and, per OD-2, deliberately does not record a
            -- missing cover as a user-facing error. A tile just renders its
            -- fallback.
            return nil
        end
        self:evict()
    end

    local rendered, image = pcall(function()
        return RenderImage:renderImageFile(path, false, width, height)
    end)
    if not rendered or not image then
        -- A truncated or corrupt file decodes to nothing; drop it so the next
        -- visit refetches instead of failing forever.
        logger.warn("CoverCache: cannot decode cached cover, dropping:", path)
        os.remove(path)
        return nil
    end
    return image
end

-- Whether a cover is already local. Lets a caller render what it has
-- immediately and fetch the rest afterwards, instead of blocking on a page of
-- tiles before drawing anything.
function CoverCache:isCached(id)
    if id == nil then
        return false
    end
    local path = self:pathFor(id)
    return path ~= nil and usableFile(path)
end

function CoverCache:clear()
    local dir = ensureDir()
    if not dir then
        return 0
    end
    local removed = 0
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            if os.remove(dir .. "/" .. name) then
                removed = removed + 1
            end
        end
    end
    return removed
end

return CoverCache

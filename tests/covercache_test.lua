-- Run: luajit tests/covercache_test.lua

local sizes = {}
local dirs_ok = true

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, attr)
        if attr == "mode" then
            if dirs_ok then return "directory" end
            return nil
        elseif attr == "size" then
            return sizes[path]
        end
        return nil
    end,
    mkdir = function(_path) return nil, "denied" end,
    dir = function(_path) return function() return nil end end,
}
package.loaded.logger = { warn = function() end }
package.loaded.datastorage = { getDataDir = function() return "/nonexistent-covercache-test" end }
package.loaded["ui/renderimage"] = { renderImageFile = function(_path, _gray, _w, _h) return "sentinel-image" end }

-- Per-id fixture results driving both api stub functions.
local FIXTURES = {
    missing404 = { fail = 404 },
    flaky = { fail = "sink timeout" },
    servererr = { fail = 500 },
    zerobyte = { zero = true },
    good = {},
    fallback404 = { fail = 404 },
    fallbacktimeout = { fail = "timeout" },
}

local dl_calls, gc_calls = {}, {}

package.loaded["audiobookshelfbridge/api"] = {
    downloadCover = function(_self, id, path)
        dl_calls[id] = (dl_calls[id] or 0) + 1
        local fx = FIXTURES[id]
        if fx.fail then
            return false, fx.fail
        end
        if fx.zero then
            sizes[path] = 0
        else
            sizes[path] = 100
        end
        return true
    end,
    getLibraryItemCover = function(_self, id)
        gc_calls[id] = (gc_calls[id] or 0) + 1
        local fx = FIXTURES[id]
        if fx.fail then
            return nil, fx.fail
        end
        return "sentinel-image"
    end,
}

local CoverCache = require("audiobookshelfbridge/covercache")

-- 1. Definite 404: recorded, not retried.
local image = CoverCache:get("missing404", 100, 100)
assert(image == nil)
assert(CoverCache:isKnownMissing("missing404") == true)
assert(CoverCache:isCached("missing404") == false)
CoverCache:get("missing404", 100, 100)
assert(dl_calls["missing404"] == 1, "404 should not be retried")

-- 2. Timeout: NOT recorded, retried.
CoverCache:get("flaky", 100, 100)
assert(CoverCache:isKnownMissing("flaky") == false)
CoverCache:get("flaky", 100, 100)
assert(dl_calls["flaky"] == 2, "timeout must be retried")

-- 3. Other status (500): NOT recorded, retried.
CoverCache:get("servererr", 100, 100)
assert(CoverCache:isKnownMissing("servererr") == false)
CoverCache:get("servererr", 100, 100)
assert(dl_calls["servererr"] == 2, "non-404 status must be retried")

-- 4. Zero-byte body: NOT recorded, retried.
CoverCache:get("zerobyte", 100, 100)
assert(CoverCache:isKnownMissing("zerobyte") == false)
CoverCache:get("zerobyte", 100, 100)
assert(dl_calls["zerobyte"] == 2, "zero-byte body must be retried")

-- 5. Good cover: cached, not re-downloaded.
local good_image = CoverCache:get("good", 100, 100)
assert(good_image == "sentinel-image")
assert(CoverCache:isKnownMissing("good") == false)
assert(CoverCache:isCached("good") == true)
CoverCache:get("good", 100, 100)
assert(dl_calls["good"] == 1, "cached cover must not be re-downloaded")

print("PASS: covercache 404 memory, retry-on-transient-failure, and disk caching")

-- 6. countUncached: known-missing ids and non-book rows are excluded.
for _, name in ipairs({
    "ffi/blitbuffer", "ui/widget/container/centercontainer", "ui/font",
    "ui/widget/container/framecontainer", "ui/geometry", "ui/gesturerange",
    "ui/widget/horizontalgroup", "ui/widget/imagewidget", "ui/size",
    "ui/widget/textboxwidget", "ui/uimanager", "ui/widget/verticalgroup",
}) do
    package.loaded[name] = {}
end
package.loaded["ui/widget/container/inputcontainer"] = {
    extend = function(_self, t) return t end,
}
package.loaded.device = { screen = {} }

local CoverGrid = require("audiobookshelfbridge/covergrid")

local menu = {
    item_table = {
        { id = "missing404", type = "book" },   -- known-missing, not pending
        { id = "flaky", type = "book" },         -- pending: timed out, not recorded
        { id = "good", type = "book" },          -- cached, not pending
        { id = "neverfetched", type = "book" },  -- pending: never touched
        { id = "author1", type = "author" },     -- never has a cover, not pending
    },
}
local pending = CoverGrid.countUncached(menu, 0, 5)
assert(pending == 2, "expected exactly 2 pending covers, got " .. tostring(pending))

print("PASS: countUncached skips known-missing covers and non-book rows")

-- 7. clear() resets the negative cache.
CoverCache:clear()
assert(CoverCache:isKnownMissing("missing404") == false)
CoverCache:get("missing404", 100, 100)
assert(dl_calls["missing404"] == 2, "clear() must allow a re-fetch of a previously 404'd id")

print("PASS: clear() resets the session negative cache")

-- 8. No writable cache dir: get() falls back to getLibraryItemCover, and
-- D-02 still holds on that path. clear() still resets even though the
-- cache directory is unavailable.
dirs_ok = false

local none = CoverCache:get("fallback404", 100, 100)
assert(none == nil)
assert(CoverCache:isKnownMissing("fallback404") == true)
CoverCache:get("fallback404", 100, 100)
assert(gc_calls["fallback404"] == 1, "404 via the fallback path must not be retried")

CoverCache:get("fallbacktimeout", 100, 100)
assert(CoverCache:isKnownMissing("fallbacktimeout") == false)
CoverCache:get("fallbacktimeout", 100, 100)
assert(gc_calls["fallbacktimeout"] == 2, "timeout via the fallback path must be retried")

local removed = CoverCache:clear()
assert(removed == 0, "no writable cache dir clears nothing on disk")
assert(CoverCache:isKnownMissing("fallback404") == false, "clear() must reset the cache with no writable dir")

print("PASS: fallback path (no writable cache dir) honors D-02, and clear() still resets")

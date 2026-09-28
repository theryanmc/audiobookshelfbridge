-- Run: luajit tests/covercache_test.lua

local sizes = {}
local dirs_ok = true

-- CR-L3: per-path touch call counts and a switchable failure mode, so a
-- cache-hit read can be proven to refresh mtime exactly once, and a failed
-- or raising touch proven not to break the read.
local touch_calls = {}
local touch_mode = "ok" -- "ok" | "fail" | "raise"

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
    touch = function(path)
        touch_calls[path] = (touch_calls[path] or 0) + 1
        if touch_mode == "raise" then
            error("touch raised")
        elseif touch_mode == "fail" then
            return nil, "read-only"
        end
        return true
    end,
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

-- 5. Good cover: cached, not re-downloaded. CR-L3: a cache hit refreshes
-- mtime via a tolerated lfs.touch, which is what makes evict() LRU rather
-- than FIFO.
local good_path = "/nonexistent-covercache-test/cache/audiobookshelfbridge/good.webp"
local good_image = CoverCache:get("good", 100, 100)
assert(good_image == "sentinel-image")
assert(CoverCache:isKnownMissing("good") == false)
assert(CoverCache:isCached("good") == true)
assert((touch_calls[good_path] or 0) == 0, "a fresh download must not touch (its mtime is already current)")
CoverCache:get("good", 100, 100)
assert(dl_calls["good"] == 1, "cached cover must not be re-downloaded")
assert((touch_calls[good_path] or 0) == 1, "a cache hit must touch exactly once")

-- A touch failure (nil, err) or a raise must never break the read.
touch_mode = "fail"
local still_good = CoverCache:get("good", 100, 100)
assert(still_good == "sentinel-image", "a failed touch must not break the read")
touch_mode = "raise"
local still_good2 = CoverCache:get("good", 100, 100)
assert(still_good2 == "sentinel-image", "a raising touch must not break the read")
touch_mode = "ok"

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

-- 9. BookDetailsWidget: the cover comes through CoverCache (CR-L4) with
-- correct aspect ratio and single ownership, and genFileList skips every
-- malformed file (CR-L2). Drives the real widget code.
dirs_ok = true

-- Case 8 ended with clear(), which also reset "missing404"'s negative
-- cache entry from case 1/7 -- re-fetch it once so it is known-missing
-- again before the "no ImageWidget" assertion below.
CoverCache:get("missing404", 100, 100)
assert(CoverCache:isKnownMissing("missing404") == true)

local function passthroughNew(_self, t) return t or {} end

-- Already-stubbed widget tables (case 6) need `new` added: countUncached
-- never constructed one of these, but genBookDetails/genFileList do.
package.loaded["ui/widget/container/centercontainer"].new = passthroughNew
package.loaded["ui/widget/container/framecontainer"].new = passthroughNew
package.loaded["ui/widget/horizontalgroup"].new = passthroughNew
package.loaded["ui/widget/verticalgroup"].new = passthroughNew
package.loaded["ui/widget/textboxwidget"].new = passthroughNew

local imagewidget_calls = {}
package.loaded["ui/widget/imagewidget"].new = function(_self, t)
    table.insert(imagewidget_calls, t)
    return t
end

-- The remaining modules bookdetailswidget.lua requires that case 6 never
-- touched.
package.loaded["ui/widget/focusmanager"] = {
    extend = function(_self, t) return t end,
}
-- case 6's "ui/size" = {} is enough for CoverGrid (fields only read inside
-- functions never called there), but BookDetailsWidget reads
-- Size.padding.fullscreen at module load time.
package.loaded["ui/size"] = { padding = { fullscreen = 0 } }
package.loaded["ui/widget/horizontalspan"] = { new = passthroughNew }
package.loaded["ui/widget/verticalspan"] = { new = passthroughNew }
package.loaded["ui/widget/textwidget"] = { new = passthroughNew }
package.loaded["ui/widget/container/leftcontainer"] = {}
package.loaded["ui/widget/linewidget"] = {}
package.loaded["ui/widget/scrolltextwidget"] = {}
package.loaded["ui/widget/titlebar"] = {}
package.loaded["ui/event"] = {}
package.loaded["ui/widget/infomessage"] = {}
package.loaded.gettext = function(text) return text end

local ebookfilewidget_calls = {}
package.loaded["audiobookshelfbridge/ebookfilewidget"] = {
    new = function(_self, t)
        table.insert(ebookfilewidget_calls, t)
        return t
    end,
}

package.loaded.device = {
    screen = {
        getWidth = function(_self) return 600 end,
        getHeight = function(_self) return 800 end,
        getScreenMode = function(_self) return "portrait" end,
        scaleBySize = function(_self, size) return size end,
    },
}

local function fakeImage(w, h)
    return {
        w = w, h = h,
        getWidth = function(self) return self.w end,
        getHeight = function(self) return self.h end,
    }
end

-- Replace renderImageFile so it records the w/h it was called with and
-- returns a decodable 600x900 buffer; add scaleBlitBuffer alongside it.
local renderfile_calls = {}
package.loaded["ui/renderimage"].renderImageFile = function(_self, _path, _gray, w, h)
    table.insert(renderfile_calls, { w = w, h = h })
    return fakeImage(600, 900)
end
local scaleblit_calls = {}
package.loaded["ui/renderimage"].scaleBlitBuffer = function(_self, _image, w, h, free_orig)
    table.insert(scaleblit_calls, { w = w, h = h, free_orig = free_orig })
    return fakeImage(w, h)
end

local BookDetailsWidget = require("audiobookshelfbridge/bookdetailswidget")

local widget = setmetatable({
    book_id = "good",
    book_info = { id = "good" },
    layout = {},
}, { __index = BookDetailsWidget })

local before_dl_good = dl_calls["good"]
local before_gc_good = gc_calls["good"] or 0
local before_iw = #imagewidget_calls
widget:genBookDetails()
assert(dl_calls["good"] == before_dl_good, "a cache hit must not re-download")
assert((gc_calls["good"] or 0) == before_gc_good, "a cache hit must not use the uncached fallback")
local last_render = renderfile_calls[#renderfile_calls]
assert(last_render and last_render.w == nil and last_render.h == nil,
    "genBookDetails must fetch the cover with no width/height")
assert(#imagewidget_calls == before_iw + 1, "expected exactly one ImageWidget for a decodable cover")
local iw = imagewidget_calls[#imagewidget_calls]
assert(iw.image_disposable == true, "ImageWidget must own the buffer (image_disposable)")
assert(iw.width <= 198 and iw.height <= 276, "the cover must fit inside the portrait box")
local last_scale = scaleblit_calls[#scaleblit_calls]
assert(last_scale and last_scale.free_orig == true, "scaleBlitBuffer must free the pre-scale original")
assert(math.abs((iw.width / iw.height) - (600 / 900)) < 0.01, "aspect ratio must be preserved within 1px")

-- A known-missing cover produces no ImageWidget and no extra download.
widget.book_id = "missing404"
local before_iw2 = #imagewidget_calls
widget:genBookDetails()
assert(#imagewidget_calls == before_iw2, "a known-missing cover must produce no ImageWidget")

print("PASS: genBookDetails fetches the cover through CoverCache with correct aspect ratio and ownership")

-- genFileList: a mix of well-formed and malformed ebook files.
local files = {
    { fileType = "ebook", ino = "1", metadata = { filename = "good.epub", size = 1000 } }, -- well-formed
    { fileType = "ebook", ino = "2" },                                        -- missing metadata
    { fileType = "ebook", ino = "3", metadata = {} },                         -- missing filename
    { fileType = "ebook", metadata = { filename = "noino.epub" } },           -- missing ino
    "bad-string-entry",                                                      -- string entry
    42,                                                                      -- number entry
    { fileType = "audio", ino = "4", metadata = { filename = "audio.mp3" } }, -- non-ebook file
}
widget.book_id = "good"
widget.book_info = { id = "good", libraryFiles = files }
widget.layout = {}
widget:genFileList()
assert(#ebookfilewidget_calls == 1, "expected exactly one EbookFileWidget for the well-formed file")
assert(#widget.layout == 1, "expected exactly one focusable layout row")

print("PASS: genFileList skips every malformed file, building exactly one EbookFileWidget row")

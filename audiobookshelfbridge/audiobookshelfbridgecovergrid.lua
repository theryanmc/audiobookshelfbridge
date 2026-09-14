local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local CoverCache = require("audiobookshelfbridge/audiobookshelfbridgecovercache")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")

local Device = require("device")
local Screen = Device.screen

local CoverGrid = {}

-- Target tile width, and the cover aspect the Audiobookshelf API returns
-- (roughly 2:3). scaleBySize converts to pixels for the device's DPI, so the
-- tile stays about the same physical size across screens.
local TARGET_TILE_DP = 170
local CAPTION_DP = 28
local COVER_ASPECT = 1.5
local MIN_COLS, MAX_COLS = 2, 5

-- Grid shape for the space available.
--
-- Column count is derived from a target tile WIDTH rather than being fixed.
-- Fixing the column count makes tile width grow with the screen, so a wide
-- screen ends up with a few enormous covers and a single row; deriving columns
-- keeps tiles a roughly constant physical size and adds columns instead.
-- Still clamped: one column is just a list with bigger rows, and past five the
-- covers stop being identifiable.
function CoverGrid.shapeFor(width, height)
    local target = Screen:scaleBySize(TARGET_TILE_DP)
    local cols = math.floor(width / target + 0.5)
    if cols < MIN_COLS then cols = MIN_COLS end
    if cols > MAX_COLS then cols = MAX_COLS end
    local tile_w = math.floor(width / cols)
    local tile_h = math.floor(tile_w * COVER_ASPECT) + Screen:scaleBySize(CAPTION_DP)
    local rows = math.floor(height / tile_h)
    if rows < 1 then rows = 1 end
    return cols, rows
end

-- One cover tile. InputContainer with onFocus/onUnfocus matches how
-- EbookFileWidget already participates in FocusManager, so D-pad traversal
-- works the same way on non-touch devices.
local CoverTile = InputContainer:extend{
    entry = nil,
    menu = nil,
    width = nil,
    height = nil,
    idx = nil,
}

function CoverTile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    if Device:isTouchDevice() then
        self.ges_events = {
            TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    self[1] = self:buildContent(false)
end

-- `focused` only changes the frame around the tile, so focus can be redrawn
-- without refetching or re-decoding the cover.
function CoverTile:buildContent(focused)
    local padding = Size.padding.small
    local caption_h = Screen:scaleBySize(28)
    local inner_w = self.width - 2 * padding
    local cover_h = self.height - caption_h - 2 * padding

    local cover = self:buildCover(inner_w, cover_h)

    local caption = TextBoxWidget:new{
        text = self.entry.text or "",
        face = Font:getFace("infont", 14),
        width = inner_w,
        alignment = "center",
        height = caption_h,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }

    return FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = padding,
        bordersize = focused and Size.border.thick or 0,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = cover_h },
                cover,
            },
            caption,
        },
    }
end

-- Returns the cover image, or a framed placeholder. A missing cover is normal
-- (not every library item has one) and per OD-2 must never surface as an
-- error, so the fallback is silent.
--
-- Only book rows have a cover to fetch. Search results mix in authors and
-- series whose ids address different endpoints entirely, so they go straight
-- to the placeholder rather than spending a blocking request on a request that
-- would 404.
function CoverTile:buildCover(width, height)
    if self.entry.type == "book" then
        local ok, image = pcall(function()
            return CoverCache:get(self.entry.id, width, height)
        end)
        if ok and image then
            return ImageWidget:new{
                image = image,
                width = width,
                height = height,
                -- the BlitBuffer came from the cache decode and belongs to
                -- this widget now; let it be freed when the tile goes away
                image_disposable = true,
            }
        end
        if not ok then
            logger.warn("CoverGrid: cover fetch failed for", self.entry.id, image)
        end
    end
    local inner_w = width - 2 * Size.padding.small
    local label = VerticalGroup:new{ align = "center" }
    table.insert(label, TextBoxWidget:new{
        text = self.entry.text or "",
        face = Font:getFace("infont", 14),
        width = inner_w,
        alignment = "center",
    })
    -- Authors and series carry their kind in `mandatory`; without it a bare
    -- name in a box gives no clue what tapping it does.
    if self.entry.type ~= "book" and self.entry.mandatory then
        table.insert(label, TextBoxWidget:new{
            text = self.entry.mandatory,
            face = Font:getFace("infont", 12),
            width = inner_w,
            alignment = "center",
        })
    end
    return FrameContainer:new{
        width = width,
        height = height,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY,
        padding = Size.padding.small,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = height - 2 * Size.padding.small },
            label,
        },
    }
end

function CoverTile:onFocus()
    self[1] = self:buildContent(true)
    UIManager:setDirty(self.menu.show_parent, "ui", self.dimen)
    return true
end

function CoverTile:onUnfocus()
    self[1] = self:buildContent(false)
    UIManager:setDirty(self.menu.show_parent, "ui", self.dimen)
    return true
end

function CoverTile:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

-- How many covers on this page still need fetching. Only book rows have one,
-- and isCached is a stat call, so this is cheap relative to the fetches it is
-- deciding whether to warn about.
function CoverGrid.countUncached(menu, idx_offset, perpage)
    local pending = 0
    for idx = 1, perpage do
        local item = menu.item_table[idx_offset + idx]
        if item and item.type == "book" and not CoverCache:isCached(item.id) then
            pending = pending + 1
        end
    end
    return pending
end

-- forceRePaint is what actually gets the message on screen: the fetches that
-- follow run on the same thread, so without it the notice would not paint
-- until after the work it is announcing had finished.
--
-- Wrapped in pcall throughout. A notice is a courtesy -- it must never be the
-- reason a page fails to draw.
function CoverGrid.showLoading(pending)
    if pending <= 0 then
        return nil
    end
    local ok, notice = pcall(function()
        local InfoMessage = require("ui/widget/infomessage")
        local _ = require("gettext")
        local T = require("ffi/util").template
        local msg = InfoMessage:new{
            text = pending == 1 and _("Loading cover…")
                or T(_("Loading %1 covers…"), pending),
        }
        UIManager:show(msg)
        UIManager:forceRePaint()
        return msg
    end)
    if not ok then
        logger.warn("CoverGrid: could not show loading notice:", notice)
        return nil
    end
    return notice
end

function CoverGrid.hideLoading(notice)
    if not notice then
        return
    end
    pcall(function() UIManager:close(notice) end)
end

-- Grid replacement for Menu:updateItems. Mirrors that method's contract --
-- reset layout and groups, recalculate dimensions, build the page, then
-- updatePageInfo / mergeTitleBarIntoLayout / setDirty -- so paging, the page
-- counter and FocusManager keep working exactly as they do for the list.
function CoverGrid.updateItems(menu, select_number, no_recalculate_dimen)
    local old_dimen = menu.dimen and menu.dimen:copy()
    menu.layout = {}
    menu.item_group:clear()
    menu.page_info:resetLayout()
    menu.return_button:resetLayout()
    menu.content_group:resetLayout()
    menu:_recalculateDimen(no_recalculate_dimen)

    local cols = menu.grid_cols or 2
    local rows = menu.grid_rows or 1
    local perpage = cols * rows
    local idx_offset = (menu.page - 1) * perpage
    local tile_w = math.floor(menu.inner_dimen.w / cols)
    local tile_h = math.floor(menu.available_height / rows)

    -- Building the tiles below blocks on one HTTP request per uncached cover.
    -- Announce it first, but only when there is actually something to fetch --
    -- a cached page draws immediately and a flashed message would be noise.
    local pending = CoverGrid.countUncached(menu, idx_offset, perpage)
    local notice = CoverGrid.showLoading(pending)

    for row = 1, rows do
        local row_group = HorizontalGroup:new{}
        local row_layout = {}
        for col = 1, cols do
            local idx = (row - 1) * cols + col
            local index = idx_offset + idx
            local item = menu.item_table[index]
            if item then
                item.idx = index -- valid only for displayed items, as in Menu
                if index == menu.itemnumber then
                    select_number = idx
                end
                local tile = CoverTile:new{
                    entry = item,
                    menu = menu,
                    idx = index,
                    width = tile_w,
                    height = tile_h,
                    show_parent = menu.show_parent,
                }
                table.insert(row_group, tile)
                table.insert(row_layout, tile)
            end
        end
        if #row_layout > 0 then
            table.insert(menu.item_group, row_group)
            -- one layout row per grid row gives FocusManager real 2D movement
            table.insert(menu.layout, row_layout)
        end
    end

    CoverGrid.hideLoading(notice)

    menu:updatePageInfo(select_number)
    menu:mergeTitleBarIntoLayout()

    UIManager:setDirty(menu.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(menu.dimen) or menu.dimen
        return "ui", refresh_dimen
    end)
end

return CoverGrid

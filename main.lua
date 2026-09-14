local Dispatcher = require("dispatcher")
local AudiobookshelfBrowser = require("audiobookshelfbridge/audiobookshelfbridgebrowser")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

-- Shared by the menu_items key and the menu order tables below; the sorter
-- matches one against the other, so they must not drift apart.
local MENU_ID = "audiobookshelfbridge"

local Audiobookshelf = WidgetContainer:extend{
    name = "audiobookshelfbridge",
    is_doc_only = false,
}

-- MenuSorter treats an item whose id is missing from the menu order tables as
-- an orphan and appends it to the end of its `sorting_hint` section, which is
-- why this entry used to land at the bottom of Tools. `sorting_hint` picks the
-- section but not the position -- that comes from the id being present in
-- `order.tools`. The order modules ship inside the (read-only) app image, but
-- they are plain `require`d tables, so mutating the cached copy is enough.
-- Same approach storefront.koplugin uses to seat itself near the top.
local function injectIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }
    local function indexOf(tbl, target_id)
        for i, val in ipairs(tbl) do
            if val == target_id then
                return i
            end
        end
        return nil
    end

    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            -- guard: addToMainMenu runs once per FileManager/Reader instance
            if not indexOf(order.tools, MENU_ID) then
                -- Sit directly below Storefront when it is installed. If it
                -- has not registered yet it inserts itself at 2 afterwards,
                -- which pushes this entry down to the same spot either way.
                local storefront_at = indexOf(order.tools, "Storefront")
                table.insert(order.tools, storefront_at and storefront_at + 1 or 2, MENU_ID)
            end
        end
    end
end

function Audiobookshelf:onDispatcherRegisterActions()
    -- none atm
end

function Audiobookshelf:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Audiobookshelf:addToMainMenu(menu_items)
    injectIntoToolsMenu()
    -- Opens the browser directly rather than a submenu: settings and search
    -- are reachable from the browser's own title bar, so a two-row menu in
    -- front of it was a step with nothing on it.
    menu_items[MENU_ID] = {
        text = _("Audiobookshelf Bridge"),
        -- fallback only: used if the order tables could not be required
        sorting_hint = "tools",
        callback = function()
            local connect_callback = function()
                UIManager:show(AudiobookshelfBrowser:new())
            end
            NetworkMgr:runWhenOnline(connect_callback)
        end,
    }
end

return Audiobookshelf

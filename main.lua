local Dispatcher = require("dispatcher")
local AudiobookshelfBrowser = require("audiobookshelfbridge/audiobookshelfbridgebrowser")
local SettingsMenu = require("audiobookshelfbridge/audiobookshelfbridgesettingsmenu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

local Audiobookshelf = WidgetContainer:extend{
    name = "audiobookshelfbridge",
    is_doc_only = false,
}

function Audiobookshelf:onDispatcherRegisterActions()
    -- none atm
end

function Audiobookshelf:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Audiobookshelf:addToMainMenu(menu_items)
    menu_items.audiobookshelfbridge = {
        text = _("Audiobookshelf"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Browse library"),
                callback = function()
                    local connect_callback = function()
                        UIManager:show(AudiobookshelfBrowser:new())
                    end
                    NetworkMgr:runWhenOnline(connect_callback)
                end
            },
            {
                text = _("Settings"),
                callback = function()
                    UIManager:show(SettingsMenu:new{})
                end
            },
        }
    }
end

return Audiobookshelf

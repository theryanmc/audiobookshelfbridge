local Screen = require("device").screen
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconButton = require("ui/widget/iconbutton")
local TitleBar = require("ui/widget/titlebar")
local _ = require("gettext")

-- Implement Menu's title-bar interface while keeping the plugin name visible.
local BrowserTitleBar = HorizontalGroup:extend{}

function BrowserTitleBar:init()
    local icon_size = Screen:scaleBySize(24)
    local padding = Screen:scaleBySize(12)
    self.label = TitleBar:new{
        width = self.width - 3 * (icon_size + 2 * padding),
        align = "left",
        fullscreen = true,
        title = _("Audiobookshelf Bridge"),
        subtitle = _("Libraries"),
        show_parent = self.browser,
    }
    local function button(icon, callback)
        return Button:new{
            icon = icon,
            width = icon_size + 2 * padding,
            height = icon_size + 2 * padding,
            bordersize = 0,
            background = nil,
            show_parent = self.browser,
            callback = callback,
        }
    end
    self.search_button = button("appbar.search", function()
        if self.browser.library_id then
            self.browser:ShowSearch()
        end
    end)
    self.search_button:enableDisable(self.browser.library_id ~= nil)
    self.search_button:showHide(self.browser.library_id ~= nil)
    self.settings_button = button("appbar.settings", function()
        self.browser:onLeftButtonTap()
    end)
    self.close_button = IconButton:new{
        icon = "close",
        width = icon_size,
        height = icon_size,
        padding = padding,
        show_parent = self.browser,
        allow_flash = false,
        callback = function() self.browser:onClose() end,
    }
    self[1] = self.label
    self[2] = self.search_button
    self[3] = self.settings_button
    self[4] = self.close_button
end

function BrowserTitleBar:getHeight()
    return self:getSize().h
end

function BrowserTitleBar:setTitle(title, no_refresh)
    self.label:setSubTitle(self.browser.level == "abs" and _("Libraries") or title, no_refresh)
    self.search_button:enableDisable(self.browser.library_id ~= nil)
    self.search_button:showHide(self.browser.library_id ~= nil)
    self:resetLayout()
end

function BrowserTitleBar:generateVerticalLayout()
    if not self.browser.library_id then
        return {{ self.settings_button, self.close_button }}
    end
    return {{ self.search_button, self.settings_button, self.close_button }}
end

return BrowserTitleBar

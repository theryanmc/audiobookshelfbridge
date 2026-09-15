local Screen = require("device").screen
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconButton = require("ui/widget/iconbutton")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

-- Implement Menu's title-bar interface while keeping the plugin name visible.
local BrowserTitleBar = VerticalGroup:extend{ align = "left" }

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
    self[1] = HorizontalGroup:new{
        self.label, self.search_button, self.settings_button, self.close_button,
    }
    self.tab_buttons = {}
    self.tab_labels = { books = _("Books"), series = _("Series"), authors = _("Authors") }
    self.tabs = HorizontalGroup:new{}
    local tab_width = math.floor(self.width / 3)
    for index, tab in ipairs({ "books", "series", "authors" }) do
        local tab_button = Button:new{
            text = self.tab_labels[tab],
            width = index == 3 and self.width - 2 * tab_width or tab_width,
            height = Screen:scaleBySize(40),
            bordersize = 0,
            show_parent = self.browser,
            callback = function() self.browser:switchLibraryTab(tab) end,
        }
        self.tab_buttons[tab] = tab_button
        self.tabs[index] = tab_button
    end
    self:updateTabs()
end

function BrowserTitleBar:updateTabs()
    self[2] = self.browser.level == "library" and self.tabs or nil
    for tab, button in pairs(self.tab_buttons) do
        local label = self.tab_labels[tab]
        button:setText(self.browser.library_tab == tab and "● " .. label or label, button.width)
    end
    self.tabs:resetLayout()
    self:resetLayout()
end

function BrowserTitleBar:getHeight()
    return self:getSize().h
end

function BrowserTitleBar:setTitle(title, no_refresh)
    self.label:setSubTitle(self.browser.level == "abs" and _("Libraries") or title, no_refresh)
    self.search_button:enableDisable(self.browser.library_id ~= nil)
    self.search_button:showHide(self.browser.library_id ~= nil)
    self[1]:resetLayout()
    self:updateTabs()
end

function BrowserTitleBar:generateVerticalLayout()
    if not self.browser.library_id then
        return {{ self.settings_button, self.close_button }}
    end
    local layout = {{ self.search_button, self.settings_button, self.close_button }}
    if self.browser.level == "library" then
        layout[2] = { self.tab_buttons.books, self.tab_buttons.series, self.tab_buttons.authors }
    end
    return layout
end

function BrowserTitleBar:free()
    if not self[2] then self.tabs:free() end
    VerticalGroup.free(self)
end

return BrowserTitleBar

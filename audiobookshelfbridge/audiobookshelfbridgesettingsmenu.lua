local Settings = require("audiobookshelfbridge/audiobookshelfbridgesettings")
local AudiobookshelfApi = require("audiobookshelfbridge/audiobookshelfbridgeapi")
local ErrorLog = require("audiobookshelfbridge/audiobookshelfbridgeerrorlog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local VERSION = require("audiobookshelfbridge_version")

local SettingsMenu = Menu:extend{
    no_title = false,
    title = _("Audiobookshelf Settings"),
    is_popout = false,
    is_borderless = true,
    show_parent = nil
}

function SettingsMenu:init()
    self.show_parent = self
    self.item_table = self:genItemTable()
    Menu.init(self)
end

-- Resolves the folder the download dialog would default to: the stored
-- download_dir when set, else the reader's own last-used directory setting,
-- matching the fallback chain ebookfilewidget.lua's download dialog already
-- uses (SET-06/empty).
function SettingsMenu:getDownloadFolder()
    local download_dir = Settings:read("download_dir", "")
    if download_dir == "" then
        download_dir = G_reader_settings:readSetting("lastdir")
    end
    return download_dir
end

function SettingsMenu:genItemTable()
    local item_table = {}
    table.insert(item_table, {
        text = T(_("Server URL: %1"), Settings:read("server", _("not set"))),
        type = "server",
    })

    local token_value = Settings:read("token", "")
    local token_state = (token_value ~= "" and _("configured")) or _("not set")
    table.insert(item_table, {
        text = T(_("API token: %1"), token_state),
        type = "token",
    })

    local download_folder = self:getDownloadFolder()
    if not download_folder or download_folder == "" then
        download_folder = _("not set")
    end
    table.insert(item_table, {
        text = T(_("Download folder: %1"), download_folder),
        type = "download_dir",
    })

    table.insert(item_table, {
        text = _("Libraries"),
        type = "libraries",
    })

    local grid_view = Settings:read("book_view", "grid") ~= "list"
    table.insert(item_table, {
        text = T(_("Book view: %1"), grid_view and _("cover tiles") or _("list")),
        type = "book_view",
    })

    table.insert(item_table, {
        text = _("Test connection"),
        type = "test",
    })

    table.insert(item_table, {
        text = T(_("Version: %1"), table.concat(VERSION, ".")),
        type = "version",
    })

    table.insert(item_table, {
        text = T(_("Recent errors (%1)"), #ErrorLog:getRecent()),
        type = "errors",
    })

    return item_table
end

function SettingsMenu:refresh()
    self:switchItemTable(self.title, self:genItemTable())
end

function SettingsMenu:onMenuSelect(item)
    if item.type == "server" then
        self:editServer()
    elseif item.type == "token" then
        self:editToken()
    elseif item.type == "download_dir" then
        self:chooseDownloadFolder()
    elseif item.type == "libraries" then
        self:showLibraryVisibility()
    elseif item.type == "book_view" then
        self:toggleBookView()
    elseif item.type == "test" then
        self:runConnectionTest()
    elseif item.type == "errors" then
        self:showRecentErrors()
    elseif item.type == "version" then
        -- Informational row only; focusable and activatable but a no-op
        -- (SET-13/empty).
    end
    return true
end

-- Two states, so the row toggles in place rather than opening a submenu for a
-- binary choice. Takes effect on the next level the browser draws.
function SettingsMenu:toggleBookView()
    local grid_view = Settings:read("book_view", "grid") ~= "list"
    Settings:write("book_view", grid_view and "list" or "grid")
    self:refresh()
end

function SettingsMenu:editServer()
    local dialog
    dialog = InputDialog:new{
        title = _("Server URL"),
        input = Settings:read("server", ""),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        dialog:onClose()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = dialog:getInputText()
                        local trimmed = value:match("^%s*(.-)%s*$") or ""
                        if trimmed == "" or not (trimmed:match("^http://") or trimmed:match("^https://")) then
                            UIManager:show(InfoMessage:new{
                                text = _("Server URL must start with http:// or https://"),
                            })
                            return
                        end
                        Settings:write("server", trimmed)
                        dialog:onClose()
                        UIManager:close(dialog)
                        self:refresh()
                        UIManager:show(InfoMessage:new{
                            text = _("Settings saved"),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SettingsMenu:editToken()
    local dialog
    dialog = InputDialog:new{
        title = _("API token"),
        input = Settings:read("token", ""),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        dialog:onClose()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = dialog:getInputText()
                        Settings:write("token", value)
                        dialog:onClose()
                        UIManager:close(dialog)
                        self:refresh()
                        UIManager:show(InfoMessage:new{
                            text = _("Settings saved"),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SettingsMenu:chooseDownloadFolder()
    local current = self:getDownloadFolder()
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            Settings:write("download_dir", path)
            self:refresh()
        end,
    }:chooseDir(current)
end

-- Builds the per-library toggle rows. A nil or zero-length getLibraries()
-- result takes the same placeholder branch (decision D-O) so a genuinely
-- empty server and a failed fetch both render one inert row instead of an
-- empty menu (SET-07/empty, SET-10/empty). The enabled test below is exact
-- inequality to `true` -- a stray nil or false value reads as enabled
-- (SET-08/adjacency) -- and the library array is walked with ipairs, never
-- pairs, so row order matches the server's order on every reopen
-- (SET-07/ordering).
function SettingsMenu:genLibraryVisibilityItemTable()
    local item_table = {}
    local libraries = AudiobookshelfApi:getLibraries()
    if not libraries or #libraries == 0 then
        table.insert(item_table, {
            text = _("Could not load libraries. Check your connection and settings."),
            type = "placeholder",
        })
        return item_table
    end
    local disabled = Settings:read("disabled_libraries", {})
    for _, library in ipairs(libraries) do
        table.insert(item_table, {
            text = library.name,
            id = library.id,
            type = "library_toggle",
            mandatory = (disabled[library.id] ~= true) and "\xE2\x9C\x93" or "",
        })
    end
    return item_table
end

-- Per decision D-L this is a separate child Menu widget closed by Back, not
-- a switchItemTable drill-down within the settings screen -- so it has no
-- path stack to get wrong and nothing here touches self.item_table.
function SettingsMenu:showLibraryVisibility()
    local menu
    menu = Menu:new{
        title = _("Libraries"),
        item_table = self:genLibraryVisibilityItemTable(),
        is_popout = false,
        is_borderless = true,
    }
    menu.show_parent = menu
    menu.onMenuSelect = function(_child, item)
        if item.type == "placeholder" then
            -- Inert row: must not crash and must not close the list
            -- (SET-10, SET-13/empty).
            return true
        elseif item.type == "library_toggle" then
            local disabled = Settings:read("disabled_libraries", {})
            if disabled[item.id] == true then
                -- Re-enabling removes the key rather than storing false, so
                -- repeated toggling cannot accumulate dead keys
                -- (SET-07/adjacency, SET-09/idempotency).
                disabled[item.id] = nil
            else
                disabled[item.id] = true
            end
            -- Write and flush at the moment of the toggle, not deferred to
            -- menu close (SET-09/concurrency).
            Settings:write("disabled_libraries", disabled)
            menu:switchItemTable(menu.title, self:genLibraryVisibilityItemTable())
        end
        return true
    end
    UIManager:show(menu)
end

function SettingsMenu:runConnectionTest()
    local ok, error_text = AudiobookshelfApi:testConnection()
    if ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Connection to %1 succeeded"), Settings:read("server", "")),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Connection failed: %1"), error_text),
        })
    end
    self:refresh()
end

function SettingsMenu:showRecentErrors()
    local recent = ErrorLog:getRecent()
    if #recent == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No errors have been recorded this session."),
        })
        return
    end
    local lines = { _("This list covers the current KOReader session only.") }
    for i = #recent, 1, -1 do
        table.insert(lines, recent[i])
    end
    UIManager:show(TextViewer:new{
        title = _("Recent errors"),
        text = table.concat(lines, "\n"),
    })
end

return SettingsMenu

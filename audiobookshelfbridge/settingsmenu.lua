local Settings = require("audiobookshelfbridge/settings")
local AudiobookshelfApi = require("audiobookshelfbridge/api")
local ErrorLog = require("audiobookshelfbridge/errorlog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
-- Required here, not in api.lua: tests/transport_test.lua and
-- tests/api_metadata_test.lua load the real api.lua unstubbed and must
-- keep doing so; the connectivity check for Sign out (F33-D4) belongs
-- with the UI that needs it.
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
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

-- F33: maps a signIn() failure reason/detail to a message naming what
-- actually went wrong. A module-level function, outside any loop -- this
-- file never shadows the single-underscore gettext identifier, so every
-- branch below can call _()/T() directly. "connection", "redirect" and
-- "unreadable" reuse AudiobookshelfApi:testConnection's / the browser's
-- exact msgids on purpose, so a translation covering those already covers
-- these too.
function SettingsMenu.signInFailureText(reason, detail)
    if reason == "unconfigured" then
        return _("Set the server URL before signing in.")
    elseif reason == "invalid_credentials" then
        return _("Wrong username or password.")
    elseif reason == "rate_limited" then
        return _("Too many sign-in attempts. Wait a few minutes and try again.")
    elseif reason == "connection" then
        return T(_("Could not reach the server (%1). Check the server URL and your Wi-Fi connection."),
            tostring(detail))
    elseif reason == "redirect" then
        return _("The server redirected the request instead of answering it. Check the URL (http vs https, extra path), or sign in to the Wi-Fi network first.")
    elseif reason == "server" then
        return T(_("Sign-in failed (HTTP %1)."), tostring(detail))
    elseif reason == "unreadable" then
        return _("Audiobookshelf sent a response this plugin could not read. See Recent errors in Settings.")
    elseif reason == "unsupported" then
        return _("This server did not return a sign-in session and may be too old. Use an API token instead.")
    end
    return _("Sign-in failed. Check network and settings, then try again.")
end

function SettingsMenu:genItemTable()
    local item_table = {}
    table.insert(item_table, {
        text = T(_("Server URL: %1"), Settings:read("server", _("not set"))),
        type = "server",
    })

    -- F33-D2: signing in leaves a stored API token in place -- it stops
    -- being used, but stays as the fallback after sign-out or expiry.
    local signed_in = AudiobookshelfApi:isSignedIn()
    if signed_in then
        table.insert(item_table, {
            text = T(_("Signed in as %1"), Settings:read("username", "")),
            type = "sign_in",
        })
        table.insert(item_table, {
            text = _("Sign out"),
            type = "sign_out",
        })
    else
        table.insert(item_table, {
            text = _("Sign in with username and password"),
            type = "sign_in",
        })
    end

    local token_value = Settings:read("token", "")
    local token_state
    if token_value == "" then
        token_state = _("not set")
    elseif signed_in then
        token_state = _("configured, not used while signed in")
    else
        token_state = _("configured")
    end
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
    elseif item.type == "sign_in" then
        self:signIn()
    elseif item.type == "sign_out" then
        self:confirmSignOut()
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
                        -- CR-F4: normalize before validating and saving, so
                        -- "https://host/" is stored as "https://host" and a
                        -- trailing-slash-only value reads as invalid rather
                        -- than as a URL.
                        trimmed = AudiobookshelfApi.normalizeServerUrl(trimmed)
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
                        if trimmed:match("^http://") then
                            -- S4: plaintext HTTP puts the API token on the
                            -- wire in the clear on every request. Say so at
                            -- the moment it is chosen, once, rather than
                            -- accepting it silently.
                            UIManager:show(InfoMessage:new{
                                text = _("Saved. This address uses http://, so your API token is sent unencrypted on every request. Use https:// if your server supports it."),
                                timeout = 6,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Settings saved"),
                                timeout = 1,
                            })
                        end
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
    local has_token = Settings:read("token", "") ~= ""
    dialog = InputDialog:new{
        title = _("API token"),
        -- S3: never pre-fill the stored token. The settings row already says
        -- "configured" without showing the value; loading the whole token
        -- into a visible field undid that for anyone looking at the screen.
        -- Empty on open, masked while typing, and an empty save keeps what
        -- is already stored rather than wiping it.
        input = "",
        input_hint = has_token and _("Leave empty to keep the current token")
            or _("Paste your API token"),
        text_type = "password",
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
                        dialog:onClose()
                        UIManager:close(dialog)
                        if trimmed == "" then
                            UIManager:show(InfoMessage:new{
                                text = has_token and _("Token unchanged") or _("No token entered"),
                                timeout = 1,
                            })
                            return
                        end
                        Settings:write("token", trimmed)
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

-- AUTH-01/AUTH-02, per F33-D2/F33-D8: a two-field MultiInputDialog
-- (username pre-filled, password masked and never pre-filled), FocusManager
-- traversal comes free with that widget. The password is never stored on
-- self, in Settings, or in any table that outlives the nextTick callback
-- below.
function SettingsMenu:signIn()
    local server = AudiobookshelfApi.normalizeServerUrl(Settings:read("server"))
    if type(server) ~= "string" or server == "" then
        UIManager:show(InfoMessage:new{
            text = SettingsMenu.signInFailureText("unconfigured"),
            timeout = 2,
        })
        return
    end

    local fields = {
        {
            text = Settings:read("username", ""),
            hint = _("Username"),
        },
        {
            text = "",
            hint = _("Password"),
            text_type = "password",
        },
    }
    if server:match("^http://") then
        -- F33-D8: warn before the password is ever sent.
        fields[2].description = _("This server uses http://, so your password will be sent unencrypted. Use https:// if possible.")
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = _("Sign in to Audiobookshelf"),
        fields = fields,
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
                    text = _("Sign in"),
                    callback = function()
                        local values = dialog:getFields()
                        local username = (values[1] or ""):match("^%s*(.-)%s*$") or ""
                        -- Never trim the password: spaces are legal, and an
                        -- empty password is allowed (some Audiobookshelf
                        -- accounts have none).
                        local password = values[2] or ""
                        if username == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Enter your username."),
                                timeout = 2,
                            })
                            return
                        end
                        dialog:onClose()
                        UIManager:close(dialog)
                        local progress = InfoMessage:new{
                            text = _("Signing in…"),
                        }
                        UIManager:show(progress)
                        UIManager:nextTick(function()
                            UIManager:forceRePaint()
                            local pok, ok, reason, detail = pcall(AudiobookshelfApi.login,
                                AudiobookshelfApi, username, password)
                            UIManager:close(progress)
                            if pok and ok then
                                self:refresh()
                                if server:match("^http://") then
                                    UIManager:show(InfoMessage:new{
                                        text = _("Signed in. This address uses http://, so your session is sent unencrypted on every request. Use https:// if your server supports it."),
                                        timeout = 6,
                                    })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Signed in as %1"), username),
                                        timeout = 2,
                                    })
                                end
                            else
                                if not pok then
                                    logger.warn("SettingsMenu: sign-in raised:", ok)
                                    reason, detail = nil, nil
                                end
                                UIManager:show(InfoMessage:new{
                                    text = SettingsMenu.signInFailureText(reason, detail),
                                })
                            end
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- F33-D4: local clear first (always shown as success), then a best-effort
-- server revoke only when the reader is actually connected -- gated on
-- NetworkMgr:isConnected(), which never prompts to turn Wi-Fi on and does
-- no DNS lookup. Scheduled after the result message is already shown and
-- painted, so the user is never left waiting on it.
function SettingsMenu:confirmSignOut()
    UIManager:show(ConfirmBox:new{
        text = _("Sign out of Audiobookshelf?"),
        ok_text = _("Sign out"),
        ok_callback = function()
            local revoke = AudiobookshelfApi:signOut()
            self:refresh()
            local has_token = Settings:read("token", "") ~= ""
            UIManager:show(InfoMessage:new{
                text = has_token and _("Signed out. The API token will be used from now on.") or _("Signed out"),
                timeout = 2,
            })
            if revoke then
                local check_ok, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
                if check_ok and connected then
                    UIManager:nextTick(function()
                        UIManager:forceRePaint()
                        pcall(revoke)
                    end)
                end
            end
        end,
    })
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

local AudiobookshelfApi = require("audiobookshelfbridge/api")
local Settings = require("audiobookshelfbridge/settings")
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local MetadataWriter = require("audiobookshelfbridge/metadatawriter")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local ReaderUI = require("apps/reader/readerui")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local util = require("util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template
local _ = require("gettext")

local EbookFileWidget = InputContainer:extend{
    filename = nil,
    ino = nil,
    size_in_bytes = 0,
    book_id = nil,
    book_info = nil,
    width = nil,
    side_margin = Size.padding.fullscreen,
    onClose = nil -- function to close whole parent menu path after download
}

-- CR-F5: maps a downloadFile failure reason/detail (see AudiobookshelfApi:
-- downloadFile's return contract) to a message naming what actually went
-- wrong, instead of always saying "Could not save file to:" regardless of
-- cause. A module-level function, defined outside any loop -- this file
-- never shadows the single-underscore gettext identifier, so every branch
-- below can call _()/T() directly.
function EbookFileWidget.downloadFailureText(reason, detail, path)
    if reason == "unconfigured" then
        return _("Set your server URL and sign in (or add an API token) in Settings before downloading.")
    elseif reason == "session_expired" then
        return _("Your sign-in has expired. Sign in again in Settings, then retry the download.")
    elseif reason == "redirect" then
        return _("The server redirected the download. Check the server URL, or sign in to the Wi-Fi network first.")
    elseif reason == "connection" then
        if type(detail) == "string" and detail:find("timeout") then
            return _("The download timed out. Check your Wi-Fi connection and try again.")
        end
        return _("Could not reach the server. Check your Wi-Fi connection and try again.")
    elseif reason == "server" then
        return T(_("The server could not send this file (HTTP %1)."), tostring(detail))
    elseif reason == "incomplete" then
        return _("The download was cut off before the whole file arrived. Try again.")
    elseif reason == "open_failed" then
        -- Verbatim, so existing translations still match.
        return T(_("Could not save file to:\n%1"), BD.filepath(path))
    elseif reason == "commit_failed" then
        return T(_("Could not save file to:\n%1\nThe existing file could not be replaced."), BD.filepath(path))
    end
    return _("The download failed. Check network and settings, then try again.")
end

function EbookFileWidget:init()
    self.small_font = Font:getFace("smallffont")
    self.medium_font = Font:getFace("ffont")

    local first_text = TextBoxWidget:new{
        text = self.filename or "",
        face = self.small_font,
        width = (self.width - self.side_margin * 2) * 0.75
    }
    local content_height = first_text:getSize().h
    local left_container = LeftContainer:new{
        dimen = Geom:new{w = self.width - self.side_margin * 2, h =  content_height},
        first_text
    }
    local last_text = TextWidget:new{
        text = util.getFriendlySize(self.size_in_bytes),
        face = self.small_font
    }
    local right_container = RightContainer:new{
        dimen = Geom:new{w = self.width - self.side_margin * 2, h = content_height},
        last_text,
    }
    local overlay_container = OverlapGroup:new{
        dimen = Geom:new{w = self.width - self.side_margin * 2, h = content_height},
        left_container,
        right_container
    }

    self.underline_container = UnderlineContainer:new{
        linesize = Size.line.thin,
        padding = Size.padding.default,
        vertical_align = "center",
        color = Blitbuffer.COLOR_DARK_GRAY,
        overlay_container
    }
    -- Wrap in a frame so we can visually highlight the row when it is focused
    -- via the D-pad / physical keys on non-touch devices.
    self.frame = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.underline_container,
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.frame:getSize().h },
        self.frame
    }

    self.dimen = Geom:new{ w = self.width, h = self.frame:getSize().h }
    self.ges_events = {
        TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen
            },
        },
        HoldSelect = {
            GestureRange:new{
                ges = self.handle_hold_on_hold_release and "hold_release" or "hold",
                range = self.dimen
            },
        },
    }
end

function EbookFileWidget:onTapSelect()
    -- make sure it exists first
    if not self[1].dimen then return end
    self:downloadFile()
end

function EbookFileWidget:onHoldSelect()
    -- make sure it exists first
    if not self[1].dimen then return end
    -- stub for adding long hold functionality
    logger.warn(self.book_id, self.ino)
end

-- Called by the parent FocusManager when this row gains focus (D-pad / keys).
function EbookFileWidget:onFocus()
    self.frame.background = Blitbuffer.COLOR_LIGHT_GRAY
    self.underline_container.color = Blitbuffer.COLOR_BLACK
    return true
end

-- Called by the parent FocusManager when this row loses focus.
function EbookFileWidget:onUnfocus()
    self.frame.background = Blitbuffer.COLOR_WHITE
    self.underline_container.color = Blitbuffer.COLOR_DARK_GRAY
    return true
end

function EbookFileWidget:downloadFile()
    local function startDownloadFile(filename, path, callback_close)
        -- Local filesystem work, no network -- stays outside the wake.
        local safeFilename = util.getSafeFilename(filename, path, 230)
        -- D-14: everything past this point needs the network, so it moves
        -- inside the wake's callback -- including the "Downloading"
        -- announcement, which must not appear before the device is
        -- actually online (that would be exactly the silent-failure shape
        -- REL-05 names). The wake sits outside the deferred tick, not
        -- inside it: nesting the wake inside nextTick would mean the tick
        -- ran before the device even starts reconnecting.
        local connect_callback = function()
            -- CR-F6: no timeout -- this stays on screen for the whole
            -- blocking transfer below, however long that takes, and is
            -- closed explicitly the moment the transfer finishes.
            local info_down = InfoMessage:new{
                text = _("Downloading. This might take a moment."),
            }
            UIManager:show(info_down, "flashui")
            -- CR-F6: one tick, not one second. The overwrite ConfirmBox (the
            -- caller of startDownloadFile) calls its ok_callback before
            -- closing itself, and deferring one tick lets that dialog leave
            -- the stack first.
            UIManager:nextTick(function()
                -- Scheduled tasks run before UIManager's own repaint
                -- (uimanager.lua's _checkTasks then _repaint), so without
                -- this the "Downloading" message would not actually paint
                -- before the blocking call below stalls the event loop.
                UIManager:forceRePaint()
                -- CR-F5: pcall so an unexpected raise still closes the
                -- progress message instead of leaving it stuck; treated as
                -- a failure with no specific reason.
                local pok, dl_ok, reason, detail = pcall(AudiobookshelfApi.downloadFile,
                    AudiobookshelfApi, self.book_id, self.ino, safeFilename, path)
                UIManager:close(info_down)
                if pok and dl_ok then
                    MetadataWriter.writeAll(path .. "/" .. safeFilename, self.book_info)

                    local confirm = ConfirmBox:new{
                        text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"),
                            BD.filepath(path .. "/" .. safeFilename)),
                        ok_callback = function()
                            local Event = require("ui/event")
                            UIManager:broadcastEvent(Event:new("SetupShowReader"))

                            if callback_close then
                                callback_close()
                            end
                            ReaderUI:showReader(path .. "/" .. safeFilename)
                        end
                    }
                    -- force full refresh / flash to avoid clipped rendering
                    UIManager:show(confirm, "flashui")
                else
                    if not pok then
                        logger.warn("EbookFileWidget: download raised:", dl_ok)
                        reason, detail = nil, nil
                    else
                        logger.warn("EbookFileWidget: download failed:", reason, detail)
                    end
                    -- No timeout, like the success ConfirmBox above: a long
                    -- download means the user may have looked away.
                    local info_err = InfoMessage:new{
                        text = EbookFileWidget.downloadFailureText(reason, detail, path),
                    }
                    UIManager:show(info_err, "flashui")
                end
            end)
        end
        NetworkMgr:runWhenOnline(connect_callback)
    end

    local function genTitle(original_filename, size, filename, path)
        local filesize_str = self.size_in_bytes and util.getFriendlySize(self.size_in_bytes) or _("N/A")

        return T(_("Filename:\n%1\n\nFile size:\n%2\n\nDownload filename:\n%3\n\nDownload folder:\n%4"),
            original_filename, filesize_str, filename, BD.dirpath(path))
    end

    local download_dir = Settings:read("download_dir") or G_reader_settings:readSetting("lastdir")
    local chosen_filename = self.filename

    local buttons = {
        {
            {
                text = _("Choose folder"),
                callback = function()
                    require("ui/downloadmgr"):new{
                        onConfirm = function(path)
                            Settings:write("download_dir", path)
                            download_dir = path
                            self.download_dialog:setTitle(genTitle(self.filename, self.size_in_bytes, chosen_filename, path))
                        end,
                    }:chooseDir(download_dir)
                end,
            },
            {
                text = _("Change filename"),
                callback = function()
                    local input_dialog
                    input_dialog = InputDialog:new{
                        title = _("Enter filename"),
                        input = chosen_filename,
                        input_hint = self.filename,
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(input_dialog)
                                    end,
                                },
                                {
                                    text = _("Set filename"),
                                    is_enter_default = true,
                                    callback = function()
                                        chosen_filename = input_dialog:getInputValue()
                                        if chosen_filename == "" then
                                            chosen_filename = self.filename
                                        end
                                        UIManager:close(input_dialog)
                                        self.download_dialog:setTitle(genTitle(self.filename, self.size_in_bytes, chosen_filename, download_dir))
                                    end,
                                },
                            }
                        },
                    }
                    UIManager:show(input_dialog)
                    input_dialog:onShowKeyboard()
                end,
            },
        },
        {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(self.download_dialog)
                end,
            },
            {
                text = _("Download"),
                callback = function()
                    UIManager:close(self.download_dialog)
                    -- call parent close callback safely without passing this widget as `self`
                    local callback_close = function()
                        if type(self.onClose) == "function" then
                            self.onClose()
                        end
                    end

                    -- ensure chosen_filename is sanitized for existence check
                    local safeFilename = util.getSafeFilename(chosen_filename, download_dir, 230)
                    local fullpath = (download_dir == "/" and ("/" .. safeFilename)) or (download_dir .. "/" .. safeFilename)

                    if lfs.attributes(fullpath) then
                        UIManager:show(ConfirmBox:new{
                            text = _("File already exists. Would you like to overwrite it?"),
                            ok_callback = function()
                                startDownloadFile(chosen_filename, download_dir, callback_close)
                            end
                        }, "flashui")
                    else
                        startDownloadFile(chosen_filename, download_dir, callback_close)
                    end
                end,
            },
        },
    }

    self.download_dialog = ButtonDialog:new{
        title = genTitle(self.filename, self.size_in_bytes, chosen_filename, download_dir),
        buttons = buttons,
    }
    UIManager:show(self.download_dialog)
end

return EbookFileWidget

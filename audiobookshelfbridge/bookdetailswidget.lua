local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local CoverCache = require("audiobookshelfbridge/covercache")
local EbookFileWidget = require("audiobookshelfbridge/ebookfilewidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TitleBar = require("ui/widget/titlebar")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Device = require("device")
local Screen = Device.screen

local Event = require("ui/event")
local AudiobookshelfApi = require("audiobookshelfbridge/api")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")

local BookDetailsWidget = FocusManager:extend{
    padding = Size.padding.fullscreen,
    onCloseParent = nil,
}

function BookDetailsWidget:onClose()
    UIManager:close(self)
end

function BookDetailsWidget:closeAndReturnToBrowser()
    UIManager:close(self)
    if self.onCloseParent then
        -- call as a zero-argument function to avoid passing this widget as `self`
        self.onCloseParent()
    end
end

function BookDetailsWidget:init()
    self.layout = {}

    local reason
    self.book_info, reason = AudiobookshelfApi:getLibraryItem(self.book_id)
    if not self.book_info then
        local text = _("Could not load book details. Check network and settings.")
        if reason == "unreadable" then
            text = _("Audiobookshelf sent a response this plugin could not read. See Recent errors in Settings.")
        elseif reason == "session_expired" then
            text = _("Your sign-in has expired. Sign in again in Settings.")
        end
        UIManager:show(InfoMessage:new{
            text = text,
            timeout = 2,
        })
        -- Mark the failure instead of closing: the widget is not on the
        -- UIManager stack yet during init, so closing here is a no-op. The
        -- caller must check this flag and skip UIManager:show entirely --
        -- an empty widget left on top of the stack would swallow every tap
        -- and key.
        self.load_failed = true
        return
    end

    self.small_font = Font:getFace("smallffont")
    self.medium_font = Font:getFace("ffont")

    local screen_size = Screen:getSize()
    self[1] = FrameContainer:new{
        width = screen_size.w,
        height = screen_size.h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        self:getDetailsContent(screen_size.w)
    }

    self.dithered = true

    -- Allow closing the screen with a physical key (e.g. Back) on non-touch devices.
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- On devices without touch, focus the first downloadable file so it can be
    -- selected and downloaded entirely with the D-pad / physical keys.
    if Device:hasDPad() and not Device:isTouchDevice()
            and self.layout[1] and self.layout[1][1] then
        self.selected = { x = 1, y = 1 }
        self.layout[1][1]:handleEvent(Event:new("Focus"))
    end
end

function BookDetailsWidget:getDetailsContent(width)
    local title_bar = TitleBar:new{
        width = width,
        bottom_v_padding = 0,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local content = VerticalGroup:new{
        align = "left",
        title_bar,
        self:genBookDetails(),
        self:genHeader(_("Description")),
        self:genDescriptionContent(),
        self:genHeader(_("Files")),
        self:genFileList(),
    }
    return content
end

function BookDetailsWidget:genFileList()
    local screen_height = Screen:getHeight()
    local screen_width = Screen:getWidth()
    local list = VerticalGroup:new{
        height =  screen_height * 0.2,
    }
    for _, file in ipairs(self.book_info.libraryFiles or {}) do
        -- CR-L2: every field below is server-supplied and untrusted in
        -- shape. `type(file) == "table"` must short-circuit first -- Lua
        -- indexing a bare number or string entry the fixture also carries
        -- would otherwise raise (a string indexes as nil via its own
        -- metatable, but a number does not). The ino check matters most:
        -- the download URL is built from file.ino outside any pcall, and
        -- util.urlEncode(nil) returns nil, so a nil ino would raise
        -- "attempt to concatenate a nil value" the moment a download is
        -- attempted.
        if type(file) == "table" and file.fileType == "ebook"
                and type(file.metadata) == "table"
                and type(file.metadata.filename) == "string" and file.metadata.filename ~= ""
                and (type(file.ino) == "string" and file.ino ~= "" or type(file.ino) == "number") then
            local file_widget = EbookFileWidget:new{
                width = screen_width,
                ino = file.ino,
                filename = file.metadata.filename,
                -- tonumber(nil) is nil, which falls back to
                -- EbookFileWidget's own default of 0.
                size_in_bytes = tonumber(file.metadata.size),
                book_id = self.book_info.id,
                book_info = self.book_info,
                show_parent = self,
                -- pass a zero-arg closure that will call this widget's onClose
                onClose = function()
                    self:closeAndReturnToBrowser()
                end,
            }
            table.insert(list, file_widget)
            -- Register each file as its own focusable row so the FocusManager
            -- can move between them with the D-pad / physical keys.
            table.insert(self.layout, { file_widget })
        end
    end
    return list
end

function BookDetailsWidget:genBookDetails()
    local screen_width = Screen:getWidth()

    local img_width, img_height
    if Screen:getScreenMode() == "landscape" then
        img_width = Screen:scaleBySize(132)
        img_height = Screen:scaleBySize(184)
    else
        img_width = Screen:scaleBySize(132 * 1.5)
        img_height = Screen:scaleBySize(184 * 1.5)
    end

    -- Mirror metadatawriter.lua's own defensive pattern: guard the whole
    -- media/metadata chain once here, near the top, and fall back to an
    -- empty table so every downstream `or ""` / `or {}` still works even if
    -- the server returned a malformed or unexpectedly-shaped payload.
    local metadata = self.book_info.media and self.book_info.media.metadata or {}

    local book_authors = {}
    for _, author in ipairs(metadata.authors or {}) do
        table.insert(book_authors, author.name)
    end
    local book_author_string = table.concat(book_authors, ", ")

    local book_metadata_group = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = img_height * 0.15},
    }
    table.insert(book_metadata_group,
        TextBoxWidget:new{ -- book title
            text = metadata.title or "",
            face = self.medium_font,
            alignment = "left",
        }
    )
    if metadata.seriesName and metadata.seriesName ~= "" then
        table.insert(book_metadata_group,
            TextBoxWidget:new{ -- book series (if applicable)
                text = metadata.seriesName,
                face = self.small_font,
                alignment = "left",
            }
        )
    end
    table.insert(book_metadata_group,
        TextBoxWidget:new{ -- book author
            text = _("by") .. " " .. book_author_string,
            face = self.small_font,
            alignment = "left",
        }
    )
    local metadata_label_group = VerticalGroup:new{
        align = "left",
        TextWidget:new{ -- book publish year
            text = _("Publish year"),
            face = self.small_font,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        },
        TextWidget:new{ -- book publish year
            text = _("Publisher"),
            face = self.small_font,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        },
        TextWidget:new{ -- book publish year
            text = _("Genres"),
            face = self.small_font,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        },
        TextWidget:new{ -- book publish year
            text = _("Language"),
            face = self.small_font,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        },
    }

    local metadata_labeled_group = VerticalGroup:new{
        align = "left",
        TextWidget:new{ -- book publish year
            text = metadata.publishedYear or "",
            face = self.small_font,
            alignment = "left",
        },
        TextWidget:new{ -- book publish year
            text = metadata.publisher or "",
            face = self.small_font,
            alignment = "left",
        },
        TextWidget:new{ -- book publish year
            text = table.concat(metadata.genres or {}, ", "),
            face = self.small_font,
            alignment = "left",
        },
        TextWidget:new{ -- book publish year
            text = metadata.language or "",
            face = self.small_font,
            alignment = "left",
        },
    }

    local extra_metadata_group = HorizontalGroup:new{
        align = "top",
        metadata_label_group,
        HorizontalSpan:new{ width = math.floor(screen_width * 0.02)},
        metadata_labeled_group,
    }

    table.insert(book_metadata_group, extra_metadata_group)



    local book_details_group = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = math.floor(screen_width * 0.05) }
    }

    -- CR-L4: through CoverCache instead of an uncached direct API call, so
    -- book details shares the disk cache and the session 404 memory (D-02)
    -- with the grid tiles (covergrid.lua). No width/height passed:
    -- RenderImage's decoder stretches to an exact box when given both, with
    -- no aspect handling, so decoding at native size is what lets the
    -- aspect-preserving scale-down block below keep working unchanged.
    local cover_ok, image = pcall(function() return CoverCache:get(self.book_id) end)
    if not cover_ok then
        logger.warn("BookDetailsWidget: cover fetch raised:", image)
        image = nil
    end

    if image then
        local actual_w, actual_h = image:getWidth(), image:getHeight()
        if actual_w > img_width or actual_h > img_height then
            local scale_factor = math.min(img_width / actual_w, img_height / actual_h)
            actual_w = math.min(math.floor(actual_w * scale_factor)+1, img_width)
            actual_h = math.min(math.floor(actual_h * scale_factor)+1, img_height)
            image = RenderImage:scaleBlitBuffer(image , actual_w, actual_h, true)
        end
        -- Ownership (CR-L4): CoverCache:get decodes a fresh BlitBuffer on
        -- every call -- it caches encoded bytes on disk, never a decoded
        -- buffer, and CoverTile's buffers (covergrid.lua) are separate
        -- decodes. scaleBlitBuffer(..., true) above frees the pre-scale
        -- original, and image_disposable = true means ImageWidget frees
        -- the final buffer when this screen closes -- exactly one owner,
        -- so no double free and no leak.
        table.insert(book_details_group, ImageWidget:new{
            image = image,
            width = actual_w,
            height = actual_h,
            image_disposable = true,
        })
    end

    table.insert(
        book_details_group,
        HorizontalSpan:new{ width = math.floor(screen_width * 0.05) }
    )
    table.insert(book_details_group, book_metadata_group)

    return book_details_group
end

function BookDetailsWidget:genHeader(title)
    local width, height = Screen:getWidth(), Size.item.height_default

    local header_title = TextWidget:new{
        text = title,
        face = self.medium_font,
        fgcolor = Blitbuffer.COLOR_GRAY_9
    }
    local padding_span = HorizontalSpan:new{ width = self.padding }
    local line_width = (width - header_title:getSize().w) / 2 - self.padding * 2
    local line_container = LeftContainer:new{
        dimen = Geom:new{ w = line_width, h = height },
        LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{
                w = line_width,
                h = Size.line.thick,
            }
        }
    }

    local span_top, span_bottom
    if Screen:getScreenMode() == "landscape" then
        span_top = VerticalSpan:new{ width = Size.span.horizontal_default }
        span_bottom = VerticalSpan:new{ width = Size.span.horizontal_default }
    else
        span_top = VerticalSpan:new{ width = Size.item.height_default }
        span_bottom = VerticalSpan:new{ width = Size.span.vertical_large }
    end

    return VerticalGroup:new{
        span_top,
        HorizontalGroup:new{
            align = "center",
            padding_span,
            line_container,
            padding_span,
            header_title,
            padding_span,
            line_container,
            padding_span,
        },
        span_bottom,
    }
end

function BookDetailsWidget:genDescriptionContent()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local metadata = self.book_info.media and self.book_info.media.metadata or {}
    local text = ScrollTextWidget:new{
        text = self:stripBasicHTMLTags(metadata.description or ""),
        face = self.small_font,
        width = screen_width - self.padding * 2,
        height = screen_height * 0.2,
        dialog = self,
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = screen_width, h = text:getSize().h },
        text
    }
end

function BookDetailsWidget:stripBasicHTMLTags(text)
    return string.gsub(text, '<[^>]*>', '')
end

return BookDetailsWidget
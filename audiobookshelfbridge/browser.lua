local AudiobookshelfApi = require("audiobookshelfbridge/api")
local BookDetailsWidget = require("audiobookshelfbridge/bookdetailswidget")
local BrowserTitleBar = require("audiobookshelfbridge/titlebar")
local LibraryTabs = require("audiobookshelfbridge/librarytabs")
local CoverGrid = require("audiobookshelfbridge/covergrid")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Settings = require("audiobookshelfbridge/settings")
local SettingsMenu = require("audiobookshelfbridge/settingsmenu")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

-- D-10: the unsequenced-volume label. Deliberately not gettext-wrapped -- it
-- is punctuation with nothing to translate -- and hoisted to a named
-- constant to keep it out of loop bodies where the gettext identifier is
-- shadowed.
local NO_SEQUENCE_LABEL = "-"

-- D-09: the decimal-safe series comparator. A file-scope local, not a
-- method, so it can be handed straight to table.sort. Parses both operands
-- with tonumber: numeric values ascend; nil, empty and non-numeric values
-- (tonumber returns nil for both in Lua 5.1) sort after every numbered
-- entry; ties -- including the both-unparseable case -- break on row text,
-- coalescing a missing title to the empty string so no comparison can raise.
local function compareSeriesRows(a, b)
    local na = tonumber(a.sequence)
    local nb = tonumber(b.sequence)
    if na and nb then
        if na ~= nb then
            return na < nb
        end
        return (a.text or "") < (b.text or "")
    end
    if na and not nb then
        return true
    end
    if nb and not na then
        return false
    end
    return (a.text or "") < (b.text or "")
end

-- Title comparator for the author level (03-02). A file-scope local, like
-- compareSeriesRows, so it can be handed straight to table.sort.
-- Coalesces a missing text to the empty string first so a row with no
-- title cannot raise a comparison error. Title order is the deliberate
-- choice for an author's list -- D-09 governs series lists only, and
-- title order is what the library-items call already asks the server
-- for, so the author level matches the library level a user just came
-- from.
local function compareByTitle(a, b)
    return (a.text or "") < (b.text or "")
end

local AudiobookshelfBrowser = Menu:extend{
    no_title = false,
    title = _("Audiobookshelf Bridge"),
    is_popout = false,
    is_borderless = true,
    show_parent = nil
}

-- levels:
-- abs
-- library
function AudiobookshelfBrowser:init()
    self.show_parent = self
    self.level = "abs"
    self.current_title = self.title
    self.library_id = nil
    if self.item then
    else
        self.item_table = self:genItemTableFromLibraries()
    end
    self.custom_title_bar = BrowserTitleBar:new{
        width = self.width or require("device").screen:getWidth(),
        browser = self,
    }
    Menu.init(self)
    -- The library rows already exclude libraries disabled in Settings.
    -- Initialize Menu first so the normal loader can update its title and grid.
    if not self.item and #self.item_table == 1 and self.item_table[1].type == "library" then
        local library = self.item_table[1]
        if self:openLibrary(library.id, library.text) then
            -- Make this library the navigation root. A failed load leaves the
            -- picker available for retrying or opening Settings.
            table.remove(self.item_table_stack)
        end
    end
end

-- Also used by Menu's hardware menu-key handler.
function AudiobookshelfBrowser:onLeftButtonTap()
    UIManager:show(SettingsMenu:new{})
end

-- Cover tiles apply to any level that contains at least one book.
--
-- This deliberately does not require every row to be a book. Search results
-- mix authors and series in with books, and requiring a uniform table dropped
-- the whole results level back to text rows -- the one place a cover is most
-- useful for telling near-identical titles apart. Author and series rows have
-- no cover, so they render as labelled text tiles and never trigger a fetch.
--
-- The top level lists libraries and contains no books at all, so it keeps the
-- list renderer; so does an empty table, which keeps its empty state.
function AudiobookshelfBrowser:levelHasBooks()
    if not self.item_table or #self.item_table == 0 then
        return false
    end
    for _, row in ipairs(self.item_table) do
        if row.type == "book" then
            return true
        end
    end
    return false
end

function AudiobookshelfBrowser:gridEnabled()
    -- Defaults to grid: the point of the view is to be the normal way to
    -- browse. "list" in settings opts back out.
    return Settings:read("book_view", "grid") ~= "list" and self:levelHasBooks()
end

-- Menu derives perpage, available_height, item_dimen and page_num from
-- items_per_page, so the grid announces its own page size through that field
-- and lets Menu do the arithmetic. Tile geometry is then read back off the
-- dimensions Menu just computed.
function AudiobookshelfBrowser:_recalculateDimen(no_recalculate_dimen)
    if self:gridEnabled() then
        local width = (self.inner_dimen and self.inner_dimen.w) or self.screen_w
        local height = (self.inner_dimen and self.inner_dimen.h) or self.screen_h
        local cols, rows = CoverGrid.shapeFor(width, height)
        self.grid_cols, self.grid_rows = cols, rows
        self.items_per_page = cols * rows
    else
        self.grid_cols, self.grid_rows = nil, nil
        self.items_per_page = nil
    end
    Menu._recalculateDimen(self, no_recalculate_dimen)
end

-- Grid rendering is opt-outable and, more importantly, fallible: it reaches
-- into Menu internals that differ across KOReader builds. If it raises, fall
-- through to the stock list renderer, which clears and rebuilds the same
-- groups from scratch -- a half-built grid cannot leave the menu wedged.
function AudiobookshelfBrowser:updateItems(select_number, no_recalculate_dimen)
    if self:gridEnabled() then
        local ok, err = pcall(CoverGrid.updateItems, self, select_number, no_recalculate_dimen)
        if ok then
            return
        end
        logger.warn("AudiobookshelfBrowser: cover grid failed, falling back to list:", err)
        self.grid_cols, self.grid_rows = nil, nil
        self.items_per_page = nil
        no_recalculate_dimen = false
    end
    return Menu.updateItems(self, select_number, no_recalculate_dimen)
end

-- Single push site for the D-09 navigation frame contract: stashes level
-- identity onto the outgoing item table (Lua tables mix array/hash parts
-- freely, so this does not affect ipairs() over the rows) and hands it to
-- Menu's own item_table_stack, then switches to the new level's rows.
function AudiobookshelfBrowser:pushLevel(new_level, new_title, new_item_table, new_library_id)
    self.item_table.title = self.current_title
    self.item_table.level = self.level
    self.item_table.library_id = self.library_id
    self.item_table.itemnumber = self.last_selected_index
    self.item_table.page = self.page
    self.item_table.ebook_ids = self.ebook_ids
    self.item_table.library_tab = self.library_tab
    table.insert(self.item_table_stack, self.item_table)
    self.level = new_level
    self.library_id = new_library_id
    self.current_title = new_title
    self:switchItemTable(new_title, new_item_table)
end

function AudiobookshelfBrowser:switchLibraryTab(tab)
    if self.level ~= "library" or not self.library_tabs or not self.library_tabs[tab]
        or tab == self.library_tab then
        return false
    end
    self.item_table.page = self.page
    self.item_table.itemnumber = self.itemnumber
    self.library_tab = tab
    self.item_table = self.library_tabs[tab]
    self.page = self.item_table.page or 1
    self.itemnumber = self.item_table.itemnumber
    self.last_selected_index = nil
    self.search_index = nil
    self.title_bar:setTitle(self.current_title, true)
    -- Recalculate after changing rows: Books and text lists have different
    -- page sizes. Converting indices with the outgoing perpage loses position.
    self:updateItems(1, false)
    return true
end

function AudiobookshelfBrowser:genItemTableFromLibraries()
    local item_table = {}
    local libraries, reason = AudiobookshelfApi:getLibraries()
    if not libraries then
        self:showApiFailure(reason, _("Could not reach Audiobookshelf server. Check network and settings."))
        return item_table, false
    end
    -- A library is excluded only when its id maps to exactly true; nil or
    -- false reads as included (SET-08/adjacency). The survivors keep the
    -- server's array order since this loop below is unchanged and appends
    -- with no re-sort (SET-08/ordering).
    local disabled = Settings:read("disabled_libraries", {})
    for _, library in ipairs(libraries) do
        if disabled[library.id] ~= true then
            table.insert(item_table, {
                text = library.name,
                type = "library",
                id = library.id,
            })
        end
    end
    if #item_table == 0 and #libraries > 0 then
        -- Every library the server returned has been disabled -- distinct
        -- from the server-unreachable message above (SET-08/empty).
        UIManager:show(InfoMessage:new{
            text = _("All libraries are hidden. Re-enable them in Settings -> Libraries."),
            timeout = 2,
        })
    end
    return item_table, true
end

-- D-13: turns an API failure reason into the right message. Defined as its
-- own method, not inlined, so its _() call resolves against the
-- module-level gettext import rather than a throwaway loop placeholder.
-- "unreadable" gets the specific message pointing at Recent errors, because
-- today's generic "Check network and settings." actively misdirects on an
-- unreadable response -- it is not a network problem. Every other reason
-- keeps the caller's existing, context-specific wording.
function AudiobookshelfBrowser:showApiFailure(reason, fallback_text)
    if reason == "unconfigured" then
        -- S1: a fresh install. Nothing about the network caused this, so do
        -- not report it as a network failure -- open Settings. Deferred one
        -- tick because the first call comes from init(), before this browser
        -- is on screen; shown synchronously, Settings would land underneath
        -- the browser that is about to be shown on top of it. Settings first,
        -- then the message, so the message is what the user sees.
        UIManager:nextTick(function()
            UIManager:show(SettingsMenu:new{})
            UIManager:show(InfoMessage:new{
                text = _("Set your server URL and API token to get started."),
                timeout = 3,
            })
        end)
        return
    end
    local text = fallback_text
    if reason == "unreadable" then
        text = _("Audiobookshelf sent a response this plugin could not read. See Recent errors in Settings.")
    elseif reason == "redirect" then
        -- S2: the request was refused rather than followed. The two usual
        -- causes are a wrong URL scheme or path, and a captive-portal Wi-Fi
        -- that answers every request with its sign-in page.
        text = _("The server redirected the request. Check the server URL, or sign in to the Wi-Fi network first.")
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 2,
    })
end

function AudiobookshelfBrowser:onMenuSelect(item)
    self.last_selected_index = item.idx
    if item.type == "library" then
        -- Capture into locals before the closure (REL-05), same as every
        -- other branch below.
        local library_id = item.id
        local library_name = item.text
        local connect_callback = function()
            self:openLibrary(library_id, library_name)
        end
        NetworkMgr:runWhenOnline(connect_callback)
    elseif item.type == "book" then
        -- Capture the id, then construct the widget *inside* the callback
        -- (A-10): the network wake only fires its callback synchronously
        -- when already online, so a widget built outside the callback and
        -- only populated later by a deferred one would already have
        -- returned from its constructor with no tree. Constructing here
        -- covers both network calls init reaches: the item fetch and,
        -- through getDetailsContent, the cover fetch (D-14).
        local book_id = item.id
        local connect_callback = function()
            -- Pass a zero-argument closure so the child calls the parent correctly
            local bookdetailswidget = BookDetailsWidget:new{
                book_id = book_id,
                onCloseParent = function()
                    self:onCloseAllMenus()
                end,
            }
            UIManager:show(bookdetailswidget, "flashui")
        end
        NetworkMgr:runWhenOnline(connect_callback)
    elseif item.type == "series" then
        -- Capture into locals before the closure (REL-05): a deferred
        -- callback then builds the level for the library and series it was
        -- launched from rather than whatever the browser happens to be
        -- showing when Wi-Fi comes up; the level loader's own staleness
        -- guard abandons the load if the user has moved on in the meantime.
        local series_id = item.id
        local series_name = item.text
        local library_id = self.library_id
        local connect_callback = function()
            self:openSeries(series_id, series_name, library_id)
        end
        NetworkMgr:runWhenOnline(connect_callback)
    elseif item.type == "author" then
        -- Same REL-05 capture as the series branch above: locals copied
        -- before the closure so a deferred callback builds the level for
        -- the author and library it was launched from.
        local author_id = item.id
        local author_name = item.text
        local library_id = self.library_id
        local connect_callback = function()
            self:openAuthor(author_id, author_name, library_id)
        end
        NetworkMgr:runWhenOnline(connect_callback)
    end
    return true
end

-- Single pop site for the D-09 frame contract. An empty stack means we are
-- at the root, so Back there delegates to the stock teardown (D-01). The
-- root frame is rebuilt rather than restored verbatim so it re-reads the
-- disabled_libraries blocklist (D-07); every other frame is handed back
-- exactly as captured (D-05), preserving row order with no re-sort.
function AudiobookshelfBrowser:onClose()
    if #self.item_table_stack == 0 then
        return self:onCloseAllMenus()
    end
    local frame = table.remove(self.item_table_stack)
    self.level = frame.level
    self.library_id = frame.library_id
    self.current_title = frame.title
    self.ebook_ids = frame.ebook_ids
    self.library_tab = frame.library_tab

    local restored = frame
    if frame.level == "abs" then
        local rebuilt, reachable = self:genItemTableFromLibraries()
        if reachable then
            restored = rebuilt
        end
    end

    local restore_index = frame.itemnumber
    if restore_index == nil and frame.page ~= nil and self.perpage ~= nil then
        restore_index = (frame.page - 1) * self.perpage + 1
    end
    if restore_index ~= nil then
        if #restored == 0 then
            restore_index = nil
        else
            restore_index = math.min(restore_index, #restored)
        end
    end

    -- switchItemTable only assigns self.itemnumber (the field the D-pad
    -- focus code actually reads) inside a self.path-gated branch that a
    -- bare Menu:extend widget like this one never satisfies -- set it
    -- directly so the highlight restore bypasses that gate.
    self.itemnumber = restore_index
    if frame.level == "library" and frame.page then
        -- The child may be a cover grid while the parent is a text tab.
        -- Restore its page directly; the child's perpage cannot map this index.
        self.page = frame.page
        self:switchItemTable(frame.title, restored, -1)
    else
        self:switchItemTable(frame.title, restored, restore_index)
    end
    return true
end

-- D-04: stock Menu:onMultiSwipe routes to onClose, which under D-01 now
-- means "up one level". Override so a multi-direction swipe always tears
-- the whole browser down instead, restoring the escape-from-depth gesture
-- that one-level-back semantics removed. Touch-only, purely additive: the
-- close button and hardware Back key still step up one level at a time.
function AudiobookshelfBrowser:onMultiSwipe(arg, ges_ev)
    if not self.no_title then
        self:onCloseAllMenus()
    end
    return true
end

function AudiobookshelfBrowser:ShowSearch()
    self.search_dialog = InputDialog:new{
        title = _("Search"),
        input = self.search_value,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    enabled = true,
                    callback = function()
                        self.search_dialog:onClose()
                        UIManager:close(self.search_dialog)
                    end
                },
                {
                    text = _("Search"),
                    enabled = true,
                    callback = function()
                        self.search_value = self.search_dialog:getInputText()
                        self:search()
                    end
                }
            }
        }
    }
    UIManager:show(self.search_dialog)
    self.search_dialog:onShowKeyboard()
end

function AudiobookshelfBrowser:search()
    if self.search_value then
        -- Dialog teardown stays outside and before the wake: the keyboard
        -- and dialog come down immediately on tap, rather than only after
        -- a reconnect (D-14).
        self.search_dialog:onClose()
        UIManager:close(self.search_dialog)
        if string.len(self.search_value) > 0 then
            -- Copy the term into a local before building the closure: a
            -- deferred search (Wi-Fi waking up) then runs the query the
            -- user actually typed, not whatever self.search_value holds
            -- by the time Wi-Fi returns.
            local search_term = self.search_value
            local connect_callback = function()
                self:loadLibrarySearch(search_term)
            end
            NetworkMgr:runWhenOnline(connect_callback)
        end
    end
end

function AudiobookshelfBrowser:loadLibrarySearch(search)
    -- D-16: gate the whole search on the snapshot before spending a
    -- round-trip. Every group below depends on it (D-15), so a search
    -- whose ebook test could not run would otherwise produce a silently
    -- incomplete result. The snapshot helper has already refetched once
    -- and shown its own message on failure, so nothing more is shown here.
    local ebook_ids = self:ensureEbookIds(self.library_id)
    if not ebook_ids then
        return
    end

    -- D-15: the ebook test is membership in this snapshot, so a confirmed-
    -- empty snapshot means no search hit could possibly survive it -- the
    -- round-trip below would buy nothing (GC-01).
    if next(ebook_ids) == nil then
        UIManager:show(InfoMessage:new{
            text = _("This library has no ebooks."),
            timeout = 2,
        })
        return
    end

    local tbl = {}
    -- Named "results" rather than "libraryItems" -- this is a group
    -- container (book/authors/series/...), not an item list. The old name
    -- is what made the previous code conflate "no book group" with
    -- "malformed" (D-13's derived rule below).
    local results, reason = AudiobookshelfApi:getSearchResults(self.library_id, search)
    if not results then
        self:showApiFailure(reason, _("Search failed. Check network and settings."))
        return
    end

    -- Hoisted above every loop below: each loop header binds the
    -- single-underscore identifier as its throwaway key variable, so a
    -- gettext call inside a loop body would invoke that placeholder and
    -- crash (the Phase 1 finding).
    local author_label = _("Author")
    local series_label = _("Series")

    -- D-02: Authors first. D-18: no count and no drop rule for an author
    -- row -- an author with zero ebooks in this library still gets a row,
    -- because the ebook-bearing this-library count is not knowable before
    -- the tap. Never read the entry's own `numBooks` field: verified
    -- against server source, that subquery has no library predicate and no
    -- ebook predicate, so it counts every book by that author across the
    -- entire server, audiobooks included -- not the number D-03 wanted and
    -- it cannot be made into it.
    for _, entry in ipairs(results.authors or {}) do
        table.insert(tbl, {
            id = entry.id,
            text = entry.name,
            mandatory = author_label,
            type = "author"
        })
    end

    -- D-18: no count and no drop rule for a series row -- a series with
    -- zero ebooks in this library still gets a row, because the
    -- ebook-bearing this-library count is not knowable before the tap.
    -- Never read the entry's nested `books` array: that is the array whose
    -- `authors` the server force-empties (advplyr/audiobookshelf#4205), and
    -- not reading it is what satisfies SRCH-08 by construction.
    for _, entry in ipairs(results.series or {}) do
        table.insert(tbl, {
            id = entry.series.id,
            text = entry.series.name,
            mandatory = series_label,
            type = "series"
        })
    end

    -- Books group keeps its existing row shape and author-in-mandatory
    -- convention (D-01). SRCH-07/D-15: a hit is kept only when the
    -- frame-cached snapshot's exact library-item id membership test
    -- passes -- the search endpoint's filter parameter does nothing
    -- server-side (03-01 removed it), so this is the whole implementation
    -- of "has an ebook" for this group, and it is the same definition the
    -- drill-in lists use. No re-sort: relevance order is the server's.
    for _, item in ipairs(results.book or {}) do
        if ebook_ids[item.libraryItem.id] then
            table.insert(tbl, {
                id = item.libraryItem.id,
                text = item.libraryItem.media.metadata.title,
                mandatory = item.libraryItem.media.metadata.authorName,
                type = "book"
            })
        end
    end

    -- D-04: a search pushes the results level if any group has at least
    -- one surviving row -- generalizes cleanly to three groups. An empty
    -- table means every group matched nothing. (This counted 1, not 0,
    -- while a pinned search row always occupied the first slot; moving
    -- search to the title bar removed that row.)
    if #tbl == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("No results for: %1"), search),
            timeout = 2,
        })
        return
    end

    self:pushLevel("search", T(_("Results: %1"), search), tbl, self.library_id)
end

function AudiobookshelfBrowser:openLibrary(id, name)
    local libraryItems, reason = AudiobookshelfApi:getLibraryItems(id)
    if not libraryItems then
        self:showApiFailure(reason, _("Could not load library. Check network and settings."))
        return false
    end
    -- D-15/D-19: the ebook-membership snapshot. getLibraryItems already
    -- fetches exactly the ebook-filtered items this library has -- build the
    -- id set once here and carry it on the frame (Edit 3), rather than
    -- reintroducing a second network call or a name-string index.
    local ebook_ids = {}
    for _, item in ipairs(libraryItems) do
        ebook_ids[item.id] = true
    end
    self.ebook_ids = ebook_ids

    self.library_tabs = LibraryTabs.build(libraryItems)
    self.library_tab = "books"
    self:pushLevel("library", name, self.library_tabs.books, id)
    return true
end

-- D-16: returns the ebook-membership id set, which may legitimately be
-- empty, or nil after telling the user the fetch itself failed. The test
-- below is on existence, not emptiness: a library that genuinely holds
-- zero ebook-bearing items is a real, permanent answer, not an unfetched
-- snapshot, and re-fetching can never change it. This amends D-16 per
-- GC-01, whose original wording did not distinguish the two.
function AudiobookshelfBrowser:ensureEbookIds(library_id)
    if self.ebook_ids ~= nil then
        return self.ebook_ids
    end
    -- Refetch exactly once. No second retry -- D-16 is refetch-once-then-fail.
    local items, reason = AudiobookshelfApi:getLibraryItems(library_id)
    if items then
        local ebook_ids = {}
        for _, item in ipairs(items) do
            ebook_ids[item.id] = true
        end
        self.ebook_ids = ebook_ids
        return self.ebook_ids
    end
    self:showApiFailure(reason, _("Could not load this library's ebook list. Try again."))
    return nil
end

-- D-17: the series drill-in level loader. Order matters -- nothing is
-- pushed until every guard has passed.
function AudiobookshelfBrowser:openSeries(series_id, series_name, library_id)
    -- Staleness guard: NetworkMgr:runWhenOnline may defer its callback, so
    -- this loader can fire after the user has navigated elsewhere.
    -- Abandoning silently is correct -- pushing a level built for a library
    -- the user has left would corrupt the frame stack.
    if library_id ~= self.library_id then
        return false
    end

    local ebook_ids = self:ensureEbookIds(library_id)
    if not ebook_ids then
        -- That snapshot helper has already shown its own message.
        return false
    end

    local items, reason = AudiobookshelfApi:getSeriesItems(library_id, series_id)
    if not items then
        self:showApiFailure(reason, _("Could not load this series. Check network and settings."))
        return false
    end

    -- SRCH-07's whole implementation: exact table-key lookup of the
    -- library-item id against the snapshot, never a name or substring
    -- comparison (D-15, D-19).
    local rows = {}
    for _, item in ipairs(items) do
        if ebook_ids[item.id] then
            -- D-12: read the sequence from the series sub-table the scoped
            -- call attached for the series being drilled into, ignoring the
            -- book's other series memberships entirely. The server attaches
            -- this sub-table with id/name/sequence precisely when the
            -- filter group is `series`.
            local series_info = item.media and item.media.metadata and item.media.metadata.series
            local sequence = series_info and series_info.sequence
            local mandatory
            if sequence and sequence ~= "" then
                -- D-11: the server's string verbatim, never re-rendered
                -- from the parsed number, never padded or rounded.
                mandatory = "#" .. sequence
            else
                mandatory = NO_SEQUENCE_LABEL
            end
            table.insert(rows, {
                id = item.id,
                text = item.media.metadata.title,
                mandatory = mandatory,
                sequence = sequence,
                type = "book"
            })
        end
    end

    -- D-09: decimal-safe by construction. Lua's sort is not guaranteed
    -- stable, but the comparator is total and deterministic (ties break on
    -- title), which is what makes the sort order reproducible anyway.
    table.sort(rows, compareSeriesRows)

    local tbl = {}
    for _, row in ipairs(rows) do
        table.insert(tbl, row)
    end

    self:pushLevel("series", T(_("Series: %1"), series_name), tbl, library_id)

    -- D-18: shown after the push, so it lands on top of the level it
    -- explains. An audiobook-only series still renders as a selectable
    -- result and drills into an explained empty list -- worded differently
    -- from the no-search-results message, because the two mean different
    -- things.
    if #rows == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No ebooks in this series in this library."),
            timeout = 2,
        })
    end

    return true
end

-- D-17: the author drill-in level loader, the series path against a
-- different endpoint. Order matters -- nothing is pushed until every
-- guard has passed.
function AudiobookshelfBrowser:openAuthor(author_id, author_name, library_id)
    -- Staleness guard: NetworkMgr:runWhenOnline may defer its callback, so
    -- this loader can fire after the user has navigated elsewhere.
    -- Abandoning silently is correct -- pushing a level built for a
    -- library the user has left would corrupt the frame stack.
    if library_id ~= self.library_id then
        return false
    end

    local ebook_ids = self:ensureEbookIds(library_id)
    if not ebook_ids then
        -- That snapshot helper has already shown its own message.
        return false
    end

    local items, reason = AudiobookshelfApi:getAuthorItems(author_id)
    if not items then
        self:showApiFailure(reason, _("Could not load this author. Check network and settings."))
        return false
    end

    -- SRCH-07's whole implementation again: exact table-key lookup of the
    -- library-item id against the snapshot (D-15, D-19). The author
    -- endpoint's own item list is not ebook-filtered (verified), so this
    -- pass is what makes the level honest. Keeping the author name in the
    -- right-hand column is deliberate -- on a co-authored title it is the
    -- useful fact -- and reuses openLibrary's row shape verbatim, one row
    -- shape backing three levels. No `sequence` key on these rows: D-10's
    -- position-instead-of-author swap applies to series lists only.
    local rows = {}
    for _, item in ipairs(items) do
        if ebook_ids[item.id] then
            table.insert(rows, {
                id = item.id,
                text = item.media.metadata.title,
                mandatory = item.media.metadata.authorName,
                type = "book"
            })
        end
    end

    -- Title order, not sequence order -- D-09 governs series lists only.
    -- Title order is what the library-items call already asks the server
    -- for, so this level matches the library level a user just came from.
    table.sort(rows, compareByTitle)

    local tbl = {}
    for _, row in ipairs(rows) do
        table.insert(tbl, row)
    end

    self:pushLevel("author", T(_("Author: %1"), author_name), tbl, library_id)

    -- D-18: shown after the push, so it lands on top of the level it
    -- explains. Wording deliberately distinct from both the no-results
    -- message and the series equivalent -- the three mean different
    -- things: nothing matched the query, this author has no ebooks here,
    -- this series has no ebooks here.
    if #rows == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No ebooks by this author in this library."),
            timeout = 2,
        })
    end

    return true
end

return AudiobookshelfBrowser

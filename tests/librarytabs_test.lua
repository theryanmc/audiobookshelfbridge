-- Run from the repository root: luajit tests/librarytabs_test.lua
local LibraryTabs = require("audiobookshelfbridge/librarytabs")
local function book(id, authors, series)
    return { id = id, media = { metadata = {
        title = id, authorName = "Author", authors = authors, series = series,
    } } }
end
local items = {
    book("one", {{id="a", name="Alpha"}, {id="b", name="Beta"}, {id="a", name="Alpha"}},
        {{id="s", name="Series", sequence="1"}, {id="t", name="Other", sequence="2"}}),
    book("two", {{id="a", name="Alpha"}, {id="c", name="Alpha"}}, {{id="s", name="Series", sequence="1.5"}}),
    book("three", {{id=false, name="Invalid"}, {id="", name="Invalid"}, "bad"}, nil),
    book("four", nil, "bad"),
}
local tabs = LibraryTabs.build(items)
assert(#tabs.books == 4 and #tabs.authors == 3 and #tabs.series == 2)
assert(tabs.books[1].id == "one" and tabs.books[4].id == "four")
assert(tabs.authors[1].id == "a" and tabs.authors[1].count == 2)
assert(tabs.authors[2].id == "c" and tabs.authors[2].count == 1) -- same name, distinct ID
assert(tabs.authors[3].id == "b" and tabs.authors[3].type == "author")
assert(tabs.series[1].id == "t" and tabs.series[2].mandatory == "2")
local empty = LibraryTabs.build({})
assert(#empty.books == 0 and #empty.authors == 0 and #empty.series == 0)

-- Host widget stubs: exercise the real browser/navigation and header methods
-- without requiring KOReader's framebuffer, font engine, or network.
local Widget = {}
function Widget:extend(fields) return setmetatable(fields or {}, {__index=self}) end
function Widget:new(fields)
    local obj = self:extend(fields)
    if obj.init then obj:init() end
    return obj
end
function Widget:resetLayout() end
function Widget:free() end
function Widget:getSize() return {w=self.width or 600, h=60} end
function Widget:setText(text, width) self.text, self.width = text, width end
function Widget:setSubTitle(text) self.subtitle = text end
function Widget:enableDisable(enabled) self.enabled = enabled end
function Widget:showHide(show) self.hidden = not show end
local Screen = { scaleBySize=function(_, size) return size end, getWidth=function() return 600 end }
package.loaded.device = { screen=Screen }
package.loaded.gettext = function(text) return text end
for _, name in ipairs({ "button", "horizontalgroup", "verticalgroup", "iconbutton", "titlebar" }) do
    package.loaded["ui/widget/" .. name] = Widget
end
local TitleBar = require("audiobookshelfbridge/titlebar")
local Api = {}
function Api:getLibraryItems() return items end
local metadata_calls = 0
function Api:getLibraryItemsMetadata(source)
    metadata_calls = metadata_calls + 1
    local result = {}
    for _, item in ipairs(source) do
        local metadata = item.media.metadata
        result[#result + 1] = book(item.id,
            type(metadata.authors) == "table" and metadata.authors or {},
            type(metadata.series) == "table" and metadata.series or {})
    end
    return result
end
package.loaded["audiobookshelfbridge/api"] = Api
for _, name in ipairs({ "bookdetailswidget", "covergrid", "settings", "settingsmenu" }) do
    package.loaded["audiobookshelfbridge/" .. name] = {}
end
for _, name in ipairs({ "infomessage", "inputdialog" }) do
    package.loaded["ui/widget/" .. name] = Widget
end
package.loaded.logger = {}
package.loaded["ui/network/manager"] = {runWhenOnline=function(_, callback) callback() end}
package.loaded["ui/uimanager"] = {}
package.loaded["ffi/util"] = { template=function(text) return text end }
local Menu = Widget:extend{}
function Menu:switchItemTable(title, rows, index)
    self.item_table = rows
    self.title_bar:setTitle(title, true)
    if index == nil then self.page = 1
    elseif index >= 0 then self.page = math.max(1, math.ceil(index / self.perpage)) end
    self:updateItems(1, false)
end
package.loaded["ui/widget/menu"] = Menu
local Browser = require("audiobookshelfbridge/browser")
local browser = Browser:extend{
    level="abs", current_title="Libraries", item_table={}, item_table_stack={}, page=1, perpage=10,
}
browser.title_bar = TitleBar:new{width=600, browser=browser}
assert(browser.title_bar[2] == nil)
assert(browser.title_bar.search_button.hidden)
assert(#browser.title_bar:generateVerticalLayout()[1] == 2)
local updates = 0
function browser:updateItems()
    updates = updates + 1
    self.perpage = self:levelHasBooks() and 6 or 10
    self.page = math.max(1, math.min(self.page, math.ceil(#self.item_table / self.perpage)))
end
function browser:onCloseAllMenus() self.closed = true; return true end
assert(browser:openLibrary("library-a", "Library A"))
assert(browser.library_tab == "books" and browser.library_id == "library-a")
assert(browser.title_bar[2] == browser.title_bar.tabs)
assert(not browser.title_bar.search_button.hidden)
assert(#browser.title_bar:generateVerticalLayout() == 2)
assert(browser.title_bar.tab_buttons.books.width == 200)
assert(browser.title_bar.tab_buttons.books.text == "● Books")
-- Initial list metadata may be condensed; load grouping data only on demand.
assert(metadata_calls == 0)
browser:switchLibraryTab("series")
assert(metadata_calls == 1 and #browser.library_tabs.series == 2)
browser:switchLibraryTab("authors")
assert(metadata_calls == 1 and #browser.item_table == 3)
browser:switchLibraryTab("books")
-- Give both renderers multiple pages with different page sizes.
for i=5,36 do browser.library_tabs.books[i] = {id=tostring(i), text=tostring(i), type="book"} end
for i=3,24 do browser.library_tabs.series[i] = {id=tostring(i), text=tostring(i), type="series"} end
browser.page, browser.itemnumber = 3, 13
assert(browser:switchLibraryTab("series"))
assert(browser.page == 1 and #browser.item_table_stack == 1)
browser.page, browser.itemnumber, browser.last_selected_index = 2, 12, 12
assert(browser:switchLibraryTab("books"))
assert(browser.page == 3 and browser.itemnumber == 13)
assert(browser:switchLibraryTab("series"))
assert(browser.page == 2 and browser.itemnumber == 12)
browser.last_selected_index = 12
browser:pushLevel("series", "Series detail", browser.library_tabs.books, "library-a")
assert(browser.title_bar[2] == nil and #browser.title_bar:generateVerticalLayout() == 1)
assert(not browser:switchLibraryTab("authors"))
assert(browser:onClose())
assert(browser.level == "library" and browser.library_tab == "series")
assert(browser.page == 2 and browser.itemnumber == 12 and browser.title_bar[2])
browser:pushLevel("search", "Results", {}, "library-a")
browser:onClose()
assert(browser.library_tab == "series" and browser.page == 2)
browser.title_bar.tab_buttons.authors.callback()
assert(browser.library_tab == "authors" and browser.page == 1)
local before = updates
assert(not browser:switchLibraryTab("authors") and not browser:switchLibraryTab("invalid"))
assert(updates == before)
-- Failed load must not replace the current library's tabs or selection.
function Api:getLibraryItems() return nil, "connection" end
function browser:showApiFailure() self.failed = true end
local saved = browser.library_tabs
assert(not browser:openLibrary("library-b", "B"))
assert(browser.library_tabs == saved and browser.library_id == "library-a" and browser.failed)
function Api:getLibraryItems() return {} end
assert(browser:openLibrary("library-b", "B"))
assert(browser.library_tabs ~= saved and browser.library_tab == "books" and #browser.item_table == 0)
-- The single-library entry path removes the picker frame; tab changes add none.
browser.item_table_stack = {}
browser:switchLibraryTab("authors")
assert(#browser.item_table_stack == 0)
browser:onClose()
assert(browser.closed)
-- Reproduce the real list response: only display names, no ID arrays.
local minified = {{id="minimal", media={metadata={title="Minimal", authorName="Alpha", seriesName="Series #1"}}}}
assert(not LibraryTabs.hasGroupMetadata(minified))
assert(LibraryTabs.hasGroupMetadata({}))
browser.closed = nil
function Api:getLibraryItems() return minified end
function Api:getLibraryItemsMetadata() return nil, "connection" end
browser:openLibrary("library-c", "C")
browser:switchLibraryTab("series")
assert(browser.library_tab == "books" and not browser.library_groups_loaded)
function Api:getLibraryItemsMetadata()
    return {book("minimal", {{id="a",name="Alpha"}}, {{id="s",name="Series"}})}
end
browser:switchLibraryTab("authors")
assert(browser.library_groups_loaded and #browser.item_table == 1 and browser.item_table[1].id == "a")
browser:switchLibraryTab("series")
assert(#browser.item_table == 1 and browser.item_table[1].id == "s")
-- A Wi-Fi callback queued for an old library must not change the current view.
browser:openLibrary("library-c", "C")
local deferred
package.loaded["ui/network/manager"].runWhenOnline = function(_, cb) deferred = cb end
browser:switchLibraryTab("authors")
function Api:getLibraryItems() return {} end
browser:openLibrary("library-d", "D")
deferred()
assert(browser.library_id == "library-d" and browser.library_tab == "books")
print("PASS: grouping, tab state, header controls, back navigation, library isolation, and root exit")

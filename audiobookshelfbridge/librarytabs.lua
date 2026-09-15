-- Build indexes from the same ebook snapshot as Books, without extra requests.
local LibraryTabs = {}

function LibraryTabs.build(items)
    local tabs = { books = {}, series = {}, authors = {} }
    local indexes = { series = {}, authors = {} }
    for _, item in ipairs(items) do
        local metadata = item.media and item.media.metadata or {}
        tabs.books[#tabs.books + 1] = {
            id = item.id, text = metadata.title, mandatory = metadata.authorName, type = "book",
        }
        for _, kind in ipairs({ "series", "authors" }) do
            local groups = metadata[kind]
            local seen = {}
            if type(groups) == "table" then
                for _, group in ipairs(groups) do
                    if type(group) == "table" and type(group.id) == "string" and group.id ~= ""
                        and type(group.name) == "string" and group.name ~= "" and not seen[group.id] then
                        seen[group.id] = true
                        local row = indexes[kind][group.id]
                        if not row then
                            row = {
                                id = group.id, text = group.name,
                                type = kind == "authors" and "author" or "series", count = 0,
                            }
                            indexes[kind][group.id] = row
                            tabs[kind][#tabs[kind] + 1] = row
                        end
                        row.count = row.count + 1
                        row.mandatory = tostring(row.count)
                    end
                end
            end
        end
    end
    for _, kind in ipairs({ "series", "authors" }) do
        table.sort(tabs[kind], function(a, b)
            local left, right = a.text:lower(), b.text:lower()
            if left ~= right then return left < right end
            if a.text ~= b.text then return a.text < b.text end
            return a.id < b.id
        end)
    end
    return tabs
end

return LibraryTabs

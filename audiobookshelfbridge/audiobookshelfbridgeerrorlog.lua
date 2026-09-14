-- In-memory, session-only ring buffer of recent plugin errors (SET-12).
--
-- Deliberately narrow: no disk persistence, no timestamps beyond what the
-- caller composes, no Settings require. This buffer is rendered on screen
-- (Recent errors row), so callers must never record a token, a raw request/
-- response/fields table, or a raw response body (decision D-J).

local ErrorLog = {
    entries = {},
    max_entries = 20,
}

function ErrorLog:record(message)
    table.insert(self.entries, tostring(message))
    if #self.entries > self.max_entries then
        table.remove(self.entries, 1)
    end
end

function ErrorLog:getRecent()
    return self.entries
end

return ErrorLog

-- Run: luajit tests/api_metadata_test.lua
local body_ids, response, calls = nil, nil, 0
local mode = "ok"
package.loaded["ffi/util"] = {template=function(text) return text end}
package.loaded.json = {encode=function(body) body_ids=body.libraryItemIds; return "encoded body" end}
package.loaded.ltn12 = {
    sink={table=function(sink) return function(data) sink[#sink+1]=data end end},
    source={string=function(body) return function() return body end end},
}
package.loaded["socket.http"] = {request=function(request)
    calls = calls + 1
    assert(request.method == "POST" and request.url == "https://example.invalid/api/items/batch/get")
    assert(request.redirect == false and request.headers.Authorization == "Bearer test-token")
    assert(request.headers["Content-Type"] == "application/json")
    assert(tonumber(request.headers["Content-Length"]) == #request.source())
    assert(#body_ids <= 100)
    if mode == "connection" then error("transport failed") end
    if mode == "redirect" then return 1, 302 end
    if mode == "server" then return 1, 500 end
    response = {}
    -- Deliberately return in reverse order to catch ordering assumptions.
    for i=#body_ids,1,-1 do
        response[#response+1] = {id=body_ids[i], media={metadata={authors={},series={}}}}
    end
    if mode == "missing" then table.remove(response) end
    if mode == "malformed" then response[1].media.metadata.authors = nil end
    if mode == "foreign" then response[1].id = "outside-snapshot" end
    if mode == "duplicate" then response[2] = response[1] end
    request.sink("response")
    return 1, 200
end}
package.loaded.socket = {skip=function(_, ...) return select(2, ...) end}
local resets = 0
package.loaded.socketutil = {set_timeout=function() end, reset_timeout=function() resets=resets+1 end}
package.loaded.logger = {warn=function() end}
for _, name in ipairs({"ffi/sha2", "ui/renderimage", "util", "audiobookshelfbridge/downloadstaging"}) do
    package.loaded[name] = {}
end
package.loaded["audiobookshelfbridge/settings"] = {read=function(_, key)
    return key == "server" and "https://example.invalid" or "test-token"
end}
package.loaded.gettext = function(text) return text end
local Api = require("audiobookshelfbridge/api")
function Api:decodeResponse(_, _, key) assert(key == "libraryItems"); return response end
local items = {}
for i=1,205 do items[i]={id=tostring(i)} end
local expanded = assert(Api:getLibraryItemsMetadata(items))
assert(#expanded == 205 and calls == 3 and resets == calls)
for i=1,205 do assert(expanded[i].id == items[i].id) end
for _, failure in ipairs({"missing", "malformed", "foreign", "duplicate", "connection", "redirect", "server"}) do
    mode = failure
    local result, reason = Api:getLibraryItemsMetadata(items)
    assert(result == nil and reason ~= nil, failure)
    assert(resets == calls, failure)
end
local before = calls
assert(#Api:getLibraryItemsMetadata({}) == 0 and calls == before)
print("PASS: metadata batching, ordering, request safety, and failure handling")

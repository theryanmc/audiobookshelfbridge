local LuaSettings = require("luasettings")

local config_file = string.gsub(debug.getinfo(1).source, "^@(.+/)[^/]+$", "%1") .. "/../audiobookshelfbridge_config.lua"

local Settings = {
    handle = LuaSettings:open(config_file)
}

function Settings:read(key, default)
    return self.handle:readSetting(key, default)
end

function Settings:write(key, value)
    self.handle:saveSetting(key, value)
    self.handle:flush()
end

return Settings

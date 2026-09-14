-- plugins/audiobookshelfbridge.koplugin/audiobookshelfbridge_config.lua
--
-- The plugin also manages two additional keys in this same file, written
-- automatically at runtime: `download_dir` (the last folder chosen for
-- downloads) and `disabled_libraries` (per-library visibility choices).
-- Neither key needs to be present here for the plugin to work, and a
-- config file written by an older version of the plugin keeps working
-- unchanged with no edits required.
return {
    ["token"] = 'your api key here',
    ["server"] = 'your audiobookshelf instance url here'
}

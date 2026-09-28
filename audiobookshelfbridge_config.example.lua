-- plugins/audiobookshelfbridge.koplugin/audiobookshelfbridge_config.lua
--
-- Signing in from Settings ("Sign in with username and password") is the
-- alternative to putting a token here. When you sign in, the plugin writes
-- five more keys into this same file: `auth`, `access_token`,
-- `refresh_token`, `session_host`, and `username`. None of them need to be
-- present up front, and a file holding only `server` and `token` keeps
-- working exactly as before.
--
-- The plugin also manages two further keys, written automatically at
-- runtime: `download_dir` (the last folder chosen for downloads) and
-- `disabled_libraries` (per-library visibility choices). Neither key needs
-- to be present here for the plugin to work, and a config file written by
-- an older version of the plugin keeps working unchanged with no edits
-- required.
return {
    ["token"] = 'your api key here',
    ["server"] = 'your audiobookshelf instance url here'
}

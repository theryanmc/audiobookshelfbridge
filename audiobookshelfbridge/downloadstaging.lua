-- Dependency-free staging primitives for AudiobookshelfApi:downloadFile (prohibition
-- A-07, gap closure for 04-metadata-write-back). Zero `require` statements, on
-- purpose: this project has no test suite by deliberate constraint, and
-- 04-UAT.md tests 5 and 6 are blocked on test-rig speed (this maintainer's LAN
-- finishes any EPUB transfer in well under a second, so there is no
-- interruptible window). Keeping this module loadable under a bare LuaJIT with
-- no KOReader present is what makes the A-07 property testable at all: a
-- harness can create a pre-existing file, simulate a failed transfer against
-- it, and assert byte survival directly, without a device, a server, or a
-- slow network.
--
-- Uses io.open plus a seek for file sizes rather than KOReader's bundled
-- LuaFileSystem attributes call, again solely to keep this module loadable
-- outside KOReader.

local DownloadStaging = {}

-- Plugin-owned literal components of the staging filename (GC-05). The
-- leading dot keeps a crash orphan out of KOReader's file browser, which
-- hides dotfiles by default (GC-06) -- so a hard kill between opening the
-- staging file and the rename leaves one hidden file behind, not a visible
-- partial book.
local TEMP_DOWNLOAD_PREFIX = ".audiobookshelfbridge-download"
local TEMP_DOWNLOAD_SUFFIX = ".part"

-- Allowlist guard for server-supplied path components, following
-- metadatawriter.lua's TEMP_COVER_PREFIX precedent (server-supplied text
-- never reaches a filesystem path unvalidated). Diverges from that precedent
-- in one way: the allowlist admits `_`, because Audiobookshelf item ids are
-- UUID-shaped on current servers but `li_`-prefixed on older ones, and an
-- underscore-rejecting allowlist would reject those (GC-05).
local function safeComponent(value)
    if type(value) ~= "string" and type(value) ~= "number" then
        return nil
    end
    local s = tostring(value)
    if s:match("^[%w_%-]+$") then
        return s
    end
    return nil
end

-- Returns the staging path for a download bound for `local_path`, or nil
-- when `local_path` itself is unusable. When both `id` and `ino` pass the
-- allowlist, the name embeds them so a retry of the same download reclaims
-- its own orphan (the name is deterministic, not randomised, on purpose --
-- orphans self-heal on retry instead of accumulating per attempt). When
-- either fails the allowlist, the name degrades to the fixed fallback
-- (prefix plus suffix) instead of refusing the download outright (GC-05):
-- unlike metadatawriter's cover write, a refusal here would cost the
-- download itself, and no id format is allowed to make a book
-- undownloadable.
function DownloadStaging.tempPathFor(local_path, id, ino)
    if type(local_path) ~= "string" or local_path == "" then
        return nil
    end
    local safe_id = safeComponent(id)
    local safe_ino = safeComponent(ino)
    if safe_id and safe_ino then
        return local_path .. "/" .. TEMP_DOWNLOAD_PREFIX .. "-" .. safe_id .. "-" .. safe_ino .. TEMP_DOWNLOAD_SUFFIX
    end
    return local_path .. "/" .. TEMP_DOWNLOAD_PREFIX .. TEMP_DOWNLOAD_SUFFIX
end

-- Returns the byte size of the file at `path`, or nil when `path` is
-- unusable or cannot be opened for reading. Exists instead of KOReader's
-- bundled LuaFileSystem attributes call solely to keep this module loadable
-- outside KOReader.
function DownloadStaging.fileSize(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local size = f:seek("end")
    f:close()
    return size
end

-- Pure completeness decision (CR-01 gap closure, GC-10/GC-12/GC-13).
-- Neither argument is read from disk here -- `actual_size` is whatever the
-- caller already measured with DownloadStaging.fileSize, and
-- `declared_length` is whatever the caller already parsed out of a
-- response header. This function performs no I/O, opens nothing, and never
-- looks at the staging file itself.
--
-- First and unconditionally: reject an unusable size. fileSize returns nil
-- for a staging file it could not read at all, and returns 0 for one that
-- exists but is empty -- and 0 is truthy in Lua, since only nil and false
-- are falsy, so a bare existence test on this value would silently accept
-- an empty transfer. That silent acceptance was CR-01: it let an empty 200
-- with no declared content-length reach DownloadStaging.commit and replace
-- a user's existing book with a 0-byte file, reopening prohibition A-07.
-- An HTTP body that is empty is never a valid ebook, so judging it needs
-- no reference to what the server declared -- this clause is deliberately
-- not conditioned on the header, so no absent header can short-circuit
-- past it.
--
-- Then, only if a length was declared as a number: reject on inequality.
-- When no length was declared, or it did not parse as a number, this
-- comparison is skipped rather than turned into an invented failure
-- (GC-13/A-16) -- an absent header must never make a book undownloadable.
--
-- Returns a real boolean in every case, never a truthy non-boolean and
-- never the result of an and/or chain that could yield nil -- the
-- distinction between a falsy value and `false` is exactly what CR-01
-- turned on.
function DownloadStaging.isCompleteTransfer(actual_size, declared_length)
    if type(actual_size) ~= "number" or actual_size <= 0 then
        return false
    end
    if type(declared_length) == "number" and actual_size ~= declared_length then
        return false
    end
    return true
end

-- Removes exactly the staging path handed to it, and nothing else. This
-- function takes one argument by design: there is no parameter through
-- which a destination path could ever be handed to it, which is the
-- structural reason A-07 cannot regress through this function.
function DownloadStaging.discard(temp_path)
    if type(temp_path) ~= "string" or temp_path == "" then
        return false
    end
    os.remove(temp_path)
    return true
end

-- Commits a completed staging file onto the destination by rename. Returns
-- true on success, or false plus a reason string.
--
-- POSIX `rename()` replaces an existing target atomically. ANSI C
-- `rename()`, as shipped by the Windows CRT, fails when the target already
-- exists. Without a fallback this would introduce a new regression on such
-- a platform -- overwrite would stop working entirely, where today's
-- truncating open always works. So: try the plain rename first; if it
-- fails, re-confirm the staging file is still readable (this guard is the
-- whole safety argument of GC-08 and must come before anything
-- destructive), then remove the destination and rename once more. If the
-- second rename also fails, the staging file is left in place -- it may by
-- then be the only complete copy -- and the failure is reported with its
-- path so the caller can log it.
function DownloadStaging.commit(temp_path, fullpath)
    if type(temp_path) ~= "string" or temp_path == "" or type(fullpath) ~= "string" or fullpath == "" then
        return false, "bad_args"
    end
    local renamed = os.rename(temp_path, fullpath)
    if renamed then
        return true
    end
    -- The plain rename failed (e.g. Windows CRT semantics where the target
    -- exists). Re-confirm the staging file is still readable BEFORE doing
    -- anything destructive -- this is what makes it impossible for the one
    -- destructive step below to run without a replacement already in hand.
    if not DownloadStaging.fileSize(temp_path) then
        return false, "staged_file_missing"
    end
    os.remove(fullpath)
    local renamed2 = os.rename(temp_path, fullpath)
    if renamed2 then
        return true
    end
    -- Deliberately not discarded: temp_path may be the only complete copy
    -- left, so it stays on disk rather than being deleted here.
    return false, "rename_failed"
end

return DownloadStaging

--[[--
Where KOReader lands after a book, and at startup.

Pure: no KOReader modules, so the specs can load it. main.lua asks `plan`
when a FileManager is created and shows the Library in that same call,
before anything paints the file browser (see Library:registerReturnHooks).

`after_close`: "library" (default) comes back to the Library; "filemanager"
leaves KOReader's file browser up and does not open the Library.

`on_startup`: "library" opens the Library when Start with is library;
"last" resumes KOReader's last file and must not paint the Library over that
reader. A Start with of "last" wins even if a stale "library" choice is saved.
--]]

local M = {}

M.LIBRARY = "library"
M.FILEMANAGER = "filemanager"
M.LAST = "last"

--- "library" or "filemanager". A saved choice wins. The old checkbox
-- `return_to_library = false` is the file browser; anything else is the Library.
function M.afterClose(stored, legacy_return_to_library)
    if stored == M.LIBRARY or stored == M.FILEMANAGER then return stored end
    if legacy_return_to_library == false then return M.FILEMANAGER end
    return M.LIBRARY
end

--- True when startup must not cover KOReader's last-file reader with the Library.
-- An explicit "last" choice, or KOReader's own Start with set to last.
function M.resumesLastBook(on_startup, start_with)
    if on_startup == M.LAST then return true end
    if start_with == "last" then return true end
    return false
end

--- Which startup row is selected. Nil when the user has not chosen and
-- KOReader is not starting on the Library or the last file.
function M.startupChoice(on_startup, start_with)
    if M.resumesLastBook(on_startup, start_with) then return M.LAST end
    if on_startup == M.LIBRARY or start_with == "library" then return M.LIBRARY end
    return nil
end

--- What to open over a FileManager that is about to be shown.
-- Returns "show", "search", or nil (leave the file browser as it is).
-- s: {
--   has_document = reader is up (KOReader started in a book),
--   after_book   = "show" | "search" | nil (Library was asked for from a book),
--   reopen       = this book was opened from the Library,
--   closed_book  = a document just closed,
--   home         = Start with is the Library,
--   first        = this KOReader run has not shown the Library yet,
--   after_close, legacy_return, on_startup, start_with,
-- }
function M.plan(s)
    s = s or {}
    if s.has_document then return nil end
    if s.after_book == "search" or s.after_book == "show" then
        return s.after_book
    end
    local from_book = s.reopen or s.closed_book
    if from_book then
        if M.afterClose(s.after_close, s.legacy_return) ~= M.LIBRARY then
            return nil
        end
        -- Opened from the Library, or the Library is the home screen.
        if s.reopen or s.home then return "show" end
        return nil
    end
    if s.first and s.home and not M.resumesLastBook(s.on_startup, s.start_with) then
        return "show"
    end
    return nil
end

return M

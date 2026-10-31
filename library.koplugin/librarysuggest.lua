--[[--
Word suggestions for the Library's search box.

While typing, a short row of words from the library itself (titles, authors
and series of the books being searched, or the names on the Authors, Series
and Collections tabs) completes the word under the cursor. Words that start
with what was typed come first, the most common first; when there are too few,
"Typo-tolerant search" adds near misses (Core.prefixDistance, the same
distance the search itself forgives). Tapping one replaces the half-typed word.

Pure Lua: no KOReader modules, so it is tested on its own.
--]]

local Core = require("librarycore")

local M = {}

M.MIN_PREFIX = 2 -- letters typed before anything is suggested
M.MAX = 5        -- suggestions shown
M.MIN_WORD = 3   -- shorter words are never suggested

-- Joining words a suggestion would never help with.
local SKIP = { the = true, ["and"] = true, ["for"] = true, with = true, from = true, ["des"] = true,
    ["del"] = true, ["der"] = true, ["die"] = true, ["das"] = true, ["les"] = true, ["los"] = true, ["las"] = true }

-- The words of `text` as written (lower case, accents kept), each with its
-- accent-free form, which is what typing is matched against.
local function addWords(text, lower, vocab, seen)
    if type(text) ~= "string" or text == "" then return end
    local s = (lower or string.lower)(text)
    -- (’ splits too: l’Étranger suggests "étranger")
    s = s:gsub("\226\128[\147\148\152\153\156\157\166]", " "):gsub("\194[\160-\191]", " ")
    s = s:gsub("[%c!-&(-/:-@%[-`{-~]", " ") -- ASCII punctuation but the apostrophe
    for w in s:gmatch("%S+") do
        w = w:gsub("^'+", ""):gsub("'+$", "")
        local key = Core.normalizeText(w, lower)
        if #key >= M.MIN_WORD and not key:find("%s") and not SKIP[key] and not key:find("^%d+$") and not seen[key] then
            seen[key] = true
            vocab.count[key] = (vocab.count[key] or 0) + 1
            vocab.display[key] = vocab.display[key] or w
        end
    end
end

--- The words to suggest from: { words = sorted accent-free forms,
-- count = { word = items using it }, display = { word = as written } }.
-- `items` are books (title, authors, series), or with `shelves` the
-- Authors, Series or Collections tab's shelves (name, and a series' authors).
function M.vocabulary(items, lower, shelves)
    local vocab = { count = {}, display = {} }
    for _, it in ipairs(items or {}) do
        local seen = {}
        if shelves then
            addWords(it.name, lower, vocab, seen)
        else
            addWords(it.title, lower, vocab, seen)
            addWords(it.series, lower, vocab, seen)
        end
        for _, a in ipairs(type(it.authors) == "table" and it.authors or {}) do addWords(a, lower, vocab, seen) end
    end
    local words, n = {}, 0
    for w in pairs(vocab.count) do n = n + 1; words[n] = w end
    table.sort(words)
    vocab.words = words
    return vocab
end

--- The half-typed last word of `query` (normalised), and the words before it.
-- Nil when the query ends in a space: that word is finished.
function M.lastWord(query, lower)
    if type(query) ~= "string" or query == "" or query:find("%s$") then return nil end
    local words = {}
    for w in Core.normalizeText(query, lower):gmatch("%S+") do words[#words + 1] = w end
    local last = table.remove(words)
    if not last or #last < M.MIN_PREFIX then return nil end
    return last, words
end

-- first index in the sorted `words` whose word is >= `s`
local function lowerBound(words, s)
    local lo, hi = 1, #words + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if words[mid] < s then lo = mid + 1 else hi = mid end
    end
    return lo
end

--- Up to `max` words (as written in the library) completing the query's
-- last word. `opts.fuzzy`: also near misses (typos) when there are not
-- enough that start with it.
function M.suggest(vocab, query, opts)
    opts = opts or {}
    local max = opts.max or M.MAX
    local last, before = M.lastWord(query, opts.lower)
    if not (vocab and last) then return {} end
    local used = {}
    for _, w in ipairs(before) do used[w] = true end
    used[last] = true
    local words, count = vocab.words, vocab.count
    local exact = {}
    local i = lowerBound(words, last)
    while words[i] and words[i]:sub(1, #last) == last do
        if not used[words[i]] then exact[#exact + 1] = words[i] end
        i = i + 1
    end
    table.sort(exact, function(a, b)
        if count[a] ~= count[b] then return count[a] > count[b] end
        if #a ~= #b then return #a < #b end
        return a < b
    end)
    local out = {}
    for k = 1, math.min(max, #exact) do out[k] = exact[k] end
    local cap = opts.fuzzy and #out < max and Core.typoBudget(#last) or 0
    if cap == 0 then
        for k, w in ipairs(out) do out[k] = vocab.display[w] or w end
        return out
    end
    local near, dist = {}, {}
    for _, w in ipairs(words) do
        if not used[w] and w:sub(1, #last) ~= last and #w >= #last - cap then
            local d = Core.prefixDistance(last, w, cap)
            if d and d <= cap then near[#near + 1] = w; dist[w] = d end
        end
    end
    table.sort(near, function(a, b)
        if dist[a] ~= dist[b] then return dist[a] < dist[b] end
        if count[a] ~= count[b] then return count[a] > count[b] end
        return a < b
    end)
    for k = 1, #near do
        if #out >= max then break end
        out[#out + 1] = near[k]
    end
    for k, w in ipairs(out) do out[k] = vocab.display[w] or w end
    return out
end

--- The query with its half-typed last word replaced by `word`, and a space
-- after it, ready for the next word.
function M.apply(query, word)
    query = type(query) == "string" and query or ""
    local head = query:match("^(.-)%S*$") or ""
    return head .. word .. " "
end

return M

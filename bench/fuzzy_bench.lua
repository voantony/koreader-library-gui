-- Typo-tolerant search on a synthetic 5,000-book library.
-- Run from the repository root: luajit bench/fuzzy_bench.lua [books] [distinct words]
package.path = "./library.koplugin/?.lua;" .. package.path
local Core = require("librarycore")

local N = tonumber(arg and arg[1]) or 5000
local V = tonumber(arg and arg[2]) or 4000 -- distinct title words
math.randomseed(42)
local syll = { "ka", "lo", "mer", "an", "tis", "ro", "vel", "dun", "sha", "pri", "ell", "or", "beth", "gar", "wyn",
    "ste", "ia", "mon", "qu", "ent", "har", "ry", "pot", "ter", "ble", "zor", "ith", "ce", "nu", "fa" }
local function word()
    local w = {}
    for _ = 1, math.random(2, 4) do w[#w + 1] = syll[math.random(#syll)] end
    return table.concat(w)
end
local vocab = {}
for i = 1, V do vocab[i] = word() .. (i > 4000 and syll[i % #syll + 1] or "") end
local first, last = {}, {}
for i = 1, 300 do first[i] = word():gsub("^%l", string.upper) end
for i = 1, 800 do last[i] = word():gsub("^%l", string.upper) .. (i % 7 == 0 and "é" or "") end
local small = { "the", "of", "and", "a", "in", "to" }

local books = {}
for i = 1, N do
    local t = {}
    for k = 1, math.random(2, 7) do
        t[k] = (k % 3 == 0) and small[math.random(#small)] or vocab[math.random(#vocab)]
    end
    local title = table.concat(t, " "):gsub("^%l", string.upper)
    books[i] = {
        path = "/b/" .. i, name = title .. ".epub", title = title,
        authors = { first[math.random(#first)] .. " " .. last[math.random(#last)] },
        series = (i % 5 == 0) and (vocab[math.random(#vocab)] .. " saga") or nil,
    }
end
-- a few known books to find
books[1234] = { path = "/hp", name = "hp.epub", title = "Harry Potter and the Philosopher's Stone", authors = { "J. K. Rowling" }, series = "Harry Potter" }
books[4321] = { path = "/je", name = "je.epub", title = "Jane Eyre", authors = { "Charlotte Brontë" } }
books[2500] = { path = "/ho", name = "ho.epub", title = "The Hobbit", authors = { "J. R. R. Tolkien" } }

local clock = os.clock
local t0 = clock()
Core.indexBooks(books)
local t_index = clock() - t0
local ntok, uniq = 0, {}
for _, b in ipairs(books) do ntok = ntok + #b.search_tokens; for _, w in ipairs(b.search_tokens) do uniq[w] = true end end
local nuniq = 0; for _ in pairs(uniq) do nuniq = nuniq + 1 end

local function stats(list)
    table.sort(list)
    local sum = 0; for _, v in ipairs(list) do sum = sum + v end
    return list[math.ceil(#list / 2)], list[math.ceil(#list * 0.95)], list[#list], sum / #list
end

local queries = { "harry poter", "charlote bronte", "tolkein hobit", "philospher stone", "zorithce kalomer" }
local function run(fuzzy)
    local per = {}
    local found = {}
    for _, q in ipairs(queries) do
        for len = 1, #q do
            local prefix = q:sub(1, len)
            local t = clock()
            local res = Core.searchIndexed(books, prefix, nil, nil, fuzzy)
            per[#per + 1] = (clock() - t) * 1000
            if len == #q then found[q] = res end
        end
    end
    return per, found
end

print(string.format("books %d, words indexed %d (%d distinct)", N, ntok, nuniq))
print(string.format("indexing (keys + normalised words): %.1f ms total", t_index * 1000))
local function report(label, per)
    local med, p95, max, mean = stats(per)
    print(string.format("%-42s median %6.2f ms  p95 %6.2f ms  max %6.2f ms  mean %6.2f ms  (%d keystrokes)", label, med, p95, max, mean, #per))
end
local plain = run(false); report("plain search, per keystroke", plain)
local warm, found = run(true); report("typo-tolerant, per keystroke (typing)", warm)
-- cold: fresh distance memo for every keystroke (worst case)
local cold = {}
for _, q in ipairs(queries) do
    for len = 1, #q do
        package.loaded.librarycore = nil
        local C = require("librarycore")
        local t = clock()
        C.searchFuzzy(books, q:sub(1, len))
        cold[#cold + 1] = (clock() - t) * 1000
    end
end
report("typo-tolerant, per keystroke (cold memo)", cold)
for _, q in ipairs(queries) do
    local r = found[q]
    print(string.format("  %-20s -> %d results, first: %s", q, #r, r[1] and r[1].title or "-"))
end

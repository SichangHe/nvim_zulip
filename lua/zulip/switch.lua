--- Switching conversations by name: a picker, `:ZulipSwitch`, and fuzzy matching for voice commands.
-- 🧑 "we need to invoke the agents themselves. and there should be some external way. by searching through the agent. thread list"
local M = {}

--- `text` in lower case without anything but letters and digits, so "terminal viz" equals `terminal_viz`.
function M.squash(text)
    return (text:lower():gsub("[^%w]", ""))
end

local function distance(a, b)
    local d = {}
    for i = 0, #a do
        d[i] = { [0] = i }
    end
    for j = 1, #b do
        d[0][j] = j
    end
    for i = 1, #a do
        for j = 1, #b do
            d[i][j] = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a:sub(i, i) == b:sub(j, j) and 0 or 1))
        end
    end
    return d[#a][#b]
end

--- Score of `query` against a conversation name: lower is better, `nil` when nothing alike.
local function score(query, name)
    local q, n = M.squash(query), M.squash(name)
    if q == "" then
        return nil
    elseif n == q then
        return 0
    elseif n:sub(1, #q) == q then
        return 1
    elseif n:find(q, 1, true) then
        return 2
    end
    local d = math.min(distance(q, n), #n > #q and distance(q, n:sub(1, #q)) or math.huge)
    return d <= math.floor(#q / 4) + 1 and 3 + d or nil
end

--- The conversations of `rows` matching `query`, best first (ties keep the recent-first order).
function M.matches(query, rows)
    local found = {}
    for i, row in ipairs(rows) do
        local s = score(query, row.topic or row.name)
        if s then
            found[#found + 1] = { row = row, score = s, order = i }
        end
    end
    table.sort(found, function(a, b)
        return a.score ~= b.score and a.score < b.score or a.order < b.order
    end)
    return vim.tbl_map(function(item)
        return item.row
    end, found)
end

local function label(row)
    return ("%s%s"):format(row.n_unread > 0 and ("(%d) "):format(row.n_unread) or "", row.name)
end

--- Choose among `rows` with `vim.ui.select` (telescope and fzf-lua replace it when installed) and open the choice.
local function choose(rows)
    vim.ui.select(rows, { prompt = "Switch to conversation", format_item = label }, function(row)
        if row then
            require("zulip.conversation").open(row)
        end
    end)
end

--- `:ZulipSwitch [name]`: with a name open the best match, asking when several match about equally; without, pick from all.
function M.run(query)
    local rows = require("zulip.sidebar").rows
    if #rows == 0 then
        return vim.notify("zulip: no conversations yet; open the sidebar first", vim.log.levels.WARN)
    end
    if not query or query == "" then
        return choose(rows)
    end
    local found = M.matches(query, rows)
    if #found == 0 then
        return vim.notify("zulip: no conversation like " .. query, vim.log.levels.WARN)
    end
    if #found == 1 or M.squash(found[1].topic or found[1].name) == M.squash(query) then
        return require("zulip.conversation").open(found[1])
    end
    choose(vim.list_slice(found, 1, 8))
end

return M

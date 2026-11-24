--- Command-mode grammar, the same as the web app's (zulip-voice/v2/grammar.mjs `navCommand` and voicecontrol.mjs `runCommands`).
-- 🧑 "We may have feature parity problems between the two ... Is there a good way we can maintain both and keep them in sync"
local M = {}

local NUMBERS = { to = 2, too = 2, won = 1, ["for"] = 4, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10 }
for i = 1, 10 do
    NUMBERS[tostring(i)] = i
end

local function split(text)
    local words = {}
    for w in text:lower():gsub("[^%w%s']", " "):gmatch("%S+") do
        words[#words + 1] = w
    end
    return words
end
M.split = split

local function kind(t)
    if t == "back" or t == "previous" or t == "last" then
        return -1
    elseif t == "next" or t == "skip" or t == "forward" then
        return 1
    elseif t == "again" or t == "repeat" then
        return 0
    end
end

local START_WORDS = { restart = true, start = true, beginning = true, top = true }
local START_FILL = { restart = true, start = true, beginning = true, top = true, from = true, the = true, go = true, to = true }

--- A whole phrase that is only navigation: `{ dir = -1|0|1, whole, count, restart }`, or nil.
function M.nav(words)
    local whole, rest = false, {}
    for _, t in ipairs(words) do
        if t == "message" or t == "messages" then
            whole = true
        else
            rest[#rest + 1] = t
        end
    end
    local dir_word = ({ forward = 1, forwards = 1, ahead = 1, next = 1, backward = -1, backwards = -1, back = -1, previous = -1, last = -1 })[rest[2] or ""]
    if rest[1] == "skip" and dir_word and #rest <= 3 then
        local c = #rest == 3 and NUMBERS[rest[3]] or (#rest < 3 and 1 or nil)
        if c then
            return { dir = dir_word, whole = whole, count = c }
        end
    end
    if #rest > 0 and #rest <= 3 then
        local all, any = true, false
        for _, t in ipairs(rest) do
            all = all and START_FILL[t] or false
            any = any or START_WORDS[t] or false
        end
        if all and any then
            return { dir = -1, whole = true, count = 1, restart = true }
        end
    end
    local n = NUMBERS[rest[#rest] or ""]
    if #rest == 2 and n and not NUMBERS[rest[1]] then
        local d = kind(rest[1])
        if d and d ~= 0 then
            return { dir = d, whole = whole, count = n }
        end
    end
    if #rest == 0 or #rest > 5 then
        return nil
    end
    local d0 = kind(rest[1])
    for _, t in ipairs(rest) do
        if kind(t) == nil or kind(t) ~= d0 then
            return nil
        end
    end
    return { dir = d0, whole = whole, count = d0 == 0 and 1 or #rest }
end

local function phrase(words, i, n)
    return table.concat(words, " ", i, math.min(#words, i + n - 1))
end
local NEXT_AGENT = { "next agent", "next thread", "next unread", "next one", "switch next", "go next", "switch to next", "go to next", "switch to the next", "next unread agent" }
local SWITCH_BACK = { "switch back", "go back", "previous agent", "switch to previous agent", "switch to the previous agent", "go back to the previous agent", "switch back to the previous agent" }
local SEND_LOG = { "send log", "send logs", "send the log", "upload log", "upload the log", "send debug log", "send log to server" }

local function starts_with(words, i, list)
    for _, p in ipairs(list) do
        local n = #split(p)
        if phrase(words, i, n) == p then
            return n
        end
    end
end

--- The commands in `words` (command word already removed), in order:
--- `{ kind = "nav", nav }`, `{ kind = "pause" }`, `{ kind = "play" }`, `{ kind = "switch", name }`, `{ kind = "switch_back" }`,
--- `{ kind = "next_agent" }`, `{ kind = "send_log" }`, `{ kind = "cancel" }`; words understood as nothing go to `ignored`.
function M.parse(words, cancel_word)
    local out, ignored, i = {}, {}, 1
    while i <= #words do
        local t = words[i]
        local n = starts_with(words, i, SEND_LOG)
        if n then
            out[#out + 1] = { kind = "send_log" }
            i = i + n
        elseif starts_with(words, i, NEXT_AGENT) then
            out[#out + 1] = { kind = "next_agent" }
            break
        elseif starts_with(words, i, SWITCH_BACK) then
            out[#out + 1] = { kind = "switch_back" }
            break
        elseif (t == "switch" or t == "switched" or t == "switching" or t == "go") and (words[i + 1] == "to" or words[i + 1] == "agent") then
            local from = i + ((words[i + 1] == "agent" and words[i + 2] == "to") and 3 or 2)
            out[#out + 1] = { kind = "switch", name = table.concat(words, " ", from) }
            break
        elseif t == cancel_word then
            out[#out + 1] = { kind = "cancel" }
            break
        else
            local took
            for len = 3, 1, -1 do
                if i + len - 1 <= #words then
                    local nav = M.nav(vim.list_slice(words, i, i + len - 1))
                    if nav then
                        out[#out + 1] = { kind = "nav", nav = nav }
                        took = len
                        break
                    end
                end
            end
            if took then
                i = i + took
            elseif t == "stop" or t == "pause" or t == "wait" then
                out[#out + 1] = { kind = "pause" }
                i = i + 1
            elseif t == "play" or t == "resume" or t == "continue" then
                out[#out + 1] = { kind = "play" }
                i = i + 1
            else
                ignored[#ignored + 1] = t
                i = i + 1
            end
        end
    end
    return out, ignored
end

return M

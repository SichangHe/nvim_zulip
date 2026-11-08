--- Hands-free voice control, as the web client's: the microphone stays open, a piece of speech starting with the start word
--- pauses reading and opens a reply that is typed live into the compose buffer; the end word followed by silence (or a long
--- silence) sends it and resumes reading. `pause next` and `pause back` skip by message.
local config = require("zulip.config")
local player = require("zulip.player")
local voice = require("zulip.voice")
local M = {
    --- Whether the listener is on.
    on = false,
    --- The open reply, or `nil`: `{ ctx, buf, base, text, timer, paused }`.
    reply = nil,
    --- The conversation of the buffer that switched it on: `{ compose = fn() -> buf }`.
    ctx = nil,
}
local RESUME_SILENCE_MS = 1000
local START_ALIASES = { pause = { "pause", "paws", "pose", "pours", "paused", "pawz", "pulse", "pulls", "polls" } }

local function normalize(text)
    return vim.trim(text:lower():gsub("[^a-z0-9 ]+", " "):gsub("%s+", " "))
end

local function edit_distance(a, b)
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

local function words_of(text)
    return vim.split(vim.trim(text), "%s+", { trimempty = true })
end

--- `text` after leading start words (fuzzy, repeats collapsed), or `nil` when it does not start with one.
function M.after_start_word(text)
    local word = normalize(config.voice.start_word)
    local accepted = vim.list_extend({ word }, START_ALIASES[word] or {})
    local words, i = words_of(text), 1
    local function is_start(w)
        w = normalize(w)
        return w ~= "" and (vim.list_contains(accepted, w) or edit_distance(w, word) <= (#word >= 5 and 1 or 0))
    end
    if not (words[1] and is_start(words[1])) then
        return nil
    end
    while words[i] and is_start(words[i]) do
        i = i + 1
    end
    return table.concat(words, " ", i)
end

--- `text` without a trailing end word ("over", "over over", "over and out"; other words match fuzzily), or `nil` when it has none.
function M.strip_end_word(text)
    local words = words_of(text)
    local norm = vim.tbl_map(normalize, words)
    local phrase = normalize(config.voice.end_word)
    local n = #norm
    if phrase == "over" then
        if n >= 3 and norm[n] == "out" and norm[n - 1] == "and" and norm[n - 2] == "over" then
            n = n - 2
        end
        local last = n
        while n > 0 and norm[n] == "over" do
            n = n - 1
        end
        if n < last then
            return table.concat(words, " ", 1, n)
        end
        local bare = text:match("^(.-)[%s%p]+[Oo]ver[%s%p]*$")
        return bare or (normalize(text) == "over" and "" or nil)
    end
    for _, q in ipairs({ phrase, "over" }) do
        local k = #words_of(q)
        if q ~= "" and #words >= k and edit_distance(normalize(table.concat(words, " ", #words - k + 1)), q) <= math.floor(#q / 6) then
            return table.concat(words, " ", 1, #words - k)
        end
    end
end

local function cancel_timer(reply)
    if reply.timer then
        reply.timer:stop()
        reply.timer:close()
        reply.timer = nil
    end
end

local function arm(reply, ms, fn)
    cancel_timer(reply)
    reply.timer = vim.uv.new_timer()
    reply.timer:start(ms, 0, vim.schedule_wrap(function()
        if M.reply == reply then
            fn()
        end
    end))
end

--- Resume reading if the reply paused it.
local function resume(reply)
    if reply.paused and player.run and player.run.paused then
        player.toggle_pause()
    end
end

--- Show the reply so far in its compose buffer.
local function show(reply)
    if vim.api.nvim_buf_is_valid(reply.buf) then
        local text = vim.trim(reply.base .. " " .. reply.text)
        vim.api.nvim_buf_set_lines(reply.buf, 0, -1, false, vim.split(text, "\n"))
    end
end

--- Nothing was said after the start word: close and carry on.
local function close_empty(reply)
    M.reply = nil
    voice.earcon("done")
    resume(reply)
    player.paint()
end

--- The end word was followed by silence: send what was said, then resume.
local function finish(reply)
    if reply.sent then
        return
    end
    reply.sent = true
    M.reply = nil
    local text = M.strip_end_word(reply.text) or reply.text
    reply.text = text
    show(reply)
    voice.earcon("done")
    if text ~= "" and vim.api.nvim_buf_is_valid(reply.buf) then
        vim.api.nvim_buf_call(reply.buf, function()
            vim.cmd("silent write")
        end)
    end
    resume(reply)
    player.paint()
end

local function add(reply, heard)
    reply.text = vim.trim(reply.text .. " " .. heard:gsub("^%s*[Pp]ause[%s%p]*", ""))
    show(reply)
    local ms = M.strip_end_word(reply.text) and RESUME_SILENCE_MS or config.voice.long_silence_s * 1000
    if reply.text ~= "" and ms > 0 then
        arm(reply, ms, function()
            finish(reply)
        end)
    else
        arm(reply, config.voice.empty_s * 1000, function()
            close_empty(reply)
        end)
    end
    player.paint()
end

local ORDINALS = { first = 1, one = 1, ["1"] = 1, second = 2, two = 2, ["2"] = 2, third = 3, three = 3, ["3"] = 3 }

--- "switch to X" / "go to X": open the conversation like X; several alike: list the top 3 and wait for "first", "second" or "third".
local function switch_to(name)
    local switch = require("zulip.switch")
    local rows = require("zulip.sidebar").rows
    local found = switch.matches(name, rows)
    voice.log("voice control: switch to %q matches %s", name, table.concat(vim.tbl_map(function(r) return r.name end, vim.list_slice(found, 1, 3)), ", "))
    if #found == 0 then
        voice.earcon("error")
        return vim.notify("zulip voice: no conversation like " .. name, vim.log.levels.WARN)
    end
    local exact = #found == 1 or switch.squash(found[1].topic or found[1].name) == switch.squash(name)
    if exact then
        voice.earcon("done")
        return require("zulip.conversation").open(found[1])
    end
    M.choice = vim.list_slice(found, 1, 3)
    vim.notify("zulip voice: say first, second or third:\n" .. table.concat(vim.tbl_map(function(r)
        return r.name
    end, M.choice), "\n"))
    voice.earcon("ready")
end

--- `{ unit, delta }` when the whole utterance is a navigation command, else `nil`.
function M.navigation(text)
    local words = normalize(text):gsub("^pause ", "")
    local commands = {
        { "back", "chunk", -1 }, { "previous", "chunk", -1 }, { "again", "chunk", -1 }, { "repeat", "chunk", -1 },
        { "previous message", "message", -1 }, { "back message", "message", -1 }, { "last message", "message", -1 },
        { "next", "chunk", 1 }, { "skip", "chunk", 1 }, { "forward", "chunk", 1 },
        { "next message", "message", 1 }, { "skip message", "message", 1 },
    }
    for _, command in ipairs(commands) do
        if words == command[1] then
            return { command[2], command[3] }
        end
    end
end

local function open(rest)
    local said = normalize(rest)
    if said == "switch back" or said == "previous agent" or said == "previous thread" or said == "go back to the previous agent" then
        voice.earcon("done")
        return require("zulip.switch").back()
    end
    local target = normalize(rest):match("^switch to (.+)$") or normalize(rest):match("^go to (.+)$") or normalize(rest):match("^open (.+)$")
    if target then
        return switch_to(target)
    end
    local ctx = M.ctx
    local reply = { ctx = ctx, buf = ctx.compose(), base = "", text = "", paused = player.run ~= nil and not player.run.paused }
    if vim.api.nvim_buf_is_valid(reply.buf) then
        reply.base = vim.trim(table.concat(vim.api.nvim_buf_get_lines(reply.buf, 0, -1, false), "\n"))
    end
    local command = M.navigation(rest)
    if command then
        voice.log("voice control: navigation %s %d", command[1], command[2])
        if reply.paused then
            player.toggle_pause()
        end
        return ctx.step(command[1], command[2])
    end
    if reply.paused then
        player.toggle_pause()
    end
    M.reply = reply
    voice.earcon("ready")
    if rest ~= "" then
        add(reply, rest)
    else
        arm(reply, config.voice.empty_s * 1000, function()
            close_empty(reply)
        end)
    end
    player.paint()
end

--- Handle one transcribed piece of speech.
function M.heard(text)
    if not M.on or voice.session then
        return
    end
    if M.choice then
        local n = ORDINALS[normalize(text):match("^(%w+)")]
        local choice = M.choice
        M.choice = nil
        voice.log("voice control: choice %q -> %s", text, tostring(n))
        if n and choice[n] then
            voice.earcon("done")
            return require("zulip.conversation").open(choice[n])
        end
    end
    local command = M.reply and M.navigation(text)
    if command then
        voice.log("voice control: navigation %s %d inside a reply; draft kept, not sent", command[1], command[2])
        local reply = M.reply
        cancel_timer(reply)
        M.reply = nil
        if reply.paused and player.run and player.run.paused then
            player.toggle_pause()
        end
        voice.earcon("done")
        return reply.ctx.step(command[1], command[2])
    end
    if M.reply then
        voice.log("voice control: reply open, adding %q", text)
        return add(M.reply, text)
    end
    local rest = M.after_start_word(text)
    voice.log("voice control: heard %q, start word %s", text, rest and ("matched, rest %q"):format(rest) or "not found, ignored")
    if rest then
        open(rest)
    end
end

--- Short state for the status line, or `nil` when off.
function M.label()
    if not M.on then
        return nil
    end
    return M.reply and "voice control: reply" or "voice control: listening"
end

--- Turn the listener on or off; `ctx.compose()` returns the compose buffer of the conversation.
function M.toggle(ctx)
    if M.on then
        voice.log("voice control off")
        require("zulip.state").save(false)
        M.on = false
        if M.reply then
            cancel_timer(M.reply)
            M.reply = nil
        end
        voice.unlisten()
        player.paint()
        return vim.notify("zulip voice: voice control off")
    end
    M.ctx = ctx
    voice.listen(M.heard, function(err)
        if err then
            return vim.notify("zulip voice: " .. err, vim.log.levels.ERROR)
        end
        M.on = true
        require("zulip.state").save(true)
        voice.log("voice control on, start word %q, end word %q", config.voice.start_word, config.voice.end_word)
        voice.earcon("ready")
        player.paint()
        vim.notify(("zulip voice: voice control on; say \"%s\", finish a reply with \"%s\""):format(config.voice.start_word, config.voice.end_word))
    end)
end

return M

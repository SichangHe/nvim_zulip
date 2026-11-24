--- Hands-free voice control, as the web client's: the microphone stays open, a piece of speech starting with the start word
--- pauses reading and opens a reply that is typed live into the compose buffer; the end word followed by silence (or a long
--- silence) sends it and resumes reading. "<start word> next" and "<start word> back" skip.
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

--- A rough sound of `text`: c, q, ck as k, ph as f, z as s, x as ks, h dropped, vowels merged, doubled letters collapsed.
function M.phonetic(text)
    local s = text:lower():gsub("[^a-z]", "")
    s = s:gsub("ph", "f"):gsub("ck", "k"):gsub("[cq]", "k"):gsub("z", "s"):gsub("x", "ks"):gsub("h", ""):gsub("[aeiouy]", "a")
    return (s:gsub("(.)%1+", "%1"))
end

--- Whether `heard` sounds like `wanted`. Short words (sound of 4 letters or fewer) must match exactly, since fuzzy
--- matching them would catch ordinary words; longer ones tolerate an edit distance of a third of their length, at most 2.
function M.sounds_like(heard, wanted)
    local a, b = M.phonetic(heard), M.phonetic(wanted)
    if a == "" or b == "" then
        return false
    end
    if #b <= 4 then
        return a == b and normalize(heard) == normalize(wanted)
    end
    return edit_distance(a, b) <= math.min(2, math.floor(#b / 3))
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
        return w ~= "" and (vim.list_contains(accepted, w) or edit_distance(w, word) <= (#word >= 5 and 1 or 0) or M.sounds_like(w, word))
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
    local k, last = #words_of(phrase), #words
    local function ends_here(upto)
        return upto >= k and (M.sounds_like(table.concat(words, " ", upto - k + 1, upto), phrase))
    end
    if not ends_here(last) then
        return nil
    end
    while ends_here(last) do
        last = last - k
    end
    return table.concat(words, " ", 1, last)
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
    voice.earcon("empty")
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
    reply.text = vim.trim(reply.text .. " " .. (M.after_start_word(heard) or heard))
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
    local words = normalize(M.after_start_word(text) or text)
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

local COMMAND_WINDOW_MS = 8000
local CANCEL_PHRASES = { cancel = true, ["cancel that"] = true, ["never mind"] = true, ["scratch that"] = true, ["forget it"] = true }

--- Whether `text`'s last sentence is a cancel: a fixed phrase, or only the cancel word (the web app's `endsWithCancel`).
function M.ends_with_cancel(text)
    local last
    for sentence in text:gmatch("[^.!?]+") do
        if vim.trim(sentence) ~= "" then
            last = sentence
        end
    end
    if not last then
        return false
    end
    local words = require("zulip.commands").split(last)
    if CANCEL_PHRASES[table.concat(words, " ")] then
        return true
    end
    for _, w in ipairs(words) do
        if not M.sounds_like(w, config.voice.cancel_word) then
            return false
        end
    end
    return #words > 0
end

--- `words` without a leading start word and command word, and whether the command word was there.
local function command_words(text)
    local commands = require("zulip.commands")
    local words = commands.split(M.after_start_word(text) or text)
    local found = false
    while words[1] and M.sounds_like(words[1], config.voice.command_word) do
        table.remove(words, 1)
        found = true
    end
    return words, found
end

--- Discard the reply in progress: the draft goes back to what it was before the start word.
local function cancel_reply(reply)
    cancel_timer(reply)
    M.reply = nil
    reply.text = ""
    show(reply)
    voice.earcon("cancel")
    vim.notify("zulip voice: reply discarded")
    resume(reply)
    player.paint()
end

--- Open the conversation before the current one (voice "switch back", key `gvT`).
function M.switch_back()
    local previous = require("zulip.conversation").previous
    if previous then
        voice.earcon("done")
        return require("zulip.conversation").open(previous)
    end
    voice.earcon("error")
    vim.notify("zulip voice: no previous conversation")
end

--- Open the first other conversation in the list with unread messages (voice "next agent", key `gvn`).
function M.next_unread()
    local current = require("zulip.conversation").current
    local row = vim.iter(require("zulip.sidebar").rows):find(function(r)
        return r.n_unread > 0 and not (current and r.key == current.key)
    end)
    if row then
        voice.earcon("done")
        return require("zulip.conversation").open(row)
    end
    voice.earcon("error")
    vim.notify("zulip voice: no other conversation has unread messages")
end

--- Run command-mode commands (the web app's grammar); returns true when something was understood.
local function run_commands(words)
    local commands = require("zulip.commands")
    local list, ignored = commands.parse(words, config.voice.cancel_word)
    local said, navs = {}, {}
    for _, c in ipairs(list) do
        voice.log("voice control: command %s", vim.inspect(c, { newline = " ", indent = "" }))
        if c.kind == "nav" then
            local nav, ctx = c.nav, M.ctx
            navs[#navs + 1] = function()
                if player.run and player.run.paused then
                    player.toggle_pause()
                end
                if nav.restart then
                    player.restart_message()
                elseif nav.dir == 0 then
                    player.replay_chunk()
                else
                    for _ = 1, nav.count do
                        ctx.step(nav.whole and "message" or "chunk", nav.dir)
                    end
                end
            end
            said[#said + 1] = nav.restart and "from the start" or nav.dir == 0 and "again"
                or (nav.dir > 0 and "next" or "back") .. (nav.whole and " message" or "") .. (nav.count > 1 and (" " .. nav.count) or "")
        elseif c.kind == "pause" then
            if player.run and not player.run.paused then
                player.toggle_pause()
            end
            said[#said + 1] = "paused"
        elseif c.kind == "play" then
            if player.run and player.run.paused then
                player.toggle_pause()
            end
            said[#said + 1] = "playing"
        elseif c.kind == "switch" then
            switch_to(c.name)
        elseif c.kind == "switch_back" then
            M.switch_back()
        elseif c.kind == "next_agent" then
            M.next_unread()
        elseif c.kind == "send_log" then
            voice.send_log()
            said[#said + 1] = "sending the log"
        elseif c.kind == "cancel" then
            if M.reply then
                cancel_reply(M.reply)
            end
        end
    end
    if #said > 0 then
        -- 🧑 (web) "It should, say. Back, with the number first, and then, start playing": the confirmation is spoken, then the navigation runs
        voice.earcon("tick")
        vim.notify("zulip voice: " .. table.concat(said, ", "))
        if player.run and not player.run.paused and #navs > 0 then
            player.toggle_pause()
        end
        local run_navs = function()
            for _, f in ipairs(navs) do
                f()
            end
        end
        if config.voice.say_commands then
            voice.say(table.concat(said, ", "), run_navs)
        else
            run_navs()
        end
    end
    if #list == 0 and #ignored > 0 then
        voice.earcon("error")
        vim.notify(("zulip voice: command not recognized: %q. Commands: next, back, skip backward N, restart, next message, previous message, next agent, switch back, switch to NAME, stop, play, %s"):format(table.concat(ignored, " "), config.voice.cancel_word))
    end
    return #list > 0
end

-- 🧑 mode beats, as in the web app: while a reply or command mode is open and nothing has been heard for 5 s, a low beat says the mode
-- (input: rising, command: two equal); never while reading aloud
local PULSE_MS = 5000
local last_sound_ms, pulse_timer = 0, nil
local function pulse_tick()
    local command_open = M.command_until and vim.uv.now() < M.command_until
    if not M.on or not (M.reply or command_open) then
        return
    end
    if player.run and not player.run.paused and player.run.state == "playing" then
        return
    end
    local listener = voice.listener
    if listener and listener.piece and #listener.piece > 0 then   -- the human is talking
        last_sound_ms = vim.uv.now()
        return
    end
    if vim.uv.now() - last_sound_ms >= PULSE_MS then
        last_sound_ms = vim.uv.now()
        voice.earcon(M.reply and "pulseInput" or "pulseCommand")
    end
end
function M.start_pulse()
    if not pulse_timer then
        pulse_timer = vim.uv.new_timer()
        pulse_timer:start(500, 500, vim.schedule_wrap(pulse_tick))
    end
end
function M.stop_pulse()
    if pulse_timer then
        pulse_timer:stop()
        pulse_timer:close()
        pulse_timer = nil
    end
end

--- Handle one transcribed piece of speech.
function M.heard(text)
    last_sound_ms = vim.uv.now()
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
    -- 🧑 "We are still not at feature parity ... Do it": command mode (command word, then commands) and the cancel word, as in the web app
    local words, has_command_word = command_words(text)
    if has_command_word or (M.command_until and vim.uv.now() < M.command_until) then
        M.command_until = nil
        if #words == 0 then
            M.command_until = vim.uv.now() + COMMAND_WINDOW_MS
            voice.log("voice control: command mode, waiting for a command")
            voice.earcon("command")
            vim.notify("zulip voice: command mode")
            return
        end
        if M.reply then
            cancel_timer(M.reply)
            local reply = M.reply
            local parsed = require("zulip.commands").parse(words, config.voice.cancel_word)
            if not (parsed[1] and parsed[1].kind == "cancel") then
                M.reply = nil
                resume(reply)
            end
        end
        run_commands(words)
        return player.paint()
    end
    if M.reply then
        if M.ends_with_cancel(text) then
            voice.log("voice control: cancel word, reply discarded")
            return cancel_reply(M.reply)
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
        if M.ends_with_cancel(rest) then   -- "attention, some reply, cancel" in one breath: nothing is kept
            voice.log("voice control: start word and cancel word in one utterance, discarded")
            voice.earcon("cancel")
            return vim.notify("zulip voice: reply discarded")
        end
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
        M.stop_pulse()
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
        M.start_pulse()
        require("zulip.state").save(true)
        voice.log("voice control on, start word %q, end word %q", config.voice.start_word, config.voice.end_word)
        voice.earcon("ready")
        player.paint()
        vim.notify(("zulip voice: voice control on; say \"%s\", finish a reply with \"%s\""):format(config.voice.start_word, config.voice.end_word))
    end)
end

return M

--- One conversation: a Markdown buffer of its messages, and a compose buffer for the reply.
local api = require("zulip.api")
local config = require("zulip.config")
local loading, pending, retries = {}, {}, {}
local viz = require("zulip.viz")
local voice = require("zulip.voice")
local player = require("zulip.player")

local M = {
    --- Message buffer of each conversation key.
    bufs = {},
    --- Compose buffer of each conversation key.
    composes = {},
    --- Per message buffer: `spans`, each shown message's `{ id, first, last }` rows, `messages`, and `unread`, a set of message IDs.
    shown = {},
    --- Per conversation key, the last message sent: `{ content, at_ms }`.
    last_sent = {},
}

local function fail(err)
    vim.notify("zulip: " .. err, vim.log.levels.ERROR)
end

local function valid(buf)
    return buf and vim.api.nvim_buf_is_valid(buf)
end

--- Buffer lines for `messages`: a heading with sender and local time, then the Markdown as written.
--- A marker line goes above the message `new_id`; its line number is the second result.
--- The third result is each message's `{ id, first, last }`: its heading row and its last text row.
--- Links relative to the server, such as `](/user_uploads/...)`, get the server address `site` prepended.
function M.render(messages, new_id, site)
    local lines, new_row, spans = {}, nil, {}
    for _, message in ipairs(messages) do
        if message.id == new_id then
            lines[#lines + 1] = "════════ new messages ════════"
            new_row = #lines
        end
        local first = #lines + 1
        lines[#lines + 1] = ("## %s · %s"):format(message.sender_full_name, os.date("%Y-%m-%d %H:%M", message.timestamp))
        lines[#lines + 1] = ""
        -- 🧑 "Automatically prepend the server domain name in the links"
        local content = message.content:gsub("\n?%[switch: [^\n]*%]", "")
        content = site and content:gsub("%]%(/", "](" .. site .. "/") or content
        vim.list_extend(lines, vim.split(content, "\n"))
        spans[#spans + 1] = { id = message.id, first = first, last = #lines }
        lines[#lines + 1] = ""
    end
    return lines, new_row, spans
end

--- The span in `spans` holding `row`, or the last one starting above it.
-- 🧑 "remember the last cursor position in each thread and resume there after reentering the thread"
--- Per conversation key, where the cursor and top line were when the thread was left, by message.
M.left = {}
--- Buffers whose next load restores `M.left` into a window just switched to them.
M.entering = {}

local function span_at(spans, row)
    local found
    for _, span in ipairs(spans) do
        if span.first <= row then
            found = span
        end
    end
    return found
end

-- 🧑 "mark messages as read after cursor go pass it"
--- Mark read, when `config.mark_read`, each unread message of `buf` whose last row the cursor in `win` has moved below.
function M.mark_seen(buf, win)
    local shown = M.shown[buf]
    if not (config.mark_read and shown) then
        return
    end
    local row, seen = vim.api.nvim_win_get_cursor(win)[1], {}
    for _, span in ipairs(shown.spans) do
        if span.last < row and shown.unread[span.id] then
            shown.unread[span.id] = nil
            seen[#seen + 1] = span.id
        end
    end
    if #seen > 0 then
        api.request("POST", "/messages/flags", { messages = seen, op = "add", flag = "read" }, function(err)
            if err then
                fail(err)
            end
        end)
    end
end

--- Mark read each unread message of `buf` up to `id`, as reading reaches it (forward only).
local function mark_upto(buf, id)
    local shown = M.shown[buf]
    if not (config.mark_read and shown) then
        return
    end
    local seen = {}
    for _, message in ipairs(shown.messages) do
        if message.id <= id and shown.unread[message.id] then
            shown.unread[message.id] = nil
            seen[#seen + 1] = message.id
        end
    end
    if #seen > 0 then
        api.request("POST", "/messages/flags", { messages = seen, op = "add", flag = "read" }, function(err)
            if err then
                fail(err)
            end
        end)
    end
end

--- Read aloud from chunk `idx` (0-based) of message `id` in `buf` (`conversation`), through the later messages of others.
--- Earlier unread messages count as read: reading only moves forward.
local function read_from(buf, conversation, id, idx)
    local messages = {}
    for _, message in ipairs(M.shown[buf].messages) do
        if message.id == id or (#messages > 0 and message.sender_id ~= api.account.user_id) then
            messages[#messages + 1] = message
        end
    end
    mark_upto(buf, id - 1)
    player.read(buf, conversation.key, messages, idx, function(done_id)
        mark_upto(buf, done_id)
    end)
end

--- Read aloud from the message under the cursor of `buf`.
local function speak(buf, conversation)
    local shown = M.shown[buf]
    local at = shown and span_at(shown.spans, vim.api.nvim_win_get_cursor(0)[1])
    if not at then
        return fail("no message here")
    end
    read_from(buf, conversation, at.id, 0)
end

--- Move `delta` (+1 or -1) by `unit` (`chunk` or `message`). While reading that moves the reading;
--- otherwise it starts reading: previous replays the last chunk or message heard, next starts after it;
--- with nothing heard it starts from the cursor message (its last chunk for previous chunk).
local function step(buf, conversation, unit, delta)
    if player.run then
        return unit == "chunk" and player.step_chunk(delta) or player.step_message(delta)
    end
    local shown = M.shown[buf]
    local at = shown and span_at(shown.spans, vim.api.nvim_win_get_cursor(0)[1])
    local last = player.last[conversation.key]
    if not at then
        return fail("no message here")
    end
    local id, idx = last and last.id or at.id, last and last.idx or 0
    local function n_chunks(message_id)
        local message = vim.iter(shown.messages):find(function(m) return m.id == message_id end)
        return message and #voice.chunks(voice.blocks(message.content)) or 0
    end
    if not last and unit == "chunk" and delta < 0 then
        idx = math.max(n_chunks(id) - 1, 0)
    elseif last and unit == "chunk" and delta > 0 then
        idx = idx + 1
        if idx >= n_chunks(id) then
            local after = vim.iter(shown.messages):find(function(m) return m.id > id and m.sender_id ~= api.account.user_id end)
            id, idx = after and after.id or id, after and 0 or idx - 1
        end
    elseif last and unit == "message" then
        idx = 0
        if delta > 0 then
            local after = vim.iter(shown.messages):find(function(m) return m.id > id and m.sender_id ~= api.account.user_id end)
            id = after and after.id or id
        end
    elseif not last then
        idx = 0
    end
    read_from(buf, conversation, id, idx)
end

--- Each of `lines` as a Markdown quote, then an empty line to write on.
function M.quote(lines)
    local quoted = vim.tbl_map(function(line)
        return line == "" and ">" or "> " .. line
    end, lines)
    quoted[#quoted + 1] = ""
    return quoted
end

--- Fetch the conversation's newest messages into its buffer and mark where the new messages start.
--- On the first load each cursor goes to that mark, or to the end when nothing is new;
--- on a reload each window keeps its view on the same messages.
function M.load(conversation)
    local buf = M.bufs[conversation.key]
    if not valid(buf) then
        return
    end
    if loading[buf] then
        pending[buf] = true
        return
    end
    if retries[buf] then
        retries[buf]:stop()
        retries[buf]:close()
        retries[buf] = nil
    end
    loading[buf] = true
    local narrow = conversation.stream_id
            and { { operator = "channel", operand = conversation.stream_id }, { operator = "topic", operand = conversation.topic } }
        or { { operator = "dm", operand = conversation.user_ids } }
    local params = { narrow = narrow, anchor = "newest", num_before = config.n_shown, num_after = 0, apply_markdown = false }
    api.request("GET", "/messages", params, function(err, reply)
        loading[buf] = nil
        local entering = M.entering[buf]
        M.entering[buf] = nil
        if err then
            pending[buf] = nil
            if valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
                retries[buf] = vim.defer_fn(function()
                    retries[buf] = nil
                    if valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
                        M.load(conversation)
                    end
                end, config.refresh_ms)
            end
            return fail(err)
        end
        if not valid(buf) then
            return
        end
        local messages = reply.messages
        local before = M.shown[buf]
        local newest_before = vim.b[buf].zulip_newest_id
        -- 🧑 "don't scroll when new messages appear": note which message each window's cursor and top line are in.
        local views = {}
        if before then
            for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                if entering == win then
                    goto continue
                end
                local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
                local at, top = span_at(before.spans, view.lnum), span_at(before.spans, view.topline)
                views[win] = { view = view, at = at, top = top }
                ::continue::
            end
        end
        local unread, unread_set = {}, {}
        -- 🧑 "Don't show messages I sent as unread"
        for _, message in ipairs(messages) do
            if not vim.list_contains(message.flags, "read") and not (api.account and message.sender_id == api.account.user_id) then
                unread[#unread + 1] = message.id
                unread_set[message.id] = true
            end
        end
        -- 🧑 "Can't tell where new messages start"
        -- Marking read clears the unread flags, so the marker's message is kept across reloads.
        vim.b[buf].zulip_new_id = unread[1] or vim.b[buf].zulip_new_id
        local lines, new_row, spans = M.render(messages, vim.b[buf].zulip_new_id, api.account and api.account.site)
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        viz.show(buf)
        vim.b[buf].zulip_newest_id = #messages > 0 and messages[#messages].id or 0
        M.shown[buf] = { spans = spans, messages = messages, unread = unread_set }
        player.refresh(buf)
        if api.account then
            local others = vim.tbl_filter(function(message)
                return message.sender_id ~= api.account.user_id
            end, messages)
            player.autoplay(buf, conversation.key, vim.tbl_filter(function(message)
                return unread_set[message.id]
            end, others), function(id)
                mark_upto(buf, id)
            end)
            if before then
                M.switch_to(buf, vim.tbl_filter(function(message)
                    return message.id > newest_before
                end, others))
            end
        end
        local first_rows = {}
        for _, span in ipairs(spans) do
            first_rows[span.id] = span.first
        end
        --- `row` moved with the message `span` it was in; unchanged when that message is gone.
        local function moved(span, row)
            local first = span and first_rows[span.id]
            return math.max(1, math.min(first and first + row - span.first or row, #lines))
        end
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            local kept = views[win]
            local left = M.left[conversation.key]
            if not kept and left and (win == entering or not before) then
                kept = { view = vim.api.nvim_win_call(win, vim.fn.winsaveview), at = left.at, top = left.top }
                kept.view.lnum, kept.view.topline = left.lnum, left.topline
            end
            if kept then
                local view = kept.view
                view.lnum, view.topline = moved(kept.at, view.lnum), moved(kept.top, view.topline)
                vim.api.nvim_win_call(win, function()
                    vim.fn.winrestview(view)
                end)
            elseif not before or win == entering then
                vim.api.nvim_win_set_cursor(win, { math.max(unread[1] and new_row or #lines, 1), 0 })
            end
            M.mark_seen(buf, win)
        end
        if pending[buf] then
            pending[buf] = nil
            M.load(conversation)
        end
    end)
end

--- Reload each displayed conversation whose newest message in `conversations` is not the one shown.
function M.reload_changed(conversations)
    for _, conversation in ipairs(conversations) do
        local buf = M.bufs[conversation.key]
        if valid(buf) and #vim.fn.win_findbuf(buf) > 0 and vim.b[buf].zulip_newest_id ~= conversation.newest_id then
            M.load(conversation)
        end
    end
end

--- Send the compose buffer `buf`, then close it and reload the conversation.
local function send(buf)
    local conversation = vim.b[buf].zulip_conversation
    local content = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    if content == "" then
        return fail("nothing to send")
    end
    if vim.b[buf].zulip_sending then
        return fail("still sending")
    end
    local sent_before = M.last_sent[conversation.key]
    if sent_before and sent_before.content == content and vim.uv.now() - sent_before.at_ms < 120000 then
        return fail("the same message was just sent; not sending it twice")
    end
    M.last_sent[conversation.key] = { content = content, at_ms = vim.uv.now() }
    vim.b[buf].zulip_sending = true
    local params = conversation.stream_id
            and { type = "stream", to = conversation.stream_id, topic = conversation.topic, content = content }
        or { type = "direct", to = conversation.user_ids, content = content }
    api.request("POST", "/messages", params, function(err)
        if not valid(buf) then
            return
        end
        vim.b[buf].zulip_sending = false
        if err then
            M.last_sent[conversation.key] = nil
            return fail(err)
        end
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.notify("zulip: sent to " .. conversation.name)
        if valid(M.bufs[conversation.key]) then
            M.load(conversation)
        end
    end)
end

--- Open the compose buffer of `conversation` below, with `quoted` lines appended.
function M.compose(conversation, quoted)
    local buf = M.composes[conversation.key]
    if not valid(buf) then
        buf = vim.api.nvim_create_buf(false, false)
        M.composes[conversation.key] = buf
        vim.api.nvim_buf_set_name(buf, "zulip-compose://" .. conversation.key .. " " .. conversation.name)
        vim.bo[buf].buftype = "acwrite"
        vim.bo[buf].filetype = "markdown"
        vim.b[buf].zulip_conversation = conversation
        vim.api.nvim_create_autocmd("BufWriteCmd", {
            buffer = buf,
            callback = function()
                send(buf)
            end,
        })
        vim.keymap.set("n", "<CR>", function()
            if voice.session then
                voice.send_when_done()
            else
                vim.cmd.write()
            end
        end, { buffer = buf, desc = "Send (while dictating: stop, wait for the text, then send)" })
        vim.api.nvim_create_autocmd("BufWinEnter", {
            buffer = buf,
            callback = function()
                voice.idle_bar(vim.api.nvim_get_current_win())
            end,
        })
        if config.voice.keys.compose_dictate then
            vim.keymap.set("n", config.voice.keys.compose_dictate, function()
                voice.dictate(buf)
            end, { buffer = buf, desc = "Zulip voice: start or stop dictating" })
        end
        if config.voice.keys.interrupt then
            vim.keymap.set("n", config.voice.keys.interrupt, player.stop, { buffer = buf, desc = "Zulip voice: stop reading" })
        end
    end
    local win = vim.fn.bufwinid(buf)
    if win == -1 then
        vim.cmd(("belowright %dsplit"):format(config.compose_height))
        vim.api.nvim_win_set_buf(0, buf)
    else
        vim.api.nvim_set_current_win(win)
    end
    if quoted then
        local empty = vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
        vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, quoted)
    end
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
end

--- The task tag in `word`, such as `nvim_omnigent` in `[nvim_omnigent]` or `nvim_omnigent.md`, or `nil`.
function M.tag(word)
    return word:match("[%w_%-]+%.md") and word:match("([%w_%-]+)%.md") or word:match("^%W*([%w_%-]+)%W*$")
end

--- Open the listed channel topic named `tag`, ignoring case; false when there is none.
local function open_tag(tag)
    local target = tag and vim.iter(require("zulip.sidebar").rows):find(function(conversation)
        return conversation.topic and conversation.topic:lower() == tag:lower()
    end)
    if target then
        M.open(target)
    end
    return target ~= nil
end

--- 🧑 "jump to the conversation on gf on a tag"
--- Open the channel topic named by the tag under the cursor; otherwise run the built-in `gf`.
function M.goto_tag()
    if not open_tag(M.tag(vim.fn.expand("<cWORD>"))) then
        vim.cmd.normal({ "gf", bang = true })
    end
end

-- 🧑 "The agent switching control should also work in nvim"
--- Follow the last `[switch: TASK]` line in the new `messages` of `buf`, in the window showing it:
--- at once, or after the reading in progress ends. An unknown task only warns.
function M.switch_to(buf, messages)
    local task
    for _, message in ipairs(messages) do
        for line in message.content:gmatch("[^\n]+") do
            task = line:match("^%[switch: (.-)%]%s*$") or task
        end
    end
    local win = vim.fn.bufwinid(buf)
    if not task or win == -1 then
        return
    end
    task = vim.trim(task):gsub("%.md$", "")
    player.after_reading(function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
            if not open_tag(task) then
                vim.notify("zulip: no conversation for " .. task, vim.log.levels.WARN)
            end
        end
    end)
end

--- Show `conversation` and load its messages:
--- from the sidebar in the window beside it, from elsewhere in the current window.
function M.open(conversation)
    local state = require("zulip.state")
    if not (state.current and state.current.key == conversation.key) then
        state.previous = state.current or state.previous
        state.current = { key = conversation.key, name = conversation.name, stream_id = conversation.stream_id, topic = conversation.topic, user_ids = conversation.user_ids }
        state.save()
    end
    local buf = M.bufs[conversation.key]
    if not valid(buf) then
        buf = vim.api.nvim_create_buf(true, true)
        M.bufs[conversation.key] = buf
        vim.api.nvim_buf_set_name(buf, "zulip://" .. conversation.key .. " " .. conversation.name)
        vim.bo[buf].filetype = "markdown"
        vim.bo[buf].modifiable = false
        vim.keymap.set("n", "<CR>", function()
            M.compose(conversation)
        end, { buffer = buf, desc = "Write a reply" })
        vim.keymap.set("x", "<CR>", function()
            local selection = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
            vim.cmd.normal({ vim.keycode("<Esc>"), bang = true })
            M.compose(conversation, M.quote(selection))
        end, { buffer = buf, desc = "Quote the selection into a reply" })
        vim.keymap.set("n", "gf", M.goto_tag, { buffer = buf, desc = "Open the conversation of the tag under the cursor" })
        vim.keymap.set("n", "p", viz.toggle, { buffer = buf, desc = "Show or hide previews" })
        vim.keymap.set("n", "gx", viz.open, { buffer = buf, desc = "Open the upload on this line" })
        local keys = config.voice.keys
        local handsfree_ctx = {
            step = function(unit, delta)
                step(buf, conversation, unit, delta)
            end,
            compose = function()
                M.compose(conversation)
                return M.composes[conversation.key]
            end,
        }
        -- Frequent actions are single keys; rare ones sit behind `prefix`.
        local actions = {
            { keys.play, "play from the message under the cursor, or pause and resume", function()
                if player.run then
                    player.toggle_pause()
                else
                    speak(buf, conversation)
                end
            end },
            { keys.read, "read from the message under the cursor", function() speak(buf, conversation) end },
            { keys.back, "switch back to the previous conversation", function() require("zulip.switch").back() end },
            { keys.switch, "switch conversation (search the thread list)", function() require("zulip.switch").run() end },
            { keys.stop, "stop reading", function() player.stop() end },
            { keys.next_chunk, "next chunk", function() step(buf, conversation, "chunk", 1) end },
            { keys.prev_chunk, "previous chunk", function() step(buf, conversation, "chunk", -1) end },
            { keys.next_message, "next message", function() step(buf, conversation, "message", 1) end },
            { keys.prev_message, "previous message (restarts the current one first)", function() step(buf, conversation, "message", -1) end },
            { keys.faster, "faster", function() player.change_speed(0.1) end },
            { keys.slower, "slower", function() player.change_speed(-0.1) end },
            { keys.follow, "toggle keeping the spoken chunk in view", player.toggle_follow },
            { keys.dictate, "dictate a reply", function()
                M.compose(conversation)
                voice.dictate(M.composes[conversation.key])
            end },
            { keys.handsfree, "toggle hands-free voice control", function() require("zulip.handsfree").toggle(handsfree_ctx) end },
        }
        local rare = {
            { keys.autoplay, "toggle reading unread messages aloud", "<Cmd>ZulipAutoplay<CR>" },
            { keys.check, "test player, microphone and service", voice.check },
            { keys.log, "send the voice log to the server", voice.send_log },
            { keys.device, "choose the microphone", function() voice.choose_device() end },
        }
        for _, action in ipairs(actions) do
            if action[1] then
                vim.keymap.set("n", action[1], action[3], { buffer = buf, desc = "Zulip voice: " .. action[2] })
            end
        end
        for _, action in ipairs(rare) do
            if action[1] then
                vim.keymap.set("n", keys.prefix .. action[1], action[3], { buffer = buf, desc = "Zulip voice: " .. action[2] })
            end
        end
        local state = require("zulip.state")
        if state.handsfree and not require("zulip.handsfree").on then
            state.handsfree = false
            vim.schedule(function()
                require("zulip.handsfree").toggle(handsfree_ctx)
            end)
        end
        pcall(function()
            require("which-key").add({ { keys.prefix, group = "Zulip voice (rare)", buffer = buf } })
        end)
        if keys.interrupt then
            vim.keymap.set("n", keys.interrupt, player.stop, { buffer = buf, desc = "Zulip voice: stop reading" })
        end
        player.attach(buf)
        vim.keymap.set("n", "R", function()
            M.load(conversation)
        end, { buffer = buf, desc = "Reload" })
        vim.api.nvim_create_autocmd("BufLeave", {
            buffer = buf,
            callback = function()
                local shown = M.shown[buf]
                if shown then
                    local view = vim.fn.winsaveview()
                    M.left[conversation.key] = {
                        lnum = view.lnum,
                        topline = view.topline,
                        at = span_at(shown.spans, view.lnum),
                        top = span_at(shown.spans, view.topline),
                    }
                end
            end,
        })
        vim.api.nvim_create_autocmd("CursorMoved", {
            buffer = buf,
            callback = function()
                M.mark_seen(buf, vim.api.nvim_get_current_win())
            end,
        })
    end
    if vim.bo.filetype == "zulip" then
        local sidebar = vim.api.nvim_get_current_win()
        vim.cmd("wincmd p")
        if vim.api.nvim_get_current_win() == sidebar then
            vim.cmd("rightbelow vertical new")
            vim.api.nvim_win_set_width(sidebar, config.sidebar_width)
        end
    end
    vim.api.nvim_win_set_buf(0, buf)
    M.entering[buf] = vim.api.nvim_get_current_win()
    M.load(conversation)
end

return M

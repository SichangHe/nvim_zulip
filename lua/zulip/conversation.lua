--- One conversation: a Markdown buffer of its messages, and a compose buffer for the reply.
local api = require("zulip.api")
local config = require("zulip.config")
local loading, pending, retries = {}, {}, {}

local M = {
    --- Message buffer of each conversation key.
    bufs = {},
    --- Compose buffer of each conversation key.
    composes = {},
    --- Per message buffer: `spans`, each shown message's `{ id, first, last }` rows, and `unread`, a set of message IDs.
    shown = {},
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
function M.render(messages, new_id)
    local lines, new_row, spans = {}, nil, {}
    for _, message in ipairs(messages) do
        if message.id == new_id then
            lines[#lines + 1] = "════════ new messages ════════"
            new_row = #lines
        end
        local first = #lines + 1
        lines[#lines + 1] = ("## %s · %s"):format(message.sender_full_name, os.date("%Y-%m-%d %H:%M", message.timestamp))
        lines[#lines + 1] = ""
        vim.list_extend(lines, vim.split(message.content, "\n"))
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

-- 🧑 "Make the nvim Zulip plugin mark \"read\" only when cursor reaches the bottom of the message"
--- Mark read, when `config.mark_read`, each unread message of `buf` whose last row the cursor in `win` has reached.
function M.mark_seen(buf, win)
    local shown = M.shown[buf]
    if not (config.mark_read and shown) then
        return
    end
    local row, seen = vim.api.nvim_win_get_cursor(win)[1], {}
    for _, span in ipairs(shown.spans) do
        if span.last <= row and shown.unread[span.id] then
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
        for _, message in ipairs(messages) do
            if not vim.list_contains(message.flags, "read") then
                unread[#unread + 1] = message.id
                unread_set[message.id] = true
            end
        end
        -- 🧑 "Can't tell where new messages start"
        -- Marking read clears the unread flags, so the marker's message is kept across reloads.
        vim.b[buf].zulip_new_id = unread[1] or vim.b[buf].zulip_new_id
        local lines, new_row, spans = M.render(messages, vim.b[buf].zulip_new_id)
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.b[buf].zulip_newest_id = #messages > 0 and messages[#messages].id or 0
        M.shown[buf] = { spans = spans, unread = unread_set }
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
                vim.api.nvim_win_set_cursor(win, { unread[1] and new_row or #lines, 0 })
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
        vim.keymap.set("n", "<CR>", "<Cmd>write<CR>", { buffer = buf, desc = "Send" })
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

--- Show `conversation` in the window beside the sidebar and load its messages.
function M.open(conversation)
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
        vim.keymap.set("n", "r", function()
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
    local sidebar = vim.api.nvim_get_current_win()
    vim.cmd("wincmd p")
    if vim.api.nvim_get_current_win() == sidebar then
        vim.cmd("rightbelow vertical new")
        vim.api.nvim_win_set_width(sidebar, config.sidebar_width)
    end
    vim.api.nvim_win_set_buf(0, buf)
    M.entering[buf] = vim.api.nvim_get_current_win()
    M.load(conversation)
end

return M

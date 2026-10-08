--- One conversation: a Markdown buffer of its messages, and a compose buffer for the reply.
local api = require("zulip.api")
local config = require("zulip.config")

local M = {
    --- Message buffer of each conversation key.
    bufs = {},
    --- Compose buffer of each conversation key.
    composes = {},
}

local function fail(err)
    vim.notify("zulip: " .. err, vim.log.levels.ERROR)
end

local function valid(buf)
    return buf and vim.api.nvim_buf_is_valid(buf)
end

--- Buffer lines for `messages`: a heading with sender and local time, then the Markdown as written.
function M.render(messages)
    local lines = {}
    for _, message in ipairs(messages) do
        lines[#lines + 1] = ("## %s · %s"):format(message.sender_full_name, os.date("%Y-%m-%d %H:%M", message.timestamp))
        lines[#lines + 1] = ""
        vim.list_extend(lines, vim.split(message.content, "\n"))
        lines[#lines + 1] = ""
    end
    return lines
end

--- Each of `lines` as a Markdown quote, then an empty line to write on.
function M.quote(lines)
    local quoted = vim.tbl_map(function(line)
        return line == "" and ">" or "> " .. line
    end, lines)
    quoted[#quoted + 1] = ""
    return quoted
end

--- Fetch the conversation's newest messages into its buffer,
--- move each cursor that was on the last line to the new last line,
--- and mark the messages read when `config.mark_read`.
function M.load(conversation)
    local buf = M.bufs[conversation.key]
    local narrow = conversation.stream_id
            and { { operator = "channel", operand = conversation.stream_id }, { operator = "topic", operand = conversation.topic } }
        or { { operator = "dm", operand = conversation.user_ids } }
    local params = { narrow = narrow, anchor = "newest", num_before = config.n_shown, num_after = 0, apply_markdown = false }
    api.request("GET", "/messages", params, function(err, reply)
        if err then
            return fail(err)
        end
        if not valid(buf) then
            return
        end
        local messages = reply.messages
        local at_end = vim.tbl_filter(function(win)
            return vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf)
        end, vim.fn.win_findbuf(buf))
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.render(messages))
        vim.bo[buf].modifiable = false
        vim.b[buf].zulip_newest_id = #messages > 0 and messages[#messages].id or 0
        for _, win in ipairs(at_end) do
            vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
        end
        local unread = {}
        for _, message in ipairs(messages) do
            if not vim.list_contains(message.flags, "read") then
                unread[#unread + 1] = message.id
            end
        end
        if config.mark_read and #unread > 0 then
            api.request("POST", "/messages/flags", { messages = unread, op = "add", flag = "read" }, function(flag_err)
                if flag_err then
                    fail(flag_err)
                end
            end)
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
    end
    local sidebar = vim.api.nvim_get_current_win()
    vim.cmd("wincmd p")
    if vim.api.nvim_get_current_win() == sidebar then
        vim.cmd("rightbelow vertical new")
        vim.api.nvim_win_set_width(sidebar, config.sidebar_width)
    end
    vim.api.nvim_win_set_buf(0, buf)
    M.load(conversation)
end

return M

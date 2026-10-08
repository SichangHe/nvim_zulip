--- The conversation list: recent conversations, newest first, with unread counts.
local api = require("zulip.api")
local config = require("zulip.config")

local M = {
    buf = nil,
    --- Conversation shown on each sidebar line.
    rows = {},
    timer = nil,
    --- Whether a refresh awaits its reply; the timer skips a tick meanwhile.
    refreshing = false,
}

--- Group `messages`, oldest first, into conversations, newest first.
--- A conversation is a channel topic `{ stream_id, topic }` or a direct message `{ user_ids }`,
--- plus `key`, `name`, `newest_id` and `n_unread`.
--- Topics differing only in case are one conversation, as on the server.
function M.conversations(messages, my_id)
    local by_key, list = {}, {}
    for _, message in ipairs(messages) do
        local fresh
        if message.type == "stream" then
            fresh = {
                key = message.stream_id .. "/" .. message.subject:lower(),
                name = message.display_recipient .. " > " .. message.subject,
                stream_id = message.stream_id,
                topic = message.subject,
            }
        else
            local user_ids, names = {}, {}
            for _, user in ipairs(message.display_recipient) do
                user_ids[#user_ids + 1] = user.id
                if user.id ~= my_id then
                    names[#names + 1] = user.full_name
                end
            end
            table.sort(user_ids)
            table.sort(names)
            fresh = {
                key = table.concat(user_ids, ","),
                name = #names > 0 and table.concat(names, ", ") or message.sender_full_name,
                user_ids = user_ids,
            }
        end
        local conversation = by_key[fresh.key]
        if not conversation then
            conversation = fresh
            conversation.n_unread = 0
            by_key[fresh.key] = conversation
            list[#list + 1] = conversation
        end
        conversation.newest_id = message.id
        if not vim.list_contains(message.flags, "read") then
            conversation.n_unread = conversation.n_unread + 1
        end
    end
    table.sort(list, function(a, b)
        return a.newest_id > b.newest_id
    end)
    return list
end

local function fail(err)
    vim.notify("zulip: " .. err, vim.log.levels.ERROR)
end

local function window()
    local win = M.buf and vim.fn.bufwinid(M.buf) or -1
    return win ~= -1 and win or nil
end

--- Redraw the list, keeping the cursor on the conversation it was on.
local function render(conversations)
    local win = window()
    local at_cursor = win and M.rows[vim.api.nvim_win_get_cursor(win)[1]]
    local lines = {}
    M.rows = conversations
    for row, conversation in ipairs(conversations) do
        lines[row] = ("%3s %s"):format(conversation.n_unread > 0 and conversation.n_unread or "", conversation.name)
    end
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false
    for row, conversation in ipairs(conversations) do
        if at_cursor and conversation.key == at_cursor.key then
            vim.api.nvim_win_set_cursor(win, { row, 0 })
        end
    end
end

--- Fetch the newest messages, redraw the list,
--- and reload each displayed conversation that got a new message.
function M.refresh()
    if M.refreshing then
        return
    end
    M.refreshing = true
    api.connect(config.zuliprc, function(err)
        if err then
            M.refreshing = false
            M.timer:stop()
            return fail(err)
        end
        local params = { anchor = "newest", num_before = config.n_recent, num_after = 0, apply_markdown = false }
        api.request("GET", "/messages", params, function(get_err, reply)
            M.refreshing = false
            if not vim.api.nvim_buf_is_valid(M.buf) then
                return M.timer:stop()
            end
            if get_err then
                return fail(get_err)
            end
            local conversations = M.conversations(reply.messages, api.account.user_id)
            render(conversations)
            require("zulip.conversation").reload_changed(conversations)
        end)
    end)
end

local function create_buffer()
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.buf].filetype = "zulip"
    vim.bo[M.buf].modifiable = false
    vim.api.nvim_buf_call(M.buf, function()
        vim.cmd([[syntax match Title /^ *\d\+ .*$/]])
    end)
    vim.keymap.set("n", "<CR>", function()
        local conversation = M.rows[vim.api.nvim_win_get_cursor(0)[1]]
        if conversation then
            require("zulip.conversation").open(conversation)
        end
    end, { buffer = M.buf, desc = "Open the conversation" })
    vim.keymap.set("n", "r", M.refresh, { buffer = M.buf, desc = "Refresh" })
    vim.keymap.set("n", "q", M.toggle, { buffer = M.buf, desc = "Hide the sidebar" })
end

--- Show the sidebar, or hide it when shown.
function M.toggle()
    local win = window()
    if win then
        M.timer:stop()
        if #vim.api.nvim_tabpage_list_wins(0) == 1 then
            vim.cmd("vertical new")
        end
        return vim.api.nvim_win_close(win, false)
    end
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        create_buffer()
    end
    vim.cmd(("topleft vertical %dsplit"):format(config.sidebar_width))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, M.buf)
    for option, value in pairs({ winfixwidth = true, number = false, relativenumber = false, cursorline = true, wrap = false }) do
        vim.wo[win][0][option] = value
    end
    M.timer = M.timer or vim.uv.new_timer()
    M.timer:start(0, config.refresh_ms, vim.schedule_wrap(M.refresh))
end

return M

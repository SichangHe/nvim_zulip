--- Run with `ZULIPRC=path nvim -l tests/run.lua` against a live Zulip server.
--- Sends one direct message from the account to itself. Marks nothing read.
--- Prints only failures; exits non-zero when any check fails.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api, sidebar, conversation = require("zulip.api"), require("zulip.sidebar"), require("zulip.conversation")
local failures = 0

local function check(name, got, want)
    if not vim.deep_equal(got, want) then
        failures = failures + 1
        print(("FAIL %s\n  got  %s\n  want %s"):format(name, vim.inspect(got), vim.inspect(want)))
    end
end

check("parse_zuliprc", { api.parse_zuliprc({ "[api]", "email=a@b.c", "key = k1", "site=https://x.zulipchat.com/" }) }, { { email = "a@b.c", key = "k1", site = "https://x.zulipchat.com" } })
check("parse_zuliprc incomplete", { api.parse_zuliprc({ "email=a@b.c" }) }, { nil, "no `key`" })
local me, other = { id = 1, full_name = "Me" }, { id = 2, full_name = "Other" }
check("conversations", sidebar.conversations({
    { id = 1, type = "stream", stream_id = 7, subject = "t", display_recipient = "s", flags = { "read" } },
    { id = 2, type = "private", display_recipient = { other, me }, flags = {} },
    { id = 3, type = "stream", stream_id = 7, subject = "t", display_recipient = "s", flags = {} },
}, 1), {
    { key = "7/t", name = "s > t", stream_id = 7, topic = "t", newest_id = 3, n_unread = 1 },
    { key = "1,2", name = "Other", user_ids = { 1, 2 }, newest_id = 2, n_unread = 1 },
})
check("quote", conversation.quote({ "a", "", "b" }), { "> a", ">", "> b", "" })
check("render", vim.list_slice(conversation.render({ { sender_full_name = "Me", timestamp = 0, content = "a\nb" } }), 2), { "", "a", "b", "" })

require("zulip").setup({ zuliprc = vim.env.ZULIPRC, mark_read = false })
vim.cmd("Zulip")
check("sidebar fills", vim.wait(20000, function()
    return #sidebar.rows > 0
end), true)
check("sidebar line", vim.api.nvim_buf_get_lines(sidebar.buf, 0, 1, false)[1]:sub(5), sidebar.rows[1] and sidebar.rows[1].name)

local function text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local id = api.account.user_id
local myself = { key = tostring(id), name = "myself", user_ids = { id } }
local marker = "nvim_zulip test " .. vim.uv.hrtime()
conversation.open(myself)
check("conversation beside sidebar", #vim.api.nvim_tabpage_list_wins(0), 2)
vim.cmd("normal \r")
check("compose opens", vim.bo.buftype, "acwrite")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { marker, "", "second paragraph" })
vim.cmd("normal \r")
check("sent message shows", vim.wait(20000, function()
    return text(conversation.bufs[myself.key]):find(marker .. "\n\nsecond paragraph", 1, true) ~= nil
end), true)
check("compose closes", vim.api.nvim_buf_is_valid(conversation.composes[myself.key]), false)
vim.api.nvim_set_current_win(vim.fn.bufwinid(conversation.bufs[myself.key]))
vim.cmd("normal ggVj\r")
check("selection is quoted", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("^> ## .+ · %d+%-%d+%-%d+ %d+:%d+$") ~= nil, true)
vim.cmd("bwipeout!")
sidebar.refresh()
check("sidebar lists the conversation", vim.wait(20000, function()
    return sidebar.rows[1] and sidebar.rows[1].key == myself.key
end), true)
vim.api.nvim_set_current_win(vim.fn.bufwinid(sidebar.buf))
vim.cmd("Zulip")
check("sidebar hides", vim.fn.bufwinid(sidebar.buf), -1)
os.exit(failures == 0 and 0 or 1)

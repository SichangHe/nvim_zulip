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
check("tag", { conversation.tag("[nvim_omnigent]"), conversation.tag("nvim_omnigent.md:"), conversation.tag("a/b"), conversation.tag("x.y") }, { "nvim_omnigent", "nvim_omnigent", nil, nil })
check("render prepends site", conversation.render({ { id = 1, sender_full_name = "Me", timestamp = 0, content = "[a.pdf](/user_uploads/2/a.pdf) [w](https://x.y/z)" } }, nil, "https://s.zulipchat.com")[3], "[a.pdf](https://s.zulipchat.com/user_uploads/2/a.pdf) [w](https://x.y/z)")
check("uploads with site", require("zulip.viz").uploads("[a.pdf](https://s.zulipchat.com/user_uploads/2/a.PDF)"), { { path = "/user_uploads/2/a.PDF", ext = "pdf" } })
check("quote", conversation.quote({ "a", "", "b" }), { "> a", ">", "> b", "" })
check("render marks new", { conversation.render({ { id = 1, sender_full_name = "Me", timestamp = 0, content = "a" }, { id = 2, sender_full_name = "Me", timestamp = 0, content = "b" } }, 2) }, {
    { "## Me · " .. os.date("%Y-%m-%d %H:%M", 0), "", "a", "", "════════ new messages ════════", "## Me · " .. os.date("%Y-%m-%d %H:%M", 0), "", "b", "" },
    5,
    { { id = 1, first = 1, last = 3 }, { id = 2, first = 6, last = 8 } },
})
check("render", vim.list_slice(conversation.render({ { id = 1, sender_full_name = "Me", timestamp = 0, content = "a\nb" } }), 2), { "", "a", "b", "" })

-- Offline: a stand-in server answers `/messages` from `served` and records read flags.
local served, flagged, real_request = {}, {}, api.request
api.request = function(method, path, params, callback)
    if path == "/messages" and method == "GET" then
        callback(nil, { messages = vim.deepcopy(served) })
    elseif path == "/messages/flags" then
        vim.list_extend(flagged, params.messages)
        callback(nil, {})
    end
end
local function message(id, read, content)
    return { id = id, sender_full_name = "P", timestamp = 0, content = content or "line1\nline2", flags = read and { "read" } or {} }
end
for id = 1, 30 do
    served[#served + 1] = message(id, id <= 20)
end
local offline = { key = "offline", name = "offline", user_ids = { 99 } }
conversation.open(offline)
local obuf, owin = conversation.bufs[offline.key], vim.fn.bufwinid(conversation.bufs[offline.key])
check("first load: cursor on the new mark", vim.api.nvim_get_current_line(), "════════ new messages ════════")
check("nothing read before the cursor reaches a message's end", flagged, {})
local spans = conversation.shown[obuf].spans
vim.api.nvim_win_set_cursor(owin, { spans[21].last - 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = obuf })
check("not read above its last line", flagged, {})
vim.api.nvim_win_set_cursor(owin, { spans[22].last, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = obuf })
check("read up to the message whose last line the cursor reached", flagged, { 21, 22 })
local before_line = vim.api.nvim_get_current_line()
local before_row = vim.api.nvim_win_get_cursor(owin)[1]
table.remove(served, 1)
served[#served + 1] = message(31, false)
conversation.load(offline)
check("new message: cursor stays on the same text", vim.api.nvim_get_current_line(), before_line)
check("new message: no read without reaching it", vim.list_contains(flagged, 31), false)
check("first message dropped: cursor moves up with its message", vim.api.nvim_win_get_cursor(owin)[1], before_row - 5)
local kept_row = vim.api.nvim_win_get_cursor(owin)[1]
local elsewhere = vim.api.nvim_create_buf(true, true)
vim.api.nvim_set_current_win(owin)
vim.api.nvim_win_set_buf(owin, elsewhere)
conversation.open(offline)
check("reentering resumes at the cursor left there", vim.api.nvim_win_get_cursor(vim.fn.bufwinid(obuf))[1], kept_row)
vim.cmd("bwipeout! " .. obuf)
conversation.open(offline)
check("reopening a closed thread resumes there too", vim.api.nvim_win_get_cursor(vim.fn.bufwinid(conversation.bufs[offline.key]))[1], kept_row)
check("switch line is hidden", conversation.render({ message(1, true, "text\n[switch: Target.md]") }, nil)[3], "text")
local target = { key = "5/target", name = "s > Target", stream_id = 5, topic = "Target" }
local player, rows = require("zulip.player"), sidebar.rows
sidebar.rows = { target }
local received = { message(40, false, "bye\n[switch: Target.md]") }
player.run = {}
conversation.switch_to(conversation.bufs[offline.key], received)
check("switch waits for the reading", vim.api.nvim_get_current_buf(), conversation.bufs[offline.key])
player.run = nil
player.on_idle()
check("switch opens the task's conversation", vim.api.nvim_get_current_buf(), conversation.bufs[target.key])
sidebar.rows = rows
-- real key presses reach the voice actions; selection and motion keys stay unmapped
conversation.open(offline)
vim.api.nvim_set_current_buf(conversation.bufs[offline.key])
local calls, real = {}, {}
api.account = api.account or { user_id = 0 }
for _, name in ipairs({ "step_chunk", "step_message", "change_speed", "stop", "toggle_pause", "read" }) do
    real[name] = player[name]
    player[name] = function(...) calls[#calls + 1] = name .. ":" .. tostring((...)) end
end
local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "x", false) end
for _, keys in ipairs({ "o", "O", "a", "A", "s", "S", "x", "i", "r" }) do press(keys) end
check("voice keys act", calls, { "step_chunk:1", "step_chunk:-1", "step_message:1", "step_message:-1", "change_speed:0.1", "change_speed:-0.1", "stop:nil", "read:" .. conversation.bufs[offline.key], "read:" .. conversation.bufs[offline.key] })
for _, key in ipairs({ "v", "V", "y", "[", "]", "{", "}", "f", "d" }) do
    check("key " .. key .. " stays a motion/selection key", vim.fn.maparg(key, "n", false, true).buffer ~= 1, true)
end
for name, fn in pairs(real) do player[name] = fn end
vim.cmd("bwipeout! " .. conversation.bufs[target.key])
vim.cmd("bwipeout! " .. conversation.bufs[offline.key])
api.request = real_request
if not vim.env.ZULIPRC then
    os.exit(failures == 0 and 0 or 1)
end

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
vim.cmd("normal gg")
vim.fn.search("^## ", "cW")
vim.cmd("normal Vj\r")
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

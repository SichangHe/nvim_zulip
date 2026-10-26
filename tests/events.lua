--- Exercise the real curl transport against a local HTTP event server; sends nothing to Zulip.
--- Run with `nvim -l tests/events.lua`; only failures are printed.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api, sidebar = require("zulip.api"), require("zulip.sidebar")
local config = require("zulip.config")
config.refresh_ms, config.mark_read = 20, false
local failures = 0
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local function check(name, got, want)
    if not vim.deep_equal(got, want) then
        failures = failures + 1
        print("FAIL " .. name .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
    end
end
local function await(name, predicate)
    check(name, vim.wait(3000, predicate, 5), true)
end
local server = vim.uv.new_tcp()
assert(server:bind("127.0.0.1", 0))
local peers, polls, registrations, snapshots, deleted = {}, {}, 0, 0, 0
local event_id, newest, read = 0, 1, false
local held_snapshot, hold_snapshot, held_register, hold_register
local fail_conversation = false
local function respond(peer, reply)
    if peer:is_closing() then
        return
    end
    local body = vim.json.encode(reply)
    peer:write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body, function()
        if not peer:is_closing() then
            peer:close()
        end
    end)
end
local function messages()
    local result = {}
    for id = 1, newest do
        result[#result + 1] = {
            id = id, type = "stream", stream_id = 7, subject = "topic", display_recipient = "channel",
            sender_full_name = "Sender", timestamp = 0, content = "message " .. id,
            flags = read and { "read" } or {},
        }
    end
    return { result = "success", messages = result }
end
local function route(peer, method, path)
    if path == "/api/v1/register" then
        registrations = registrations + 1
        local reply = { result = "success", queue_id = "queue" .. registrations, last_event_id = event_id, event_queue_longpoll_timeout_seconds = 60 }
        if hold_register then
            held_register = function() respond(peer, reply) end
        else
            respond(peer, reply)
        end
    elseif path:match("^/api/v1/events") and method == "GET" then
        check("acknowledge received events", tonumber(path:match("last_event_id=(%d+)")), event_id)
        polls[#polls + 1] = peer
    elseif path == "/api/v1/events" and method == "DELETE" then
        deleted = deleted + 1
        respond(peer, { result = "success" })
    elseif path:match("^/api/v1/messages") then
        snapshots = snapshots + 1
        if fail_conversation and path:find("narrow=", 1, true) then
            fail_conversation = false
            return respond(peer, { result = "error", msg = "temporary conversation failure" })
        end
        local reply = messages()
        if hold_snapshot then
            held_snapshot = function() respond(peer, reply) end
        else
            respond(peer, reply)
        end
    else
        error("unexpected request: " .. method .. " " .. path)
    end
end
assert(server:listen(32, function(err)
    assert(not err, err)
    local peer = vim.uv.new_tcp()
    assert(server:accept(peer))
    peers[#peers + 1] = peer
    local received = ""
    peer:read_start(vim.schedule_wrap(function(read_err, data)
        assert(not read_err, read_err)
        if not data then
            if not peer:is_closing() then peer:close() end
            return
        end
        received = received .. data
        local boundary = received:find("\r\n\r\n", 1, true)
        local length = tonumber(received:lower():match("content%-length: (%d+)")) or 0
        if boundary and #received >= boundary + 3 + length then
            peer:read_stop()
            local method, path = received:match("^(%u+) (%S+)")
            route(peer, method, path)
        end
    end))
end))
api.account = { email = "test", key = "test", user_id = 1, site = "http://127.0.0.1:" .. server:getsockname().port }
local function event(kind)
    event_id = event_id + 1
    local peer = table.remove(polls, 1)
    assert(peer, "no pending poll")
    respond(peer, { result = "success", events = { { id = event_id, type = kind } } })
    await("next long poll", function() return #polls > 0 end)
end
sidebar.toggle()
await("registered snapshot", function() return #sidebar.rows == 1 and #polls == 1 end)
check("register once", registrations, 1)
local idle_snapshots = snapshots
event("heartbeat")
check("heartbeat does not fetch messages", snapshots, idle_snapshots)
require("zulip.conversation").open(sidebar.rows[1])
local conversation = require("zulip.conversation")
local buf = conversation.bufs["7/topic"]
await("conversation loads", function() return vim.b[buf].zulip_newest_id == 1 end)
local win = vim.fn.bufwinid(buf)
vim.api.nvim_win_set_cursor(win, { 3, 0 })
local cursor = vim.api.nvim_win_get_cursor(win)
newest = 2
event("message")
await("message reaches conversation", function() return vim.b[buf].zulip_newest_id == 2 end)
check("cursor preserved", vim.api.nvim_win_get_cursor(win), cursor)
read = true
event("update_message_flags")
await("read flags update sidebar", function() return sidebar.rows[1].n_unread == 0 end)
hold_snapshot = true
sidebar.refresh()
await("snapshot held", function() return held_snapshot ~= nil end)
newest = 3
event("message")
hold_snapshot = false
held_snapshot()
await("event during snapshot is not lost", function() return sidebar.rows[1].newest_id == 3 end)
respond(table.remove(polls, 1), { result = "error", code = "BAD_EVENT_QUEUE_ID", msg = "expired queue" })
newest = 4
await("reconnect refreshes missed messages", function() return registrations == 2 and sidebar.rows[1].newest_id == 4 and #polls == 1 end)
check("reconnect reports the failure once", notices, { "zulip: expired queue; reconnecting" })
await("conversation catches up after reconnect", function() return vim.b[buf].zulip_newest_id == 4 end)
fail_conversation, newest = true, 5
event("message")
await("failed conversation refresh retries without another event", function() return vim.b[buf].zulip_newest_id == 5 end)
check("conversation failure reported", notices[2], "zulip: temporary conversation failure")
sidebar.toggle()
await("queue released on hide", function() return deleted >= 2 end)
polls = {}
hold_register = true
sidebar.toggle()
await("registration held", function() return held_register ~= nil end)
sidebar.toggle()
local before_deleted, before_snapshots = deleted, snapshots
held_register()
await("late registration released", function() return deleted > before_deleted end)
check("late registration does not refresh", snapshots, before_snapshots)
for _, peer in ipairs(peers) do
    if not peer:is_closing() then peer:close() end
end
server:close()
os.exit(failures == 0 and 0 or 1)

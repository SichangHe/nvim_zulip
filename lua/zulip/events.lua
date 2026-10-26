--- One event queue while the sidebar is visible; reconnects after request failures.
local api = require("zulip.api")
local config = require("zulip.config")
local M = {}
local current

local function release(queue_id)
    if queue_id then
        api.request("DELETE", "/events", { queue_id = queue_id }, function() end)
    end
end

--- Cancel the outstanding poll and retry timer; callbacks from this session become inert.
function M.stop()
    local session = current
    current = nil
    if not session then
        return
    end
    if session.timer then
        session.timer:stop()
        session.timer:close()
    end
    if session.poll then
        session.poll:kill(15)
    end
    release(session.queue_id)
end

-- 🧑 "Can it be push-based"
--- Register before refreshing so messages arriving during the snapshot remain queued.
function M.start(on_change)
    M.stop()
    local session = { retry_ms = config.refresh_ms }
    current = session
    local register, poll
    local function retry(err)
        release(session.queue_id)
        session.queue_id = nil
        if not session.timer then
            session.timer = vim.uv.new_timer()
            vim.notify("zulip: " .. err .. "; reconnecting", vim.log.levels.WARN)
        end
        session.timer:start(session.retry_ms, 0, vim.schedule_wrap(function()
            if current == session then
                register()
            end
        end))
        session.retry_ms = math.min(session.retry_ms * 2, 30000)
    end
    poll = function()
        session.poll = api.request("GET", "/events", {
            queue_id = session.queue_id,
            last_event_id = session.last_event_id,
            dont_block = false,
        }, function(err, reply)
            if current ~= session then
                return
            end
            session.poll = nil
            if err then
                return retry(err)
            end
            session.retry_ms = config.refresh_ms
            local changed = false
            for _, event in ipairs(reply.events) do
                if event.id > session.last_event_id then
                    session.last_event_id = event.id
                    changed = changed or event.type ~= "heartbeat"
                end
            end
            if changed then
                on_change()
            end
            poll()
        end, session.timeout_seconds)
    end
    register = function()
        api.connect(config.zuliprc, function(err)
            if current ~= session then
                return
            end
            if err then
                return retry(err)
            end
            api.request("POST", "/register", {
                event_types = { "message", "update_message_flags" },
                fetch_event_types = {},
                apply_markdown = false,
            }, function(register_err, reply)
                if current ~= session then
                    return release(reply and reply.queue_id)
                end
                if register_err then
                    return retry(register_err)
                end
                session.queue_id, session.last_event_id = reply.queue_id, reply.last_event_id
                session.timeout_seconds = (reply.event_queue_longpoll_timeout_seconds or 90) + 10
                on_change()
                poll()
            end)
        end)
    end
    register()
end

return M

--- Desktop notifications for urgent messages (manager request: "The nvim zulip plugin should create desktop notifications
--- using oscscript or something for urgent messages"). Urgent = a new message from someone else in a channel of `notify.channels`.
local config = require("zulip.config")
local M = {}

--- The desktop notification command for `title` and `body`, or nil when no notifier is available.
local function command(title, body)
    if vim.fn.has("mac") == 1 then
        local function q(s)
            return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
        end
        return { "osascript", "-e", ("display notification %s with title %s sound name \"Glass\""):format(q(body), q(title)) }
    elseif vim.fn.executable("notify-send") == 1 then
        return { "notify-send", "-u", "critical", title, body }
    end
end

function M.show(title, body)
    local cmd = command(title, body:gsub("%s+", " "):sub(1, 200))
    if cmd then
        vim.system(cmd)
    end
    vim.schedule(function()
        vim.notify(title .. ": " .. body, vim.log.levels.WARN)
    end)
end

--- Whether `message` should notify: a channel message in `notify.channels` sent by someone other than this account.
function M.wanted(message, my_id)
    if message.type ~= "stream" or message.sender_id == my_id then
        return false
    end
    return vim.tbl_contains(config.notify.channels, message.display_recipient)
end

--- Listen for urgent messages on their own event queue, independent of the sidebar.
function M.start()
    if not config.notify.enabled or vim.fn.filereadable(vim.fn.expand(config.zuliprc)) == 0 then
        return
    end
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            require("zulip.events").stop("notify")
        end,
    })
    local api = require("zulip.api")
    require("zulip.events").start(function(events)
        for _, event in ipairs(events) do
            local message = event.message
            if event.type == "message" and message and M.wanted(message, api.account and api.account.user_id) then
                M.show(("Zulip %s > %s"):format(message.display_recipient, message.subject), message.sender_full_name .. ": " .. message.content)
            end
        end
    end, { name = "notify", event_types = { "message" } })
end

return M

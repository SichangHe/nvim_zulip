--- Calls to the Zulip server. Every call is asynchronous;
--- `on_done(err, result)` runs on the main loop with `err` a string or `nil`.
local M = {
    --- `{ email, key, site, user_id }` once `connect` succeeded.
    account = nil,
}

--- Parse the lines of a `zuliprc` file; returns the account, or `nil` and what is missing.
function M.parse_zuliprc(lines)
    local account = {}
    for _, line in ipairs(lines) do
        local name, value = line:match("^%s*(%w+)%s*=%s*(.-)%s*$")
        if name then
            account[name] = value
        end
    end
    for _, name in ipairs({ "email", "key", "site" }) do
        if not account[name] then
            return nil, "no `" .. name .. "`"
        end
    end
    account.site = account.site:gsub("/+$", "")
    return account
end

--- Send an HTTP request to the Zulip API as `account`; the result is the decoded JSON reply.
--- Values of `params` that are not strings are sent as JSON.
--- The key goes to `curl` on standard input, so other users cannot see it in the process list.
local function request(account, method, path, params, on_done)
    local cmd = { "curl", "-sS", "--max-time", "30", "-K", "-", "-X", method, account.site .. "/api/v1" .. path }
    if method == "GET" then
        cmd[#cmd + 1] = "-G"
    end
    for name, value in pairs(params) do
        vim.list_extend(cmd, { "--data-urlencode", name .. "=" .. (type(value) == "string" and value or vim.json.encode(value)) })
    end
    local stdin = ('user = "%s:%s"\n'):format(account.email, account.key)
    vim.system(cmd, { text = true, stdin = stdin }, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
            return on_done(vim.trim(result.stderr))
        end
        local ok, reply = pcall(vim.json.decode, result.stdout, { luanil = { object = true, array = true } })
        if not ok then
            return on_done(reply)
        end
        if reply.result ~= "success" then
            return on_done(reply.msg)
        end
        on_done(nil, reply)
    end))
end

--- Read `zuliprc` and ask the server who the account is; later calls reuse the answer.
function M.connect(zuliprc, on_done)
    if M.account then
        return on_done()
    end
    local readable, lines = pcall(vim.fn.readfile, vim.fn.expand(zuliprc))
    if not readable then
        return on_done("cannot read " .. zuliprc)
    end
    local account, missing = M.parse_zuliprc(lines)
    if not account then
        return on_done(zuliprc .. ": " .. missing)
    end
    request(account, "GET", "/users/me", {}, function(err, me)
        if err then
            return on_done(err)
        end
        account.user_id = me.user_id
        M.account = account
        on_done()
    end)
end

--- Send a request as the connected account.
function M.request(method, path, params, on_done)
    request(M.account, method, path, params, on_done)
end

return M

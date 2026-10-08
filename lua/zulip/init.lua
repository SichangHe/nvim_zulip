--- Entry point: options, the `:Zulip` command, and global mappings.
local config = require("zulip.config")

local M = {}

--- Merge `opts` into the options, then define the command and mappings.
function M.setup(opts)
    for key, value in pairs(vim.tbl_deep_extend("force", config, opts or {})) do
        config[key] = value
    end
    local toggle = require("zulip.sidebar").toggle
    vim.api.nvim_create_user_command("Zulip", toggle, {})
    if config.keys.toggle then
        vim.keymap.set("n", config.keys.toggle, toggle, { desc = "Zulip: show or hide conversations" })
    end
end

return M

--- Voice settings kept across restarts in `stdpath("state")/zulip_voice.json`; options given to `setup` win.
local config = require("zulip.config")
local M = {
    --- Whether voice control was on when last saved.
    handsfree = false,
}
local FIELDS = { "autoplay", "speed", "follow", "device", "start_word", "end_word", "long_silence_s", "empty_s", "pause_ms", "silence_rms" }
--- The settings file.
function M.path()
    return vim.fs.joinpath(vim.fn.stdpath("state"), "zulip_voice.json")
end

--- The saved settings, `{}` when there are none or they cannot be read.
function M.load()
    local ok, lines = pcall(vim.fn.readfile, M.path())
    local decoded_ok, saved = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
    return decoded_ok and type(saved) == "table" and saved or {}
end

--- Merge the saved settings under `opts` (the user's explicit options) into `config.voice`.
function M.apply(opts)
    local saved = M.load()
    M.handsfree = saved.handsfree == true
    for _, field in ipairs(FIELDS) do
        local old_default = (field == "start_word" and saved[field] == "pause") or (field == "end_word" and (saved[field] == "over" or saved[field] == "kangaroo"))
        if saved[field] ~= nil and not old_default and not (opts and opts.voice and opts.voice[field] ~= nil) then
            config.voice[field] = saved[field]
        end
    end
    if opts and opts.voice and opts.voice.handsfree ~= nil then
        M.handsfree = opts.voice.handsfree
    end
end

--- Write the current settings; `handsfree` is whether voice control is on.
function M.save(handsfree)
    if handsfree ~= nil then
        M.handsfree = handsfree
    end
    local saved = { handsfree = M.handsfree }
    for _, field in ipairs(FIELDS) do
        saved[field] = config.voice[field]
    end
    vim.fn.mkdir(vim.fs.dirname(M.path()), "p")
    vim.fn.writefile({ vim.json.encode(saved) }, M.path())
end

return M

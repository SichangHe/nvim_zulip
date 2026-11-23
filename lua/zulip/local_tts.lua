--- Speech made on the laptop by `config.voice.local_tts` (mac_tts: Kokoro on the GPU), instead of the voice service.
-- 🧑 "on the laptop, we should just do text to speech on the laptop, so we don't have the latency"
-- One long-lived `mac-tts --lines DIR` (through `config.voice.via` when Neovim runs remotely) keeps the model loaded:
-- each text line in, one WAV path out. The WAVs of a batch are joined into one bundle shaped like the service's.
local config = require("zulip.config")
local M = {}

local engine = nil -- {proc, queue = {{text, on_path}}, buf, ready}

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    return a + b * 256
end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

--- `{fmt = fmt chunk body, data = sample bytes, bytes_per_s}` of a RIFF WAV, or nil.
function M.parse_wav(bytes)
    if #bytes < 12 or bytes:sub(1, 4) ~= "RIFF" or bytes:sub(9, 12) ~= "WAVE" then
        return nil
    end
    local i, fmt, data = 13, nil, nil
    while i + 8 <= #bytes + 1 do
        local id, size = bytes:sub(i, i + 3), u32(bytes, i + 4)
        local body = bytes:sub(i + 8, i + 7 + size)
        if id == "fmt " then
            fmt = body
        elseif id == "data" then
            data = body
        end
        i = i + 8 + size + size % 2
    end
    if not fmt or not data then
        return nil
    end
    local channels, rate, bits = u16(fmt, 3), u32(fmt, 5), u16(fmt, 15)
    return { fmt = fmt, data = data, bytes_per_s = rate * channels * bits / 8 }
end

--- One WAV from several of the same format, with each part's start in milliseconds.
function M.join_wavs(wavs)
    local parts, offsets, t = {}, {}, 0
    for _, w in ipairs(wavs) do
        table.insert(offsets, math.floor(t + 0.5))
        table.insert(parts, w.data)
        t = t + #w.data / w.bytes_per_s * 1000
    end
    local data = table.concat(parts)
    local fmt = wavs[1].fmt
    local head = "RIFF" .. le32(4 + 8 + #fmt + 8 + #data) .. "WAVE" .. "fmt " .. le32(#fmt) .. fmt .. "data" .. le32(#data)
    return head .. data, offsets, math.floor(t + 0.5)
end

local function spawn(cmd, opts, on_exit)
    return require("zulip.voice").spawn(cmd, opts, on_exit)
end

local function fail_all(why)
    local e = engine
    engine = nil
    if e then
        for _, job in ipairs(e.queue) do
            job.on_path(why)
        end
    end
end

local function dir()
    return "/tmp/nvim_zulip_tts_" .. vim.fn.getpid()
end

local function start()
    if engine then
        return engine
    end
    local e = { queue = {}, buf = "", ready = false }
    engine = e
    local cmd = vim.list_extend(vim.deepcopy(config.voice.local_tts), { "--lines", dir() })
    e.proc = spawn(cmd, {
        stdin = true,
        stdout = function(_, chunk)
            if not chunk then
                return
            end
            vim.schedule(function()
                e.buf = e.buf .. chunk
                for line in function() local l, rest = e.buf:match("^(.-)\n(.*)$"); if l then e.buf = rest end; return l end do
                    if line == "ready" then
                        e.ready = true
                    elseif line ~= "" then
                        local job = table.remove(e.queue, 1)
                        if job then
                            job.on_path(nil, line)
                        end
                    end
                end
            end)
        end,
    }, function(result)
        if engine == e then
            fail_all(("local speech engine exited (code %d): %s"):format(result.code, vim.trim(result.stderr or "")))
        end
    end)
    return e
end

--- Render one line of text on the laptop; `on_done(err, wav)`.
local function render(text, on_done)
    local e = start()
    table.insert(e.queue, {
        on_path = function(err, path)
            if err then
                return on_done(err)
            end
            spawn({ "cat", path }, { text = false }, function(result)
                if result.code ~= 0 then
                    return on_done("could not read " .. path)
                end
                spawn({ "rm", "-f", path }, {}, function() end)
                local wav = M.parse_wav(result.stdout)
                if not wav then
                    return on_done("not a WAV file: " .. path)
                end
                on_done(nil, wav)
            end)
        end,
    })
    e.proc:write(text:gsub("[\r\n]+", " ") .. "\n")
end

--- Speech for `texts` as one bundle starting at chunk `first_idx`, like `voice.tts` but made locally; `on_done(err, bundle)`.
function M.tts(texts, first_idx, on_done)
    local wavs, left, failed = {}, #texts, nil
    for i, text in ipairs(texts) do
        render(text, function(err, wav)
            failed = failed or err
            wavs[i] = wav
            left = left - 1
            if left > 0 then
                return
            end
            if failed then
                return on_done(failed)
            end
            local bytes, offsets, duration = M.join_wavs(wavs)
            on_done(nil, { texts = texts, offsetsMs = offsets, durationMs = duration, bytes = bytes, firstIdx = first_idx, arrived_ms = os.time() * 1000, id = "local" })
        end)
    end
end

--- Whether speech is made locally.
function M.enabled()
    return config.voice.local_tts ~= nil and #config.voice.local_tts > 0
end

--- Stop the engine (it is restarted on the next request).
function M.stop()
    local e = engine
    engine = nil
    if e and e.proc then
        pcall(function() e.proc:kill(15) end)
        spawn({ "rm", "-rf", dir() }, {}, function() end)
    end
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.stop })

return M

--- Speech through the voice service (`agent_managers/zulip-voice/service/protocol.md`):
--- requests go to the private channel `config.voice.channel` as the account, results come back as bot messages.
--- Audio is played and recorded by commands that may run on another machine (`config.voice.via`).
local api = require("zulip.api")
local config = require("zulip.config")
local M = {
    --- Voice channel id once looked up.
    relay_id = nil,
    --- The reading in progress: `{ items, waiting, proc }`, or `nil`.
    run = nil,
    --- The recording in progress: its process, or `nil`.
    recorder = nil,
    --- Runs once when the reading ends without being stopped.
    on_idle = nil,
}
local n_requests = 0
local MAX_CHUNK_CHARS = 240
local MAX_TTS_CHARS = 1800
local POLL_MS = 250

local function fail(err)
    vim.notify("zulip voice: " .. err, vim.log.levels.ERROR)
end

--- Run `cmd` here, or through `config.voice.via` (e.g. `ssh` to the laptop) with each argument shell-quoted.
local function spawn(cmd, opts, on_exit)
    local via = config.voice.via
    if #via > 0 then
        cmd = vim.list_extend(vim.deepcopy(via), { table.concat(vim.tbl_map(vim.fn.shellescape, cmd), " ") })
    end
    return vim.system(cmd, opts, vim.schedule_wrap(on_exit))
end

--- What a speech engine should say for Markdown `text` (same cleaning as the service's `text.mjs`).
local function speech_text(text)
    text = text:gsub("!?%[([^%]]*)%]%([^)]*%)", "%1"):gsub("https?://%S+", "link"):gsub("`([^`]*)`", "%1")
    text = text:gsub("%*%*", ""):gsub("__", ""):gsub("~~", ""):gsub("%*", "")
    for _ = 1, 2 do
        text = text:gsub("(%w)_(%w)", "%1 %2")
    end
    return vim.trim(text:gsub("^>%s?", ""):gsub("%s+", " "))
end

--- Sentence groups of at most `MAX_CHUNK_CHARS` characters (one `tts` request each) in `text`.
local function groups(text)
    local out, group = {}, ""
    for sentence in (text .. " "):gmatch("[^.!?]+[.!?]*%s+") do
        if group ~= "" and #group + #sentence > MAX_CHUNK_CHARS then
            out[#out + 1] = group
            group = ""
        end
        group = group .. sentence
    end
    out[#out + 1] = group
    return vim.tbl_map(function(chunk)
        return vim.trim(chunk):sub(1, MAX_TTS_CHARS)
    end, out)
end

--- The strings to say for a message's Markdown `content`: the `[task]` title line, `[switch: ...]` lines and code are skipped.
function M.chunks(content)
    local lines = vim.tbl_filter(function(line)
        return not line:match("^%[switch: .+%]$")
    end, vim.split(content, "\n"))
    if lines[1] and lines[1]:match("^%[[^%]]+%]") then
        table.remove(lines, 1)
    end
    local blocks, paragraph, in_code = {}, {}, false
    local function flush()
        blocks[#blocks + 1] = table.concat(paragraph, " ")
        paragraph = {}
    end
    for _, line in ipairs(lines) do
        if line:match("^%s*```") then
            flush()
            in_code = not in_code
        elseif in_code then
        elseif vim.trim(line) == "" then
            flush()
        elseif line:match("^%s*[-*+]%s") or line:match("^%s*%d+[.)]%s") or line:match("^#+%s") then
            flush()
            blocks[#blocks + 1] = line:gsub("^%s*[-*+]%s+", ""):gsub("^%s*%d+[.)]%s+", ""):gsub("^#+%s+", "")
        else
            paragraph[#paragraph + 1] = vim.trim(line)
        end
    end
    flush()
    local chunks = {}
    for _, block in ipairs(blocks) do
        local speech = speech_text(block)
        if speech:match("%w") then
            vim.list_extend(chunks, groups(speech))
        end
    end
    return chunks
end

--- Post a request for `op` with `fields`, wait for the matching result, then delete both and ack.
--- `on_done(err, result)`; the result is the service's JSON.
local function call(op, fields, on_done)
    local function send(topic, body, on_sent)
        n_requests = n_requests + 1
        body = vim.tbl_extend("force", { voice = 1, op = topic, id = ("nv_%d_%d"):format(os.time(), n_requests) }, body)
        api.request("POST", "/messages", { type = "stream", to = M.relay_id, topic = topic, content = vim.json.encode(body) }, function(err, reply)
            on_sent(err, body.id, reply and reply.id)
        end)
    end
    local function forget(message_id)
        api.request("DELETE", "/messages/" .. message_id, {}, function() end)
    end
    local function poll(id, request_message_id, deadline_ms)
        local narrow = { { operator = "channel", operand = M.relay_id }, { operator = "topic", operand = op } }
        api.request("GET", "/messages", { narrow = narrow, anchor = "newest", num_before = 30, num_after = 0, apply_markdown = false }, function(err, reply)
            local result
            for _, message in ipairs(reply and reply.messages or {}) do
                local ok, body = pcall(vim.json.decode, message.content)
                if message.sender_id ~= api.account.user_id and ok and type(body) == "table" and body.id == id then
                    result = body
                end
            end
            if not result and (err or vim.uv.now() > deadline_ms) then
                forget(request_message_id)
                return on_done(err or op .. " timed out")
            elseif not result then
                return vim.defer_fn(function()
                    poll(id, request_message_id, deadline_ms)
                end, POLL_MS)
            end
            forget(request_message_id)
            send("ack", { ids = { id } }, function(_, _, ack_message_id)
                if ack_message_id then
                    forget(ack_message_id)
                end
            end)
            on_done(result.error, result)
        end)
    end
    send(op, fields, function(err, id, message_id)
        if err then
            return on_done(err)
        end
        poll(id, message_id, vim.uv.now() + 1000 * config.voice.timeout_s)
    end)
end

--- Find the voice channel, then run `then_do`; errors go to `on_done`.
local function with_relay(on_done, then_do)
    api.connect(config.zuliprc, function(err)
        if err then
            return on_done(err)
        end
        if M.relay_id then
            return then_do()
        end
        api.request("GET", "/get_stream_id", { stream = config.voice.channel }, function(stream_err, reply)
            if stream_err then
                return on_done(("channel `%s`: %s"):format(config.voice.channel, stream_err))
            end
            M.relay_id = reply.stream_id
            then_do()
        end)
    end)
end

--- Audio bytes of `text` spoken by the service; `on_done(err, bytes)`.
function M.tts(text, on_done)
    with_relay(on_done, function()
        call("tts", { text = text }, function(err, result)
            if err then
                return on_done(err)
            end
            local url = result.audioURL:match("^/") and api.account.site .. result.audioURL or result.audioURL
            vim.system({ "curl", "-sSf", "--max-time", "60", url }, { text = false }, vim.schedule_wrap(function(download)
                if download.code ~= 0 then
                    return on_done(vim.trim(download.stderr or "download failed"))
                end
                on_done(nil, download.stdout)
            end))
        end)
    end)
end

--- Text said in the audio file `path`; `on_done(err, text)`.
function M.stt(path, on_done)
    with_relay(on_done, function()
        api.request("POST", "/user_uploads", { file = { file = path } }, function(err, upload)
            if err then
                return on_done(err)
            end
            local uri = upload.uri or upload.url
            call("stt", { uri = uri, attachment = ("[audio](%s)"):format(uri) }, function(call_err, result)
                on_done(call_err, result and result.text)
            end)
        end)
    end)
end

--- Stop reading aloud.
function M.stop()
    local run = M.run
    M.run, M.on_idle = nil, nil
    if run and run.proc then
        run.proc:kill(15)
    end
end

--- Play item `i` of `run` once its audio is here, fetching the next two meanwhile.
local function play(run, i)
    if M.run ~= run then
        return
    end
    local item = run.items[i]
    if not item then
        M.run = nil
        local on_idle = M.on_idle
        M.on_idle = nil
        return on_idle and on_idle()
    end
    local function fetch(j)
        local ahead = run.items[j]
        if ahead and not ahead.fetching then
            ahead.fetching = true
            M.tts(ahead.text, function(err, bytes)
                ahead.err, ahead.bytes, ahead.done = err, bytes, true
                if run.waiting == j then
                    play(run, j)
                end
            end)
        end
    end
    fetch(i)
    if not item.done then
        run.waiting = i
        return
    end
    run.waiting = nil
    if item.err then
        M.stop()
        return fail(item.err)
    end
    fetch(i + 1)
    fetch(i + 2)
    run.proc = spawn(config.voice.play_cmd, { stdin = item.bytes, text = false }, function(result)
        if M.run ~= run then
            return
        end
        item.bytes = nil
        if result.code ~= 0 then
            M.stop()
            return fail("player: " .. vim.trim(result.stderr or ""))
        end
        play(run, i + 1)
    end)
end

--- Run `fn` now, or when the reading in progress ends (not if it is stopped or replaced).
function M.after_reading(fn)
    if M.run then
        M.on_idle = fn
    else
        fn()
    end
end

--- Read `texts` aloud in order, replacing any reading in progress.
function M.speak(texts)
    M.stop()
    if #texts == 0 then
        return
    end
    local run = { items = vim.tbl_map(function(text)
        return { text = text }
    end, texts) }
    M.run = run
    play(run, 1)
end

--- Read `messages` (`{ sender_full_name, content }`) aloud, each led by its sender when `with_sender`.
function M.speak_messages(messages, with_sender)
    local texts = {}
    for _, message in ipairs(messages) do
        if with_sender then
            texts[#texts + 1] = message.sender_full_name .. " says."
        end
        vim.list_extend(texts, M.chunks(message.content))
    end
    M.speak(texts)
end

--- Autoplay `messages` just received from others, when `config.voice.autoplay`.
function M.autoplay(messages)
    if config.voice.autoplay and #messages > 0 then
        M.speak_messages(messages, false)
    end
end

--- Insert `text` at the cursor of `win`, which shows `buf`.
local function insert(buf, win, text)
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    local at = line == "" and 0 or math.min(col + 1, #line)
    local lead = at > 0 and not line:sub(at, at):match("%s") and " " or ""
    vim.api.nvim_buf_set_text(buf, row - 1, at, row - 1, at, { lead .. text })
    vim.api.nvim_win_set_cursor(win, { row, at + #lead + #text - 1 })
end

--- Start recording, or stop and transcribe into the compose buffer `buf`.
--- The recorder writes WebM to its standard output and stops on `q` from its standard input or at its own time limit.
function M.dictate(buf)
    if M.recorder then
        return M.recorder:write("q")
    end
    local chunks = {}
    M.recorder = spawn(config.voice.record_cmd, {
        stdin = true,
        text = false,
        stdout = function(_, data)
            chunks[#chunks + 1] = data
        end,
    }, function(result)
        M.recorder = nil
        local audio = table.concat(chunks)
        if #audio == 0 then
            return fail("recorder: " .. vim.trim(result.stderr or "no audio"))
        end
        local path = vim.fn.tempname() .. ".webm"
        local file = io.open(path, "wb")
        file:write(audio)
        file:close()
        vim.notify("zulip voice: transcribing")
        M.stt(path, function(err, text)
            os.remove(path)
            if err then
                return fail(err)
            end
            local win = vim.fn.bufwinid(buf)
            if text == "" or not vim.api.nvim_buf_is_valid(buf) or win == -1 then
                return vim.notify("zulip voice: no speech heard")
            end
            insert(buf, win, vim.trim(text))
        end)
    end)
    vim.notify("zulip voice: recording; stop with the same key")
end

return M

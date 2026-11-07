--- Client of the voice service (`agent_managers/zulip-voice/service/protocol.md`) and dictation.
--- Requests go to the private channel `config.voice.channel` as the account; results and the service's
--- pre-rendered speech bundles arrive as bot messages through one event queue.
--- Audio is recorded by a command that may run on another machine (`config.voice.via`).
local api = require("zulip.api")
local config = require("zulip.config")
local events = require("zulip.events")
local M = {
    --- Voice channel id once looked up.
    relay_id = nil,
    --- The dictation in progress, or `nil`.
    session = nil,
    --- Whether the last service call failed.
    offline = false,
    --- Pre-rendered speech bundles by message id, each `{ firstIdx, texts, offsetsMs, uri, audioURL, arrived_ms }`.
    bundles = {},
}
local n_requests = 0
local waiters, ready = {}, nil
local MAX_CHUNK_CHARS = 240
local MAX_TTS_CHARS = 1800
local PREPARED_TTL_MS = 6 * 3600 * 1000
local URL_TTL_MS = 50000
local SPEECH_BATCH = 6

local function fail(err)
    vim.notify("zulip voice: " .. err, vim.log.levels.ERROR)
end

--- Run `cmd` here, or through `config.voice.via` (e.g. `ssh` to the laptop) with each argument shell-quoted.
function M.spawn(cmd, opts, on_exit)
    local via = config.voice.via
    if #via > 0 then
        cmd = vim.list_extend(vim.deepcopy(via), { table.concat(vim.tbl_map(vim.fn.shellescape, cmd), " ") })
    end
    return vim.system(cmd, opts, vim.schedule_wrap(on_exit))
end
local spawn = M.spawn

--- What a speech engine should say for Markdown `text` (same cleaning as the service's `text.mjs`).
local function speech_text(text)
    text = text:gsub("!?%[([^%]]*)%]%([^)]*%)", "%1"):gsub("https?://%S+", "link"):gsub("`([^`]*)`", "%1")
    text = text:gsub("%*%*", ""):gsub("__", ""):gsub("~~", ""):gsub("%*", "")
    for _ = 1, 2 do
        text = text:gsub("(%w)_(%w)", "%1 %2")
    end
    return vim.trim(text:gsub("^>%s?", ""):gsub("%s+", " "))
end

--- Sentence groups of at most `MAX_CHUNK_CHARS` characters (one speech chunk each) in `text`.
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

--- The speakable blocks of a message's Markdown `content`, each `{ speech, first, last }` with
--- its 1-based line range in `content`. The `[task]` title line, `[switch: ...]` lines and code are skipped.
function M.blocks(content)
    local blocks, from, last, in_code, parts = {}, nil, 0, false, {}
    local function flush()
        if from and table.concat(parts, " "):match("%w") then
            blocks[#blocks + 1] = { speech = speech_text(table.concat(parts, " ")), first = from, last = last }
        end
        from, parts = nil, {}
    end
    for n, line in ipairs(vim.split(content, "\n")) do
        if line:match("^%s*```") then
            flush()
            in_code = not in_code
        elseif in_code or line:match("^%[switch: .+%]$") or (n == 1 and line:match("^%[[^%]]+%]")) then
            flush()
        elseif vim.trim(line) == "" then
            flush()
        elseif line:match("^%s*[-*+]%s") or line:match("^%s*%d+[.)]%s") or line:match("^#+%s") then
            flush()
            from, last = n, n
            parts = { (line:gsub("^%s*[-*+]%s+", ""):gsub("^%s*%d+[.)]%s+", ""):gsub("^#+%s+", "")) }
            flush()
        else
            from, last = from or n, n
            parts[#parts + 1] = vim.trim(line)
        end
    end
    flush()
    return blocks
end

--- The strings to say for `blocks`, in order.
function M.chunks(blocks)
    local chunks = {}
    for _, block in ipairs(blocks) do
        vim.list_extend(chunks, groups(block.speech))
    end
    return chunks
end

--- A bundle in `bundles` with the chunk `idx` of message `message_id`, or `nil`.
function M.bundle_for(message_id, idx)
    return vim.iter(M.bundles[message_id] or {}):find(function(bundle)
        return idx >= bundle.firstIdx and idx < bundle.firstIdx + #bundle.texts
    end)
end

local function handle(message)
    if message.stream_id ~= M.relay_id or message.sender_id == api.account.user_id then
        return
    end
    local ok, body = pcall(vim.json.decode, message.content)
    if not (ok and type(body) == "table" and body.voice == 1 and body.op == "result") then
        return
    end
    if waiters[body.id] then
        local waiter = waiters[body.id]
        waiters[body.id] = nil
        waiter(body)
    elseif body.proactive and body.bundle and body.audioURL then
        local parts = M.bundles[body.messageId] or {}
        if not vim.iter(parts):any(function(part)
            return part.id == body.id
        end) then
            body.arrived_ms = math.min(os.time() * 1000, message.timestamp * 1000)
            parts[#parts + 1] = body
        end
        M.bundles[body.messageId] = parts
        for key, list in pairs(M.bundles) do
            if os.time() * 1000 - list[1].arrived_ms > PREPARED_TTL_MS then
                M.bundles[key] = nil
            end
        end
    end
end

--- Find the voice channel and listen on its event queue, then run `then_do`; errors go to `on_done`.
--- Bundles rendered while not listening are read back after each registration.
local function with_relay(on_done, then_do)
    api.connect(config.zuliprc, function(err)
        if err then
            M.offline = true
            return on_done(err)
        end
        if ready then
            return ready(on_done, then_do)
        end
        local waiting = {}
        ready = function(done, run)
            waiting[#waiting + 1] = { done, run }
        end
        ready(on_done, then_do)
        local function live()
            ready = function(_, run)
                run()
            end
            for _, call in ipairs(waiting) do
                call[2]()
            end
            waiting = {}
        end
        api.request("GET", "/get_stream_id", { stream = config.voice.channel }, function(stream_err, reply)
            if stream_err then
                ready = nil
                M.offline = true
                for _, call in ipairs(waiting) do
                    call[1](("channel `%s`: %s"):format(config.voice.channel, stream_err))
                end
                return
            end
            M.relay_id = reply.stream_id
            events.start(function(received)
                for _, event in ipairs(received or {}) do
                    if event.type == "message" then
                        handle(event.message)
                    end
                end
                if not received then
                    local narrow = { { operator = "channel", operand = M.relay_id }, { operator = "topic", operand = "tts" } }
                    api.request("GET", "/messages", { narrow = narrow, anchor = "newest", num_before = 300, num_after = 0, apply_markdown = false }, function(_, back)
                        for _, message in ipairs(back and back.messages or {}) do
                            handle(message)
                        end
                    end)
                    if waiting[1] then
                        live()
                    end
                end
            end, { name = "voice", event_types = { "message" }, narrow = { { "stream", config.voice.channel } } })
        end)
    end)
end

--- Post a request for `op` with `fields` and wait for its result; `on_done(err, result)`.
--- The service removes requests and results itself.
local function call(op, fields, on_done)
    n_requests = n_requests + 1
    local body = vim.tbl_extend("force", { voice = 1, op = op, id = ("nv_%d_%d"):format(os.time(), n_requests) }, fields)
    local timer = vim.uv.new_timer()
    local function finish(err, result)
        timer:stop()
        timer:close()
        waiters[body.id] = nil
        M.offline = err ~= nil and result == nil
        on_done(err, result)
    end
    waiters[body.id] = function(result)
        finish(result.error, result)
    end
    timer:start(1000 * config.voice.timeout_s, 0, vim.schedule_wrap(function()
        finish(op .. " timed out")
    end))
    api.request("POST", "/messages", { type = "stream", to = M.relay_id, topic = op, content = vim.json.encode(body) }, function(err)
        if err and waiters[body.id] then
            finish(err)
        end
    end)
end

--- Speech for `texts` (a few chunks) in one request, as a bundle starting at chunk `first_idx`; `on_done(err, bundle)`.
function M.tts(texts, first_idx, on_done)
    with_relay(on_done, function()
        call("tts", { texts = texts }, function(err, result)
            if err then
                return on_done(err)
            end
            result.firstIdx, result.arrived_ms = first_idx, os.time() * 1000
            on_done(nil, result)
        end)
    end)
end

--- How many chunks one on-demand speech request holds.
M.SPEECH_BATCH = SPEECH_BATCH

--- Download the audio of `bundle` into `bundle.bytes`, minting a new link when the old one is stale; `on_done(err)`.
function M.fetch(bundle, on_done)
    if bundle.bytes then
        return on_done()
    end
    local function download(url)
        url = url:match("^/") and api.account.site .. url or url
        vim.system({ "curl", "-sSf", "--max-time", "60", url }, { text = false }, vim.schedule_wrap(function(result)
            if result.code ~= 0 then
                return on_done(vim.trim(result.stderr or "download failed"))
            end
            bundle.bytes = result.stdout
            on_done()
        end))
    end
    if os.time() * 1000 - bundle.arrived_ms < URL_TTL_MS then
        return download(bundle.audioURL)
    end
    api.request("GET", bundle.uri, {}, function(err, reply)
        if err then
            return on_done("clip expired: " .. err)
        end
        download(reply.url)
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

--- Short status of the voice features for a status line: `recording`, `transcribing`, `offline` or `nil`.
function M.status()
    if M.session then
        return M.session.stopped and "transcribing" or "recording"
    end
    return M.offline and "offline" or nil
end

local FRAME_MS = 100
local FRAME_BYTES = 16 * FRAME_MS * 2
local ns = vim.api.nvim_create_namespace("zulip_voice")
local darwin = vim.uv.os_uname().sysname == "Darwin"
local MIC_HINT = darwin and "; allow your terminal under System Settings > Privacy & Security > Microphone, and check the device with :ZulipVoiceCheck" or ""

--- Little-endian bytes of `n`.
local function le(n, bytes)
    local out = {}
    for i = 1, bytes do
        out[i] = string.char(bit.band(bit.rshift(n, 8 * (i - 1)), 255))
    end
    return table.concat(out)
end

--- The 16 kHz mono 16-bit samples `pcm` as a WAV file.
local function wav(pcm)
    return "RIFF" .. le(36 + #pcm, 4) .. "WAVEfmt " .. le(16, 4) .. le(1, 2) .. le(1, 2) .. le(16000, 4) .. le(32000, 4) .. le(2, 2) .. le(16, 2) .. "data" .. le(#pcm, 4) .. pcm
end

--- Root mean square of the 16-bit samples in `frame`.
local function rms(frame)
    local samples, sum = require("ffi").cast("const int16_t*", frame), 0
    local n = math.floor(#frame / 2)
    for i = 0, n - 1 do
        sum = sum + samples[i] * samples[i]
    end
    return math.sqrt(sum / math.max(n, 1))
end

local function write_file(path, bytes)
    local file = io.open(path, "wb")
    file:write(bytes)
    file:close()
end

--- A message when the first word of `cmd` is not installed (only checkable when run here), else `nil`.
local function missing(cmd)
    if #config.voice.via == 0 and vim.fn.executable(cmd[1]) == 0 then
        return ("`%s` not found%s"):format(cmd[1], darwin and "; run `brew install ffmpeg`" or "")
    end
end

--- Idle hint in the compose window `win`.
function M.idle_bar(win)
    vim.wo[win].winbar = "%#Comment# <CR> send · <C-g> dictate · <C-c> stop playback"
end

--- Show the dictation state of `session` in the winbar of its compose window.
local function paint(session)
    local win = vim.fn.bufwinid(session.buf)
    if win == -1 then
        return
    end
    local bars = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
    local seconds = math.floor((vim.uv.now() - session.started_ms) / 1000)
    if not session.stopped then
        local bar = bars[math.min(8, math.floor(session.level / 400) + 1)]
        vim.wo[win].winbar = ("%%#ErrorMsg# ● Recording %d:%02d %s %%#Comment# <C-g> stop · <Esc> cancel"):format(math.floor(seconds / 60), seconds % 60, bar)
    else
        vim.wo[win].winbar = ("%%#WarningMsg# Transcribing… (%d left)"):format(session.n_sent - session.n_done)
    end
end

--- End the session: stop its timer, drop the cancel key, restore the idle hint.
local function close(session)
    if session.closed then
        return
    end
    session.closed = true
    M.session = nil
    session.timer:stop()
    session.timer:close()
    require("zulip.player").release()
    pcall(vim.keymap.del, "n", "<Esc>", { buffer = session.buf })
    local win = vim.fn.bufwinid(session.buf)
    if win ~= -1 then
        M.idle_bar(win)
    end
end

--- Put each finished transcript, in recording order, at the session's mark.
local function drain(session)
    while session.results[session.next] do
        local text = session.results[session.next]
        session.results[session.next] = nil
        session.next, session.n_done = session.next + 1, session.n_done + 1
        local buf = session.buf
        if text ~= "" and not session.cancelled and vim.api.nvim_buf_is_valid(buf) then
            local row, col = unpack(vim.api.nvim_buf_get_extmark_by_id(buf, ns, session.mark, {}))
            local before = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]:sub(col, col)
            local lead = before ~= "" and not before:match("%s") and " " or ""
            vim.api.nvim_buf_set_text(buf, row, col, row, col, { lead .. text })
            local win = vim.fn.bufwinid(buf)
            if win ~= -1 and vim.api.nvim_get_mode().mode == "n" then
                local end_row, end_col = unpack(vim.api.nvim_buf_get_extmark_by_id(buf, ns, session.mark, {}))
                vim.api.nvim_win_set_cursor(win, { end_row + 1, math.max(end_col - 1, 0) })
            end
        end
    end
    if session.stopped and session.n_done == session.n_sent then
        close(session)
    end
end

--- Transcribe the speech `pcm` of `session` as the next piece.
local function send_piece(session, pcm)
    session.n_sent = session.n_sent + 1
    local index, path = session.n_sent, vim.fn.tempname() .. ".wav"
    write_file(path, wav(pcm))
    M.stt(path, function(err, text)
        os.remove(path)
        if err then
            fail("speech to text: " .. err)
        end
        session.results[index] = text or ""
        drain(session)
    end)
end

--- Cut the speech heard so far into a piece and send it.
local function cut(session)
    if #session.piece > 0 then
        send_piece(session, table.concat(session.piece))
    end
    session.piece, session.silent_ms = {}, 0
end

--- Take one `FRAME_MS` frame of audio: track level, and cut a piece at a pause or at `max_piece_s`.
local function feed_frame(session, frame)
    session.level = rms(frame)
    session.n_frames = session.n_frames + 1
    if session.level >= config.voice.silence_rms then
        if #session.piece == 0 then
            session.piece = session.preroll
        end
        session.silent_ms = 0
        session.piece[#session.piece + 1] = frame
    elseif #session.piece > 0 then
        session.silent_ms = session.silent_ms + FRAME_MS
        session.piece[#session.piece + 1] = frame
        if session.silent_ms >= config.voice.pause_ms then
            cut(session)
        end
    else
        session.preroll = { session.preroll[#session.preroll], frame }
    end
    if #session.piece * FRAME_MS >= config.voice.max_piece_s * 1000 then
        cut(session)
    end
end

--- Stop recording, keeping what was said; the pieces still being transcribed arrive afterwards.
function M.stop_dictation()
    if M.session and not M.session.stopped then
        M.session.recorder:write("q")
    end
end

--- Stop recording and throw away everything.
local function cancel()
    local session = M.session
    if session then
        session.cancelled = true
        session.recorder:kill(15)
        vim.notify("zulip voice: dictation cancelled")
    end
end

--- Once the recorder has exited and its output is all read: transcribe the last piece and finish.
local function settle(session)
    if not (session.eof and session.exit) then
        return
    end
    local result = session.exit
    if session.n_frames == 0 and not session.cancelled then
        fail("recorder produced no audio (exit " .. result.code .. "): " .. vim.trim(result.stderr or "") .. MIC_HINT)
    end
    session.stopped = true
    if session.cancelled or session.n_frames == 0 then
        session.n_sent = session.n_done
    else
        cut(session)
    end
    drain(session)
end

--- Start recording into the compose buffer `buf`, or stop when already recording.
--- The recorder writes 16 kHz mono 16-bit samples to its standard output and stops on `q` on its standard input.
--- Speech is cut at pauses and each piece is transcribed into the buffer as it finishes.
function M.dictate(buf)
    if M.session then
        return M.stop_dictation()
    end
    local absent = missing(config.voice.record_cmd)
    if absent then
        return fail(absent)
    end
    local win = vim.fn.bufwinid(buf)
    local row, col = unpack(vim.api.nvim_win_get_cursor(win == -1 and 0 or win))
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    local session = {
        buf = buf, started_ms = vim.uv.now(), level = 0, n_frames = 0, n_sent = 0, n_done = 0, next = 1,
        results = {}, piece = {}, preroll = { "", "" }, silent_ms = 0, timer = vim.uv.new_timer(), rest = "",
        mark = vim.api.nvim_buf_set_extmark(buf, ns, row - 1, line == "" and 0 or math.min(col + 1, #line), { right_gravity = true }),
    }
    M.session = session
    require("zulip.player").hold()
    session.recorder = spawn(config.voice.record_cmd, {
        stdin = true,
        text = false,
        stdout = function(_, data)
            vim.schedule(function()
                if not data then
                    session.eof = true
                    return settle(session)
                end
                session.rest = session.rest .. data
                while #session.rest >= FRAME_BYTES do
                    feed_frame(session, session.rest:sub(1, FRAME_BYTES))
                    session.rest = session.rest:sub(FRAME_BYTES + 1)
                end
            end)
        end,
    }, function(result)
        session.exit = result
        settle(session)
    end)
    session.timer:start(0, 200, vim.schedule_wrap(function()
        paint(session)
    end))
    vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, desc = "Zulip voice: cancel dictation" })
end

--- Report whether the player, the recorder (with its microphone level) and the service work.
function M.check()
    local lines = {}
    local function report(ok, text)
        lines[#lines + 1] = (ok and "ok    " or "FAIL  ") .. text
    end
    local function service()
        with_relay(function(err)
            report(false, "service: " .. err)
            vim.notify(table.concat(lines, "\n"))
        end, function()
            call("ping", { t = vim.uv.now() }, function(err, result)
                report(not err, err and "service: " .. err or ("service: relay %d ms, stt %s, tts %s"):format(result.relayMs, result.workers.stt, result.workers.tts))
                vim.notify(table.concat(lines, "\n"))
            end)
        end)
    end
    local function recorder()
        local absent = missing(config.voice.record_cmd)
        if absent then
            report(false, "recorder: " .. absent)
            return service()
        end
        local peak, n_bytes = 0, 0
        local proc = spawn(config.voice.record_cmd, {
            stdin = true,
            text = false,
            stdout = function(_, data)
                if data then
                    vim.schedule(function()
                        n_bytes = n_bytes + #data
                        for i = 1, #data - FRAME_BYTES + 1, FRAME_BYTES do
                            peak = math.max(peak, rms(data:sub(i, i + FRAME_BYTES - 1)))
                        end
                    end)
                end
            end,
        }, function(result)
            if n_bytes == 0 then
                report(false, "recorder: no audio (exit " .. result.code .. "): " .. vim.trim(result.stderr or "") .. MIC_HINT)
            else
                report(true, ("recorder: %d bytes, peak level %d (speak: above %d counts as speech)"):format(n_bytes, peak, config.voice.silence_rms))
            end
            service()
        end)
        vim.defer_fn(function()
            proc:write("q")
        end, 1500)
        vim.notify("zulip voice: testing the microphone for 1.5 s; say something")
    end
    local absent = missing(config.voice.play_cmd)
    if absent then
        report(false, "player: " .. absent)
        return recorder()
    end
    spawn(config.voice.play_cmd, { stdin = wav(("\0"):rep(FRAME_BYTES * 3)), text = false }, function(result)
        report(result.code == 0, "player: " .. (result.code == 0 and "ran" or vim.trim(result.stderr or "")))
        recorder()
    end)
end

return M

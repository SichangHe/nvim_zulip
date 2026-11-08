--- Reading messages aloud, modeled on the web client (`agent_managers/zulip-voice/v2/design.md`).
--- A run is a queue of messages read one after another; the audio of a message arrives as bundles
--- (several chunks in one file) and each bundle plays in one process that starts at its chunk.
local config = require("zulip.config")
local voice = require("zulip.voice")
local M = {
    --- The reading in progress, or `nil`: `{ buf, key, items, i, idx, state, auto, paused, held, gen, proc, mark }`.
    --- `i` is the item and `idx` the 0-based chunk being read; `state` is `loading`, `playing` or `paused`.
    run = nil,
    --- Where reading stopped, by conversation key: `{ id, idx }`.
    last = {},
    --- Runs once when the reading ends without being stopped.
    on_idle = nil,
    --- Buffers whose window shows the status line.
    bufs = {},
}
local ns = vim.api.nvim_create_namespace("zulip_player")
local queued = {}
local DEBOUNCE_MS = 250
local TICK_MS = 100
vim.api.nvim_set_hl(0, "ZulipReading", { default = true, link = "Visual" })

local function fail(err)
    vim.notify("zulip voice: " .. err, vim.log.levels.ERROR)
end

--- The status line text: dictation, offline, reading state and autoplay.
function M.status_line()
    local run = M.run
    local dictation = voice.status()
    local parts = {}
    if dictation == "recording" then
        parts[1] = "● Recording"
    elseif dictation == "transcribing" then
        parts[1] = "Transcribing…"
    elseif run then
        parts[1] = ({ loading = "… Loading", playing = "▶ Playing", paused = "⏸ Paused" })[run.state]
        parts[1] = ("%s %d/%d"):format(parts[1], run.i, #run.items)
    else
        parts[1] = "Idle"
    end
    if voice.status() == "offline" then
        parts[#parts + 1] = "offline"
    end
    local control = require("zulip.handsfree").label()
    if control then
        parts[#parts + 1] = control
    end
    parts[#parts + 1] = ("%.1fx"):format(config.voice.speed)
    if run then
        parts[#parts + 1] = run.following and "follow" or "follow off"
    end
    parts[#parts + 1] = "autoplay " .. (config.voice.autoplay and "on" or "off")
    local keys = config.voice.keys
    if dictation == "recording" then
        parts[#parts + 1] = "<CR> in compose sends · <Esc> cancels · " .. keys.dictate .. " stops"
    else
        parts[#parts + 1] = ("%s play · %s/%s chunk · %s/%s msg · %s/%s speed · %s voice · %s switch · %s stop · %s? more"):format(keys.play, keys.next_chunk, keys.prev_chunk, keys.next_message, keys.prev_message, keys.faster, keys.slower, keys.handsfree, keys.switch, keys.stop, keys.prefix)
    end
    return " " .. table.concat(parts, " · "):gsub("%%", "%%%%")
end

--- Show the status line in the window of each conversation buffer.
function M.paint()
    for buf in pairs(M.bufs) do
        for _, win in ipairs(vim.api.nvim_buf_is_valid(buf) and vim.fn.win_findbuf(buf) or {}) do
            vim.wo[win].winbar = "%#Comment#" .. M.status_line()
        end
    end
end

--- Mark `buf` as one whose windows show the status line, and stop following the audio when the cursor is moved by hand.
function M.attach(buf)
    M.bufs[buf] = true
    -- winbar belongs to the window, so it follows the buffer in and out of windows.
    vim.api.nvim_create_autocmd("BufWinEnter", { buffer = buf, callback = M.paint })
    vim.api.nvim_create_autocmd("BufWinLeave", {
        buffer = buf,
        callback = function(event)
            for _, win in ipairs(vim.fn.win_findbuf(event.buf)) do
                vim.wo[win].winbar = ""
            end
        end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = function()
            local run = M.run
            if run and run.buf == buf and run.following then
                if run.expect_move then
                    run.expect_move = false
                else
                    run.following = false
                    M.paint()
                end
            end
        end,
    })
    M.paint()
end

local function item_of(message)
    local blocks = voice.blocks(message.content)
    local item = { message = message, blocks = blocks, chunks = voice.chunks(blocks), local_bundles = {}, waiting = {}, block_of = {} }
    for b, block in ipairs(blocks) do
        for _ = 1, #voice.chunks({ block }) do
            item.block_of[#item.block_of + 1] = b
        end
    end
    item.n = #item.chunks
    return item
end

--- Highlight the block holding the chunk being read; with `follow`, move the cursor there.
local function highlight(run, follow)
    if not vim.api.nvim_buf_is_valid(run.buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(run.buf, ns, 0, -1)
    local item = run.items[run.i]
    local shown = require("zulip.conversation").shown[run.buf]
    local span = item and shown and vim.iter(shown.spans):find(function(candidate)
        return candidate.id == item.message.id
    end)
    local block = item and item.blocks[item.block_of[run.idx + 1] or 1]
    if not (span and block) then
        return
    end
    local first, last = span.first + 1 + block.first, span.first + 1 + block.last
    vim.api.nvim_buf_set_extmark(run.buf, ns, first - 1, 0, { end_row = last, end_col = 0, hl_group = "ZulipReading", hl_eol = true })
    local win = follow and run.following and vim.fn.bufwinid(run.buf) or -1
    if win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] ~= first then
        run.expect_move = win == vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_cursor(win, { first, 0 })
    end
end

--- Re-highlight after the buffer `buf` reloaded.
function M.refresh(buf)
    if M.run and M.run.buf == buf then
        highlight(M.run, false)
    end
end

local function halt(run)
    run.gen = run.gen + 1
    for _, name in ipairs({ "timer", "debounce" }) do
        if run[name] then
            run[name]:stop()
            run[name]:close()
            run[name] = nil
        end
    end
    if run.proc then
        run.proc:kill(15)
        run.proc = nil
    end
end

--- Stop reading; the position is remembered for `gp`.
function M.stop()
    local run = M.run
    M.run, M.on_idle = nil, nil
    if run then
        halt(run)
        if vim.api.nvim_buf_is_valid(run.buf) then
            vim.api.nvim_buf_clear_namespace(run.buf, ns, 0, -1)
        end
    end
    M.paint()
end

local function finish(run)
    M.run = nil
    local on_idle = M.on_idle
    M.on_idle = nil
    if vim.api.nvim_buf_is_valid(run.buf) then
        vim.api.nvim_buf_clear_namespace(run.buf, ns, 0, -1)
    end
    M.paint()
    return on_idle and on_idle()
end

--- The bundle with chunk `idx` of `item`, rendering one when the service did not; `on_done(err, bundle)`.
local function get_bundle(item, idx, on_done)
    local function has(bundle)
        return idx >= bundle.firstIdx and idx < bundle.firstIdx + #bundle.texts
    end
    local bundle = voice.bundle_for(item.message.id, idx) or vim.iter(item.local_bundles):find(has)
    if bundle then
        return voice.fetch(bundle, function(err)
            on_done(err, bundle)
        end)
    end
    if item.waiting[idx] then
        table.insert(item.waiting[idx], on_done)
        return
    end
    item.waiting[idx] = { on_done }
    voice.tts(vim.list_slice(item.chunks, idx + 1, idx + voice.SPEECH_BATCH), idx, function(err, rendered)
        local callbacks = item.waiting[idx]
        item.waiting[idx] = nil
        if rendered then
            table.insert(item.local_bundles, rendered)
        end
        local function done(fetch_err)
            for _, callback in ipairs(callbacks) do
                callback(err or fetch_err, rendered)
            end
        end
        if err then
            return done()
        end
        voice.fetch(rendered, done)
    end)
end

local play

--- The message of the item just read has ended: mark it read and go to the next.
local function item_done(run)
    local item = run.items[run.i]
    if run.mark then
        run.mark(item.message.id)
    end
    run.i, run.idx = run.i + 1, 0
    if run.i > #run.items then
        return finish(run)
    end
    play(run)
end

--- Play the bundle from the current chunk on; the chunk tracked follows the elapsed time.
local function start_process(run, item, bundle)
    local gen = run.gen
    local k = run.idx - bundle.firstIdx
    local offset_ms = run.resume_ms or bundle.offsetsMs[k + 1] or 0
    run.resume_ms = nil
    local started_ms = vim.uv.now()
    local speed = config.voice.speed
    local cmd = { config.voice.play_cmd[1], "-ss", ("%.3f"):format(offset_ms / 1000) }
    if speed ~= 1 then
        -- `atempo` takes 0.5 to 2.0, so faster speeds chain two.
        local filter = speed > 2 and ("atempo=2.0,atempo=%.3f"):format(speed / 2) or ("atempo=%.3f"):format(speed)
        vim.list_extend(cmd, { "-af", filter })
    end
    vim.list_extend(cmd, vim.list_slice(config.voice.play_cmd, 2))
    run.state = "playing"
    run.proc = voice.spawn(cmd, { stdin = bundle.bytes, text = false }, function(result)
        if M.run ~= run or run.gen ~= gen then
            return
        end
        halt(run)
        if result.code ~= 0 then
            M.stop()
            return fail("player: " .. vim.trim(result.stderr or ""))
        end
        local next_idx = bundle.firstIdx + #bundle.texts
        if next_idx < item.n or voice.bundle_for(item.message.id, next_idx) then
            run.idx = next_idx
            return play(run)
        end
        item_done(run)
    end)
    run.timer = vim.uv.new_timer()
    run.timer:start(TICK_MS, TICK_MS, vim.schedule_wrap(function()
        if run.gen ~= gen then
            return
        end
        local position_ms, at = offset_ms + (vim.uv.now() - started_ms) * speed, k
        run.position_ms = position_ms
        for j, start_ms in ipairs(bundle.offsetsMs) do
            if start_ms <= position_ms then
                at = j - 1
            end
        end
        if bundle.firstIdx + at ~= run.idx then
            run.idx = bundle.firstIdx + at
            M.last[run.key] = { id = item.message.id, idx = run.idx }
            highlight(run, true)
        end
    end))
    local next_idx = bundle.firstIdx + #bundle.texts
    if next_idx < item.n then
        get_bundle(item, next_idx, function() end)
    elseif run.items[run.i + 1] then
        get_bundle(run.items[run.i + 1], 0, function() end)
    end
    M.paint()
end

--- Play from the current item and chunk unless paused or dictating.
function play(run)
    if M.run ~= run then
        return
    end
    if run.paused or run.held then
        run.state = "paused"
        return M.paint()
    end
    local item = run.items[run.i]
    if item.n == 0 then
        return item_done(run)
    end
    local gen = run.gen
    run.state = "loading"
    M.last[run.key] = { id = item.message.id, idx = run.idx }
    highlight(run, true)
    M.paint()
    get_bundle(item, run.idx, function(err, bundle)
        if M.run ~= run or run.gen ~= gen then
            return
        end
        if err then
            M.stop()
            return fail(err)
        end
        start_process(run, item, bundle)
    end)
end

--- Read `messages` (`{ id, sender_full_name, content }`) of the conversation buffer `buf` with key `key`
--- from `idx` of the first one, replacing any reading; `mark(id)` is called as each message ends.
function M.read(buf, key, messages, idx, mark)
    M.stop()
    local run = { buf = buf, key = key, following = config.voice.follow, i = 1, idx = idx or 0, gen = 0, items = vim.tbl_map(item_of, messages), mark = mark }
    for _, message in ipairs(messages) do
        queued[message.id] = true
    end
    if #run.items > 0 then
        M.run = run
        play(run)
    end
end

--- Read the unread `messages` of `buf` that nobody has queued yet, when `config.voice.autoplay`.
--- They join the running queue of that buffer; a reading of another buffer yields only if it is autoplay.
function M.autoplay(buf, key, messages, mark)
    if not config.voice.autoplay or voice.session then
        return
    end
    local fresh = vim.tbl_filter(function(message)
        return not queued[message.id]
    end, messages)
    local run = M.run
    if #fresh == 0 or (run and run.buf ~= buf and not run.auto) then
        return
    end
    if run and run.buf == buf then
        for _, message in ipairs(fresh) do
            queued[message.id] = true
            run.items[#run.items + 1] = item_of(message)
        end
        return M.paint()
    end
    M.read(buf, key, fresh, 0, mark)
    if M.run then
        M.run.auto = true
    end
end

--- Pause, or resume when paused.
function M.toggle_pause()
    local run = M.run
    if not run then
        return vim.notify("zulip voice: nothing is playing; `gs` reads from the cursor")
    end
    if run.paused then
        run.paused, run.following = false, config.voice.follow
        play(run)
    else
        run.paused = true
        run.resume_ms = run.state == "playing" and run.position_ms or nil
        halt(run)
        run.state = "paused"
        M.paint()
    end
end

--- Restart playing soon at the current position; repeated moves within the delay add up.
local function restart(run)
    halt(run)
    run.resume_ms = nil
    run.paused, run.state = false, "loading"
    highlight(run, true)
    M.paint()
    run.debounce = vim.uv.new_timer()
    run.debounce:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        run.debounce:close()
        run.debounce = nil
        play(run)
    end))
end

--- Change the playback speed by `delta`, within 0.5 to 3.0, restarting the chunk when playing.
function M.change_speed(delta)
    config.voice.speed = math.min(3, math.max(0.5, math.floor((config.voice.speed + delta) * 10 + 0.5) / 10))
    require("zulip.state").save()
    local run = M.run
    if run and not run.paused then
        restart(run)
    end
    M.paint()
end

--- Keep the spoken chunk in view, or stop doing so.
function M.toggle_follow()
    config.voice.follow = not config.voice.follow
    require("zulip.state").save()
    local run = M.run
    if run then
        run.following = config.voice.follow
        highlight(run, true)
    end
    M.paint()
end

--- Move `delta` (+1 or -1) chunks, across messages.
function M.step_chunk(delta)
    local run = M.run
    if not run then
        return
    end
    if delta > 0 then
        if run.idx + 1 < run.items[run.i].n then
            run.idx = run.idx + 1
        elseif run.items[run.i + 1] then
            run.i, run.idx = run.i + 1, 0
        end
    elseif run.idx > 0 then
        run.idx = run.idx - 1
    elseif run.i > 1 then
        run.i = run.i - 1
        run.idx = math.max(run.items[run.i].n - 1, 0)
    end
    restart(run)
end

--- Move to the next message, or the previous one; previous first restarts the current message.
function M.step_message(delta)
    local run = M.run
    if not run then
        return
    end
    if delta > 0 and run.items[run.i + 1] then
        if run.mark then
            run.mark(run.items[run.i].message.id)
        end
        run.i, run.idx = run.i + 1, 0
    elseif delta < 0 then
        run.i, run.idx = run.idx > 0 and run.i or math.max(run.i - 1, 1), 0
    end
    restart(run)
end

--- Run `fn` now, or when the reading in progress ends (not if it is stopped or replaced).
function M.after_reading(fn)
    if M.run then
        M.on_idle = fn
    else
        fn()
    end
end

--- Hold playback while dictating.
function M.hold()
    local run = M.run
    if run then
        run.held = true
        halt(run)
        run.state = "paused"
    end
    M.paint()
end

--- Resume playback held by dictation.
function M.release()
    local run = M.run
    if run then
        run.held = false
        play(run)
    end
    M.paint()
end

return M

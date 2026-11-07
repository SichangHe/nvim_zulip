-- Voice against the live service: `ZULIPRC=<the human's zuliprc> nvim -l tests/voice.lua`.
-- Posts only relay traffic to `voice-relay`. Needs `ffmpeg`; the speaker and the microphone are replaced by files.
vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("zulip.config")
local conversation = require("zulip.conversation")
local player = require("zulip.player")
local voice = require("zulip.voice")
local failures = 0
local function check(name, got, want)
    if not vim.deep_equal(got, want) then
        failures = failures + 1
        print(("FAIL %s: got %s, want %s"):format(name, vim.inspect(got), vim.inspect(want)))
    end
end

local blocks = voice.blocks("[task] Title\nFirst **bold** `code` see [a link](http://x.y).\n\n```\nskipped\n```\n- item_one here\n[switch: other]")
check("blocks skip title, switch lines and code", vim.tbl_map(function(b) return { b.speech, b.first, b.last } end, blocks), { { "First bold code see a link.", 2, 2 }, { "item one here", 7, 7 } })
check("long paragraph splits", #voice.chunks(voice.blocks(("Word word word. "):rep(40))), 3)

if not vim.env.ZULIPRC then
    os.exit(failures == 0 and 0 or 1)
end
require("zulip").setup({ zuliprc = vim.env.ZULIPRC, mark_read = false })
local dir = vim.fn.tempname()
vim.fn.mkdir(dir)
local function wait(done)
    return vim.wait(90000, done)
end
local function seconds(path)
    local out = vim.system({ "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path }, { text = true }):wait()
    return tonumber(vim.trim(out.stdout)) or 0
end

-- speech for several chunks in one request
local sentences = { "The quick brown fox jumps over the lazy dog.", "Pack my box with five dozen liquor jugs." }
local bundle
voice.tts(sentences, 0, function(err, got)
    bundle = got or { err = err }
end)
check("tts bundle", wait(function() return bundle end) and bundle.err == nil and #bundle.offsetsMs, 2)
local fetched
voice.fetch(bundle, function(err) fetched = err or true end)
check("bundle downloads", wait(function() return fetched end), true)
local clip = dir .. "/clip.m4a"
local file = io.open(clip, "wb")
file:write(bundle.bytes)
file:close()
check("online", voice.offline, false)

-- reading: a conversation buffer with two messages; the speaker is ffmpeg writing a file, started at the chunk
local me = require("zulip.api").account.user_id
local messages = {
    { id = 1, sender_id = me + 1, sender_full_name = "Ann", content = "[task] T\nThe quick brown fox jumps over the lazy dog.\n\nPack my box with five dozen liquor jugs." },
    { id = 2, sender_id = me + 1, sender_full_name = "Ann", content = "Second message here." },
}
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local lines, _, spans = conversation.render(messages)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
conversation.shown[buf] = { spans = spans, messages = messages, unread = {} }
config.voice.play_cmd = { "ffmpeg", "-loglevel", "error", "-y", "-i", "-", dir .. "/played.wav" }
local marked = {}
player.read(buf, "k", messages, 0, function(id) marked[#marked + 1] = id end)
check("reading highlights and follows", wait(function() return player.run and player.run.state == "playing" end) and vim.api.nvim_win_get_cursor(0)[1], spans[1].first + 3)
check("reading ends", wait(function() return player.run == nil end), true)
check("messages marked in order as they end", marked, { 1, 2 })
check("audio played", seconds(dir .. "/played.wav") > 0.5, true)
local full = seconds(dir .. "/played.wav")

-- the status line follows the state
player.attach(buf)
check("status line", player.status_line():find("Idle · autoplay on", 1, true) ~= nil, true)

-- controls with a stand-in player that sleeps
local fake = dir .. "/fakeplay"
file = io.open(fake, "w")
file:write("#!/bin/sh\ncat > /dev/null\nsleep 30\n")
file:close()
vim.uv.fs_chmod(fake, 493)
config.voice.play_cmd = { fake }
player.read(buf, "k", messages, 0, nil)
check("playing", wait(function() return player.run and player.run.state == "playing" end), true)
player.toggle_pause()
check("paused", player.run.state, "paused")
player.toggle_pause()
check("resumed", wait(function() return player.run.state == "playing" end), true)
player.step_chunk(1)
player.step_chunk(1)
check("rapid steps accumulate: chunk 2 is the first of message 2", { player.run.i, player.run.idx }, { 2, 0 })
check("playing again after the delay", wait(function() return player.run.state == "playing" end), true)
player.step_message(-1)
check("previous message when at its start", { player.run.i, player.run.idx }, { 1, 0 })
player.stop()
check("stop clears the run", player.run, nil)
check("position remembered", player.last.k ~= nil, true)

-- dictation: the microphone is a clip, 1.5 s of silence, the clip again; two pieces appear in order
local rate = "aformat=sample_rates=16000:channel_layouts=mono"
config.voice.record_cmd = { "ffmpeg", "-loglevel", "error", "-i", clip, "-f", "lavfi", "-t", "1.5", "-i", "anullsrc=r=16000:cl=mono", "-i", clip,
    "-filter_complex", ("[0]%s[a];[1]%s[s];[2]%s[c];[a][s][c]concat=n=3:v=0:a=1"):format(rate, rate, rate), "-f", "s16le", "-ar", "16000", "-ac", "1", "-" }
local compose = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(compose)
vim.api.nvim_buf_set_lines(compose, 0, -1, false, { "Hello" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
voice.dictate(compose)
check("dictation starts", voice.status(), "recording")
check("dictation ends", wait(function() return voice.session == nil end), true)
local text = table.concat(vim.api.nvim_buf_get_lines(compose, 0, -1, false), " "):lower()
local _, n_fox = text:gsub("quick brown fox", "")
check("two pieces in order after the typed text", { text:find("^hello "), n_fox, text:find("liquor jugs") ~= nil }, { 1, 2, true })

-- a quiet microphone like macOS emits: 48 kHz stereo float, speech below the fixed threshold, no pause before the end
local pipe = ("ffmpeg -loglevel error -i %s -af volume=0.05 -ar 48000 -ac 2 -f f32le - | ffmpeg -loglevel error -f f32le -ar 48000 -ac 2 -i - -ac 1 -ar 16000 -f s16le -"):format(clip)
config.voice.record_cmd = { "sh", "-c", pipe }
vim.api.nvim_buf_set_lines(compose, 0, -1, false, { "" })
voice.dictate(compose)
check("quiet dictation ends", wait(function() return voice.session == nil end), true)
text = table.concat(vim.api.nvim_buf_get_lines(compose, 0, -1, false), " "):lower()
check("quiet speech is still transcribed", text:find("quick brown fox", 1, true) ~= nil, true)

local sent
vim.notify = function(message) sent = message end
voice.send_log()
check("log sent to the server", wait(function() return sent end) and sent:find("sent log", 1, true) ~= nil, true)
vim.notify = function() end

-- service check
config.voice.record_cmd = { "sh", "-c", pipe }
local reported
local notify = vim.notify
vim.notify = function(message) if message:find("service:", 1, true) then reported = message end end
voice.check()
check("check reports", wait(function() return reported end) and reported:find("ok    service", 1, true) ~= nil and reported:lower():find("quick brown fox", 1, true) ~= nil, true)
vim.notify = notify
print(full)
os.exit(failures == 0 and 0 or 1)

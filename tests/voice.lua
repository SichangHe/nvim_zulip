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
check("status line", player.status_line():find("Idle · 1.0x · autoplay on", 1, true) ~= nil, true)

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

check("virtual devices skipped, microphone first", voice.candidates({ { index = "0", name = "BlackHole 2ch" }, { index = "1", name = "MacBook Pro Microphone" }, { index = "2", name = "ZoomAudioDevice" }, { index = "3", name = "BlackHole 64ch" }, { index = "4", name = "USB Headset" } }), { "MacBook Pro Microphone", "USB Headset" })
-- an all-zero capture is reported, with the device list parsed from avfoundation's output
local bin = dir .. "/bin"
vim.fn.mkdir(bin)
file = io.open(bin .. "/ffmpeg", "w")
file:write([[#!/bin/sh
cat >&2 <<'EOF'
[AVFoundation indev @ 0x7f8] AVFoundation video devices:
[AVFoundation indev @ 0x7f8] [0] FaceTime HD Camera
[AVFoundation indev @ 0x7f8] AVFoundation audio devices:
[AVFoundation indev @ 0x7f8] [0] MacBook Pro Microphone
[AVFoundation indev @ 0x7f8] [1] Zoom Audio
EOF
exit 1
]])
file:close()
vim.uv.fs_chmod(bin .. "/ffmpeg", 493)
local path = vim.env.PATH
vim.env.PATH = bin .. ":" .. path
local listed
voice.devices(function(err, devices) listed = devices or err end)
vim.env.PATH = path
check("devices parsed", wait(function() return listed end) and listed, { { index = "0", name = "MacBook Pro Microphone" }, { index = "1", name = "Zoom Audio" } })
config.voice.record_cmd = { "ffmpeg", "-loglevel", "error", "-f", "lavfi", "-t", "2", "-i", "anullsrc=r=16000:cl=mono", "-f", "s16le", "-" }
local errors = {}
vim.notify = function(message) errors[#errors + 1] = message end
voice.dictate(compose)
check("silent dictation ends", wait(function() return voice.session == nil end), true)
check("silent mic is reported", wait(function() return vim.iter(errors):any(function(m) return m:find("only silence", 1, true) end) end), true)
vim.notify = function() end
config.voice.record_cmd = nil
check("named device with spaces", voice.record_cmd("MacBook Pro Microphone")[7], vim.uv.os_uname().sysname == "Darwin" and ":MacBook Pro Microphone" or "MacBook Pro Microphone")

-- speed: the player gets `-af atempo`, and the status line shows it
file = io.open(fake, "w")
file:write("#!/bin/sh\necho \"$@\" >> " .. dir .. "/args\ncat > /dev/null\nsleep 30\n")
file:close()
config.voice.play_cmd = { fake }
player.read(buf, "k", messages, 0, nil)
check("playing at 1x", wait(function() return player.run and player.run.state == "playing" end), true)
player.change_speed(0.5)
player.change_speed(0.5)
player.change_speed(0.5)
check("speed steps", config.voice.speed, 2.5)
check("playing at the new speed", wait(function()
    local f = io.open(dir .. "/args")
    local args = f and f:read("*a") or ""
    return args:find("atempo=2.0,atempo=1.250", 1, true) ~= nil
end), true)
check("status shows speed", player.status_line():find("2.5x", 1, true) ~= nil, true)
player.change_speed(-9)
check("speed floor", config.voice.speed, 0.5)
player.change_speed(9)
check("speed ceiling", config.voice.speed, 3)
config.voice.speed = 1
player.stop()

-- the event queue can lose results: stopped, requests still complete, and the log command works
require("zulip.events").stop("voice")
local logged
vim.notify = function(message) logged = message end
voice.send_log()
check("log works without the event queue", wait(function() return logged end) and logged:find("sent log", 1, true) ~= nil, true)
vim.notify = function() end

-- a long dictation: twelve pieces in order, and <CR> stops, waits for the text and sends once
local inputs, parts, joined = {}, {}, {}
for i = 0, 11 do
    vim.list_extend(inputs, { "-i", clip, "-f", "lavfi", "-t", "0.9", "-i", "anullsrc=r=16000:cl=mono" })
    parts[#parts + 1] = ("[%d]%s[a%d];[%d]%s[s%d]"):format(2 * i, rate, i, 2 * i + 1, rate, i)
    joined[#joined + 1] = ("[a%d][s%d]"):format(i, i)
end
config.voice.record_cmd = vim.list_extend(vim.list_extend({ "ffmpeg", "-loglevel", "error", "-re" }, inputs), { "-filter_complex", table.concat(parts, ";") .. ";" .. table.concat(joined) .. "concat=n=24:v=0:a=1", "-f", "s16le", "-ar", "16000", "-ac", "1", "-" })
local outbox = vim.api.nvim_create_buf(false, false)
vim.bo[outbox].buftype = "acwrite"
vim.api.nvim_buf_set_name(outbox, "zulip-test-compose")
local writes = {}
vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = outbox, callback = function()
    writes[#writes + 1] = table.concat(vim.api.nvim_buf_get_lines(outbox, 0, -1, false), " ")
end })
vim.api.nvim_set_current_buf(outbox)
voice.dictate(outbox)
vim.wait(9000)
voice.send_when_done()
check("sent once after all pieces", wait(function() return #writes > 0 end) and #writes, 1)
local _, n_fox = writes[1]:lower():gsub("quick brown fox", "")
check("sent text has the pieces so far", n_fox >= 2, true)
vim.wait(500)
check("not sent twice", #writes, 1)

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

-- Voice against the live service: `ZULIPRC=<the human's zuliprc> nvim -l tests/voice.lua`.
-- Posts only relay traffic to `voice-relay`. Needs `ffmpeg`; the player and the microphone are replaced by files.
vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("zulip.config")
local conversation = require("zulip.conversation")
local voice = require("zulip.voice")
local failures = 0
local function check(name, got, want)
    if not vim.deep_equal(got, want) then
        failures = failures + 1
        print(("FAIL %s: got %s, want %s"):format(name, vim.inspect(got), vim.inspect(want)))
    end
end

check("chunks skip title, switch lines and code", voice.chunks("[task] Title\nFirst **bold** `code` see [a link](http://x.y).\n\n```\nskipped\n```\n- item_one here\n[switch: other]"), { "First bold code see a link.", "item one here" })
check("long paragraph splits", #voice.chunks(("Word word word. "):rep(40)), 3)

if not vim.env.ZULIPRC then
    os.exit(failures == 0 and 0 or 1)
end
require("zulip").setup({ zuliprc = vim.env.ZULIPRC })
local dir = vim.fn.tempname()
vim.fn.mkdir(dir)

--- Wait up to 60 s for `done()`.
local function wait(done)
    return vim.wait(60000, done)
end

local spoken
voice.tts("The quick brown fox jumps over the lazy dog.", function(err, bytes)
    spoken = { err = err, bytes = bytes }
end)
check("tts returns audio", wait(function() return spoken end) and spoken.err == nil and #spoken.bytes > 1000, true)
local clip = dir .. "/clip.aac"
local file = io.open(clip, "wb")
file:write(spoken.bytes)
file:close()

-- microphone stand-in: the clip, encoded as the real recorder does; recording ends by itself
config.voice.record_cmd = { "ffmpeg", "-loglevel", "error", "-i", clip, "-ac", "1", "-ar", "16000", "-c:a", "libopus", "-f", "webm", "-" }
local compose = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(compose)
vim.api.nvim_buf_set_lines(compose, 0, -1, false, { "Hello" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
voice.dictate(compose)
check("dictation inserts the transcript", wait(function()
    return #vim.api.nvim_buf_get_lines(compose, 0, 1, false)[1] > 5
end), true)
local line = vim.api.nvim_buf_get_lines(compose, 0, 1, false)[1]
check("transcript is the spoken sentence", line:lower():find("quick brown fox", 1, true) ~= nil and line:find("^Hello "), 1)
check("recorder released", voice.recorder, nil)

-- speaker stand-in: each chunk lands in a file; `via` is exercised with `sh -c`
config.voice.via = { "sh", "-c" }
config.voice.play_cmd = { "ffmpeg", "-loglevel", "error", "-y", "-i", "-", dir .. "/played.wav" }
local messages = {
    { sender_full_name = "Ann", content = "[task] T\nHello there. This is the first message." },
    { sender_full_name = "Bob", content = "Second message." },
}
voice.speak_messages(messages, true)
check("reading finishes", wait(function() return voice.run == nil end), true)
local duration = vim.system({ "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", dir .. "/played.wav" }, { text = true }):wait()
check("last chunk was played as audio", tonumber(vim.trim(duration.stdout)) ~= nil and tonumber(vim.trim(duration.stdout)) > 0.5, true)

-- stop kills the player
config.voice.play_cmd = { "sleep", "30" }
voice.speak({ "Please stop." })
check("reading starts", wait(function() return voice.run and voice.run.proc end) ~= nil, true)
voice.stop()
check("stop clears the reading", voice.run, nil)

os.exit(failures == 0 and 0 or 1)

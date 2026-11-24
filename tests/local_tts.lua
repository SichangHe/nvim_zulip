-- Local speech (config.voice.local_tts) with a stand-in engine: `nvim -l tests/local_tts.lua`. Needs ffmpeg; no network.
vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("zulip.config")
local voice = require("zulip.voice")
local failures = 0
local function check(name, ok, detail)
    if not ok then
        failures = failures + 1
        print(("FAIL %s %s"):format(name, detail or ""))
    end
end
config.voice.local_tts = { vim.fn.getcwd() .. "/tests/fake/mac-tts" }
local got
voice.tts({ "aaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbb", "line\nbreak" }, 4, function(err, bundle) got = { err = err, bundle = bundle } end)
vim.wait(20000, function() return got ~= nil end)
check("bundle made", got and got.bundle, vim.inspect(got and got.err))
if got and got.bundle then
    local b = got.bundle
    check("offsets follow each part's length", math.abs(b.offsetsMs[2] - 500) < 80 and math.abs(b.offsetsMs[3] - 1500) < 80, vim.inspect(b.offsetsMs))
    check("first index kept", b.firstIdx == 4)
    check("one valid WAV", require("zulip.local_tts").parse_wav(b.bytes) ~= nil)
    check("duration", math.abs(b.durationMs - 2000) < 120, b.durationMs)
end
local again
voice.tts({ "cc" }, 0, function(err, bundle) again = { err = err, bundle = bundle } end)
vim.wait(10000, function() return again ~= nil end)
check("engine stays loaded for a second request", again and again.bundle, vim.inspect(again and again.err))
-- local speech to text (voice.local_stt): the audio goes over standard input to the stand-in
config.voice.local_stt = { vim.fn.getcwd() .. "/tests/fake/mac-stt" }
local wav = vim.fn.tempname() .. ".wav"
vim.fn.writefile({ "RIFFxxxx" }, wav, "b")
local heard
voice.stt(wav, function(err, text) heard = err or text end)
vim.wait(10000, function() return heard ~= nil end)
check("local stt runs the program with the audio", heard == "heard 8 bytes", vim.inspect(heard))
require("zulip.local_tts").stop()
print(failures == 0 and "local_tts ok" or ("%d failures"):format(failures))
os.exit(failures == 0 and 0 or 1)

--- Options; `require("zulip").setup` overrides them in place.
return {
    --- File with the account's `email`, `key` and `site`, as downloaded from Zulip.
    zuliprc = "~/.zuliprc",
    --- Initial event reconnect delay in milliseconds (kept under its original option name).
    -- 🧑 "nvim zulip plugin delay is quite big on receiving messages"
    refresh_ms = 2000,
    --- How many of the newest messages the sidebar groups into conversations.
    n_recent = 500,
    --- How many of its newest messages a conversation buffer shows.
    n_shown = 100,
    --- Whether a message is marked read once the cursor reaches its last line.
    mark_read = true,
    --- Whether uploaded images and PDFs show inline; `p` in a conversation toggles it.
    previews = true,
    --- Voice service (`docs/voice.md`). Commands run on this machine, or through `via` (e.g. `{ "ssh", "-p", "2222", "localhost" }`) when Neovim runs remotely.
    -- 🧑 "We should separate out the voice services and allow the NeoVim Zulip plugin to also use it."
    voice = {
        --- Private channel the service listens on.
        channel = "voice-relay",
        --- Seconds to wait for one result.
        timeout_s = 60,
        --- Read new messages from others aloud as they arrive.
        autoplay = false,
        --- Prefix for `play_cmd` and `record_cmd`; empty runs them where Neovim runs.
        via = {},
        --- Plays the audio on its standard input.
        play_cmd = { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", "-i", "-" },
        --- Writes WebM to standard output; stops on `q` on standard input. Microphone: macOS `avfoundation`, else PulseAudio.
        record_cmd = { "ffmpeg", "-loglevel", "error", "-f", vim.uv.os_uname().sysname == "Darwin" and "avfoundation" or "pulse", "-i", vim.uv.os_uname().sysname == "Darwin" and ":0" or "default", "-ac", "1", "-ar", "16000", "-t", "120", "-c:a", "libopus", "-f", "webm", "-" },
        --- Buffer-local mappings in conversations and compose buffers; set one to `false` to skip it.
        keys = {
            speak = "gs",
            speak_from = "gS",
            stop = "gh",
            interrupt = "<C-c>",
            autoplay = "gA",
            dictate = "<C-g>",
            compose_dictate = "gd",
        },
    },
    sidebar_width = 40,
    compose_height = 10,
    --- Global mappings; set one to `false` to skip it.
    keys = {
        toggle = "<leader>oz",
    },
}

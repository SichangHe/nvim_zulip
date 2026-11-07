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
        --- Read unread messages from others aloud in the open conversation, as the web client does.
        autoplay = true,
        --- Dictation cuts speech into pieces at pauses of this many milliseconds, or at `max_piece_s` seconds.
        pause_ms = 700,
        max_piece_s = 10,
        --- A 100 ms stretch counts as speech above this root mean square level (16-bit samples) , 3 times the quietest recent level, or a tenth of the recent loudest, whichever is highest.
        silence_rms = 30,
        --- Prefix for `play_cmd` and `record_cmd`; empty runs them where Neovim runs.
        via = {},
        --- Plays the audio on its standard input; must accept `-ss SECONDS` right after the program name.
        play_cmd = { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", "-i", "-" },
        --- Microphone: `auto` (macOS: the first real microphone that delivers a signal, skipping BlackHole, Zoom and the like),
        --- else an `avfoundation` device name such as `MacBook Pro Microphone`, an index, or `default`; `:ZulipVoiceDevice` lists and picks.
        device = "auto",
        --- Overrides the recording command, which must write 16 kHz mono 16-bit samples to standard output and stop on `q` on standard input.
        record_cmd = nil,
        --- Playback speed, 0.5 to 3.0 in steps of 0.1; `play_cmd` must accept `-af` filters for speeds other than 1.
        speed = 1.0,
        --- Keep the chunk being read in view; moving the cursor yourself turns it off until toggled or reading restarts.
        follow = true,
        --- Buffer-local mappings in conversations: every voice action is `prefix` plus its key (`prefix` then `?` lists them);
        --- `interrupt` stops reading on its own, `compose_dictate` toggles dictation in the compose buffer. Set one to `false` to skip it.
        keys = {
            prefix = "gv",
            read = "s",
            pause = "p",
            next_chunk = "]",
            prev_chunk = "[",
            next_message = "}",
            prev_message = "{",
            faster = "+",
            slower = "-",
            follow = "f",
            autoplay = "a",
            dictate = "d",
            stop = "h",
            check = "c",
            log = "L",
            device = "m",
            interrupt = "<C-c>",
            compose_dictate = "<C-g>",
        },
    },
    sidebar_width = 40,
    compose_height = 10,
    --- Global mappings; set one to `false` to skip it.
    keys = {
        toggle = "<leader>oz",
    },
}

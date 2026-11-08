# nvim_zulip

(authored by agents unless marked 🧑)

Read and answer [Zulip](https://zulip.com) messages from Neovim: a sidebar of recent conversations with unread counts, each conversation as a Markdown buffer, and a normal buffer for writing replies.

Needs Neovim 0.11+ and `curl`.

## Install

Download your `zuliprc` file from Zulip (Settings, Account & privacy, API key, "Download zuliprc") and save it as `~/.zuliprc`, readable only by you.

With lazy.nvim:

```lua
{ "SichangHe/nvim_zulip", opts = {} }
```

Options and their defaults are in [`lua/zulip/config.lua`](lua/zulip/config.lua).

## Keys

`<leader>oz` or `:Zulip` shows or hides the sidebar. A conversation is a channel topic, shown as `channel > topic`, or a direct message, shown by the other people's names. The number before it counts its unread messages.

`<CR>` moves one step toward sending:

- sidebar: open the conversation. A `new messages` line shows where they start, with the cursor on it the first time; reentering a conversation resumes where the cursor was left. A message is marked read once the cursor moves past its last line. Your own messages never count as unread
- conversation, normal mode: open the compose buffer
- conversation, `gf` on a task tag such as `[nvim_omnigent]` or `nvim_omnigent.md`: open the channel topic of that name; elsewhere `gf` works as usual
- conversation, visual mode: quote the selection into the compose buffer
- compose buffer, normal mode: send. `:w` also sends

Links to the Zulip server carry its full address, so `gx` or a click opens them. Uploaded images, and the first page of uploaded PDFs (needs `pdftoppm` from Poppler), show inline under their link when [snacks.nvim](https://github.com/folke/snacks.nvim) image support works in your terminal (e.g. Kitty, also through tmux). `p` in a conversation shows or hides these previews. `gx` opens the upload on the cursor line, preferring HTML: with a `viz` command on `PATH` it goes there, else to `vim.ui.open`.

`r` refreshes the sidebar, `R` reloads a conversation; `q` hides the sidebar. Displayed conversations reload on their own when a message arrives, without moving the cursor or scrolling.

While the sidebar is visible, Zulip's event queue delivers message and read-flag changes through long polling. Idle connections fetch no message snapshots. Interrupted connections reconnect automatically and refresh to catch up.

## Voice

Reads agent messages aloud and dictates replies through the voice service (private channel `voice-relay`; the `zuliprc` must be the human's account), like the web client. Needs `ffmpeg` and `ffplay`; on macOS `brew install ffmpeg`, and allow the terminal under System Settings, Privacy & Security, Microphone. `:ZulipVoiceCheck` tests the player, records 4 s and shows what the service heard, and pings the service. `:ZulipVoiceLog` sends the plugin's debug log to the server (`client.log`).

Opening a conversation reads its unread messages from others, oldest first (`autoplay`, on by default; `gA` or `:ZulipAutoplay` toggles). Reading marks messages read forward only: a message is read once it has been spoken. The status line on the conversation window shows the state (idle, loading, playing, paused, recording, transcribing, offline), and the block being read is highlighted and followed.

Keys in a conversation (normal mode; each has a which-key description). The buffer is read-only, so voice actions use insert and change keys, and motion, selection and yank keys (`v`, `V`, `y`, `[`, `]`, `{`, `}`, `f`, `d`...) keep their meaning:

- `i` play from the message under the cursor, or pause and resume (resumes mid-chunk); `r` read from the cursor message; `x` stop (also `<C-c>`)
- `o` `O` next and previous chunk, `a` `A` next and previous message (previous first restarts the current one); presses in quick succession add up; with nothing playing, `O`/`A` replay the last heard chunk/message and `o`/`a` start after it (from the cursor message if nothing was heard)
- `s` `S` playback speed up and down, 0.5 to 3.0 in 0.1 steps (needs a `play_cmd` that accepts `-af`, as `ffplay` does)
- `I` keep the chunk being read in view (on by default; moving the cursor yourself turns it off until `I` or the next play)
- `t` search the thread list and switch (`:ZulipSwitch [name]` too; telescope or fzf-lua are used when installed as `vim.ui.select`)
- `p` open the compose buffer and start dictating; `c` toggle hands-free voice control; `R` reload the conversation
- rare, behind `gv`: `gva` autoplay, `gvc` check, `gvL` send the log, `gvm` choose the microphone

Hands-free voice control (`c`) keeps the microphone open. Say "pause" (fuzzy: "paws", "pose"...) and reading pauses, a ready tone plays, and what you say next is typed live into the compose buffer. End with "over" (or "over and out") and about a second of silence, or just keep quiet for 6 s: the reply is sent, a done tone plays, and reading resumes. "Pause" with nothing after it resumes after 8 s. "Pause back" (or "previous", "again") replays the previous chunk, "pause previous message" the previous message, "pause next" and "pause next message" go forward; said alone inside an open reply they act as commands and keep the draft unsent. "Pause, switch to terminal viz" (or "go to", "open") opens the thread by fuzzy name; if several match, the top three are shown and "first", "second" or "third" picks one. Speech without the start word is ignored. Playback volume is untouched, so speakers can bleed into the microphone: use headphones. Words and times are `voice.start_word`, `end_word`, `long_silence_s` and `empty_s`.

Dictation, in the compose buffer: `<C-g>` (normal mode only) starts and stops recording, `<Esc>` in normal mode cancels, `<CR>` while recording (also in insert mode) stops, waits for every piece and sends once. Each piece keeps 1.2 s of audio from before the first word. The winbar shows `● Recording` with the time and level, then `Transcribing…`. Speech is cut at pauses and each piece appears at the cursor as it is transcribed, so the buffer is a live preview. Playback pauses while dictating. Otherwise `<CR>` sends. Stopping always sends the rest of the recording; if no speech passed the level threshold the whole recording is sent. Missing `ffmpeg`, microphone errors and service errors show as notifications.

A new message from someone else with a `[switch: TASK]` line opens that task's conversation once it has been read aloud; the line is hidden.

Voice settings (autoplay, speed, follow, voice control on/off, microphone, start and end words, silence times) are remembered in `stdpath("state")/zulip_voice.json`; options you pass to `setup` win over them. Options are `voice` in [`config.lua`](lua/zulip/config.lua): `play_cmd` (must accept `-ss SECONDS` after the program name), `record_cmd`, `device`, `pause_ms`, `silence_rms`. On macOS `voice.device = "auto"` (default) picks the first real microphone (names with "Microphone" first; BlackHole, Zoom, Loopback and similar virtual devices are skipped) that delivers a signal, probing each for 0.5 s once. To choose by name: `voice = { device = "MacBook Pro Microphone" }`, or `:ZulipVoiceDevice` to list and pick (`:ZulipVoiceDevice NAME` sets one). A microphone that delivers only zeros is reported with the device list, and the next dictation probes again.

If Neovim runs on a remote machine without audio, set `voice.via = { "ssh", "-p", "2222", "localhost" }` with `RemoteForward 2222 localhost:22` in the laptop's SSH config, so the audio commands run on the laptop.

## Limits

- The sidebar lists only conversations among the newest `n_recent` messages, and a conversation shows only its newest `n_shown` messages.
- Muted channels and topics are listed like the others.
- No starting a new topic or direct message, no editing, reactions or uploading.

## Develop

`ZULIPRC=<the human's zuliprc> nvim -l tests/voice.lua` checks voice against the live service. `env -u ZULIPRC nvim -l tests/run.lua` checks rendering and cursor/read behavior offline; `nvim -l tests/events.lua` checks event delivery, reconnects, and request races through a local HTTP server. `ZULIPRC=path nvim -l tests/run.lua` also runs against the live server and sends one direct message from the account to itself. Design notes are in [`docs/design.md`](docs/design.md).

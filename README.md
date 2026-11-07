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

- sidebar: open the conversation. A `new messages` line shows where they start, with the cursor on it the first time; reentering a conversation resumes where the cursor was left. A message is marked read when the cursor reaches its last line
- conversation, normal mode: open the compose buffer
- conversation, `gf` on a task tag such as `[nvim_omnigent]` or `nvim_omnigent.md`: open the channel topic of that name; elsewhere `gf` works as usual
- conversation, visual mode: quote the selection into the compose buffer
- compose buffer, normal mode: send. `:w` also sends

Links to the Zulip server carry its full address, so `gx` or a click opens them. Uploaded images, and the first page of uploaded PDFs (needs `pdftoppm` from Poppler), show inline under their link when [snacks.nvim](https://github.com/folke/snacks.nvim) image support works in your terminal (e.g. Kitty, also through tmux). `p` in a conversation shows or hides these previews. `gx` opens the upload on the cursor line, preferring HTML: with a `viz` command on `PATH` it goes there, else to `vim.ui.open`.

`r` refreshes the sidebar or reloads the conversation; `q` hides the sidebar. Displayed conversations reload on their own when a message arrives, without moving the cursor or scrolling.

While the sidebar is visible, Zulip's event queue delivers message and read-flag changes through long polling. Idle connections fetch no message snapshots. Interrupted connections reconnect automatically and refresh to catch up.

## Voice

Reads agent messages aloud and dictates replies through the voice service (private channel `voice-relay`; the `zuliprc` must be the human's account), like the web client. Needs `ffmpeg` and `ffplay`; on macOS `brew install ffmpeg`, and allow the terminal under System Settings, Privacy & Security, Microphone. `:ZulipVoiceCheck` tests the player, records 4 s and shows what the service heard, and pings the service. `:ZulipVoiceLog` sends the plugin's debug log to the server (`client.log`).

Opening a conversation reads its unread messages from others, oldest first (`autoplay`, on by default; `gA` or `:ZulipAutoplay` toggles). Reading marks messages read forward only: a message is read once it has been spoken. The status line on the conversation window shows the state (idle, loading, playing, paused, recording, transcribing, offline), and the block being read is highlighted and followed.

Keys in a conversation, all behind `g`:

- `gs` read from the message under the cursor, then the later messages of others; `gp` pause or resume (or continue where reading last stopped)
- `g]` `g[` next and previous chunk, `g}` `g{` next and previous message (previous first restarts the current one); presses in quick succession add up
- `gh` or `<C-c>` stop and cancel a pending switch
- `gd` open the compose buffer and start dictating

Dictation, in the compose buffer: `<C-g>` (normal or insert) starts and stops recording, `<Esc>` in normal mode cancels. The winbar shows `● Recording` with the time and level, then `Transcribing…`. Speech is cut at pauses and each piece appears at the cursor as it is transcribed, so the buffer is a live preview. Playback pauses while dictating. After stopping, `<CR>` sends. Stopping always sends the rest of the recording; if no speech passed the level threshold the whole recording is sent. Missing `ffmpeg`, microphone errors and service errors show as notifications.

A new message from someone else with a `[switch: TASK]` line opens that task's conversation once it has been read aloud; the line is hidden.

Options are `voice` in [`config.lua`](lua/zulip/config.lua): `play_cmd` (must accept `-ss SECONDS` after the program name), `record_cmd`, `pause_ms`, `silence_rms`. On macOS the microphone is `avfoundation` device `:0` (the first one `:ZulipVoiceCheck` lists); change `:0` in `record_cmd` to pick another.

If Neovim runs on a remote machine without audio, set `voice.via = { "ssh", "-p", "2222", "localhost" }` with `RemoteForward 2222 localhost:22` in the laptop's SSH config, so the audio commands run on the laptop.

## Limits

- The sidebar lists only conversations among the newest `n_recent` messages, and a conversation shows only its newest `n_shown` messages.
- Muted channels and topics are listed like the others.
- No starting a new topic or direct message, no editing, reactions or uploading.

## Develop

`ZULIPRC=<the human's zuliprc> nvim -l tests/voice.lua` checks voice against the live service. `env -u ZULIPRC nvim -l tests/run.lua` checks rendering and cursor/read behavior offline; `nvim -l tests/events.lua` checks event delivery, reconnects, and request races through a local HTTP server. `ZULIPRC=path nvim -l tests/run.lua` also runs against the live server and sends one direct message from the account to itself. Design notes are in [`docs/design.md`](docs/design.md).

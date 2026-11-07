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

Reads messages aloud and dictates replies through the voice service (private channel `voice-relay`; the `zuliprc` must be the human's account). Needs `ffmpeg`/`ffplay` wherever the audio is played and recorded.

- conversation: `gs` reads the message under the cursor, `gS` the conversation from there on, `gh` stops, `gA` or `:ZulipAutoplay` toggles reading new messages from others, `gd` opens the compose buffer and starts dictating
- compose buffer: `<C-g>` (normal or insert) starts recording and stops it; the transcript is inserted at the cursor
- a new message from someone else ending in `[switch: TASK]` opens that task's conversation, after it is read aloud if reading

Neovim over SSH has no speakers or microphone, so run the audio commands on the laptop through a reverse tunnel. In `~/.ssh/config` on the laptop add `RemoteForward 2222 localhost:22` for the host, enable Remote Login on macOS, install `ffmpeg` with Homebrew, then:

```lua
opts = { voice = {
    via = { "ssh", "-p", "2222", "localhost" },
    play_cmd = { "/opt/homebrew/bin/ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", "-i", "-" },
    record_cmd = { "/opt/homebrew/bin/ffmpeg", "-loglevel", "error", "-f", "avfoundation", "-i", ":0", "-ac", "1", "-ar", "16000", "-t", "120", "-c:a", "libopus", "-f", "webm", "-" },
} }
```

Without `via`, the defaults play and record on the machine running Neovim (PulseAudio).

## Limits

- The sidebar lists only conversations among the newest `n_recent` messages, and a conversation shows only its newest `n_shown` messages.
- Muted channels and topics are listed like the others.
- No starting a new topic or direct message, no editing, reactions or uploading.

## Develop

`ZULIPRC=<the human's zuliprc> nvim -l tests/voice.lua` checks voice against the live service. `env -u ZULIPRC nvim -l tests/run.lua` checks rendering and cursor/read behavior offline; `nvim -l tests/events.lua` checks event delivery, reconnects, and request races through a local HTTP server. `ZULIPRC=path nvim -l tests/run.lua` also runs against the live server and sends one direct message from the account to itself. Design notes are in [`docs/design.md`](docs/design.md).

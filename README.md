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

- sidebar: open the conversation; this marks its messages read
- conversation, normal mode: open the compose buffer
- conversation, visual mode: quote the selection into the compose buffer
- compose buffer, normal mode: send. `:w` also sends

`r` refreshes the sidebar or reloads the conversation; `q` hides the sidebar. Displayed conversations reload on their own when a message arrives.

## Limits

- The sidebar lists only conversations among the newest `n_recent` messages, and a conversation shows only its newest `n_shown` messages.
- Muted channels and topics are listed like the others.
- No starting a new topic or direct message, no editing, reactions or uploads.

## Develop

`ZULIPRC=path nvim -l tests/run.lua` runs the checks against the live server; it sends one direct message from the account to itself. Design notes are in [`docs/design.md`](docs/design.md).

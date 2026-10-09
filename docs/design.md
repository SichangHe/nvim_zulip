# Design

(authored by agents unless marked 🧑)

🧑 request: "Yes have an agent build a Zulip nvim integration"

modules in `lua/zulip/`
- `config`: option table; `setup` overrides it in place
- `api`: async calls to the Zulip REST API through `curl`
    - `on_done(err, result)` on the main loop; errors are returned, not thrown
    - `connect`: reads `zuliprc`, then `GET /users/me` for the account's user id; runs once
    - key reaches `curl` as a `-K -` config on standard input
        - why: command arguments are visible to other users of the machine
    - Zulip answers errors as JSON `result = "error"`; `msg` becomes `err`
- `sidebar`: owns the conversation list, its buffer, the refresh timer
    - one `GET /messages` for the newest `n_recent` messages, grouped by `conversations`
        - why not the event queue or `POST /register`: polling one route gives list, order and unread counts with no state to keep
        - unread: message without the `read` flag
    - conversation: channel topic `{ stream_id, topic }` or direct message `{ user_ids }`
        - `key`: `STREAM_ID/TOPIC` with the topic in lower case, or sorted user ids joined by `,`; unique, so buffer names start with it
    - `refreshing` skips a timer tick while a reply is awaited, so replies cannot arrive out of order
    - each refresh calls `conversation.reload_changed`
    - timer runs only while the sidebar is shown; a failed `connect` stops it
- `conversation`: message buffer and compose buffer per conversation key
    - `load`: `GET /messages` narrowed by `channel` + `topic` or `dm`, `apply_markdown = false` so content is the Markdown as written
        - then `POST /messages/flags` adds `read`, unless `mark_read = false`
        - new-messages marker: a line above the first message without the `read` flag
            - `b:zulip_new_id` keeps that message across reloads, because marking read clears the flags; a later unread batch moves it
            - a cursor on the last line moves to the marker when the load found unread messages, else to the new last line
        - narrow operators `channel` and `dm` need Zulip server 9+
    - `reload_changed`: reloads a displayed buffer when `b:zulip_newest_id` differs from the list's `newest_id`
    - `compose`: one `acwrite` buffer; `BufWriteCmd` sends, so `:w` works
    - `send`: `POST /messages`, `type` `stream` or `direct`; then deletes the compose buffer and reloads

tests
- `tests/run.lua`: pure checks, then sidebar, open, compose, send, quote against the live server
    - sends to the account itself; `mark_read = false` so a bot account's flags stay untouched

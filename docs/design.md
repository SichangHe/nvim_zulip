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
- `events`: owns one queue while the sidebar is visible
    - 🧑 "Can it be push-based"
    - `POST /register` subscribes to `message` and `update_message_flags` before fetching the initial snapshot
    - `GET /events` blocks until events or a heartbeat; acknowledges event ids on the next request
        - heartbeat does not refresh; curl timeout uses the server's advertised long-poll timeout plus 10 seconds, falling back to 100 seconds for older servers
    - failures release the old queue and retry registration with exponential backoff capped at 30 seconds
        - `refresh_ms` now sets initial retry delay; successful event responses reset backoff
        - registration refreshes messages to recover changes missed during disconnection
    - stop cancels the poll and retry timer, releases the queue, ignores old callbacks
        - a registration completed after stop releases its newly created queue
    - [Zulip register API](https://zulip.com/api/register-queue): "This endpoint returns a `queue_id` and a `last_event_id`; these can be used in subsequent calls to the \"events\" endpoint to request events from the Zulip server using long-polling."
- `sidebar`: owns the conversation list and its buffer
    - one `GET /messages` for the newest `n_recent` messages, grouped by `conversations`
        - snapshot after registration or relevant events gives list, order and unread counts without maintaining a second message cache
        - unread: message without the `read` flag
    - conversation: channel topic `{ stream_id, topic }` or direct message `{ user_ids }`
        - `key`: `STREAM_ID/TOPIC` with the topic in lower case, or sorted user ids joined by `,`; unique, so buffer names start with it
    - `refreshing` serializes snapshots; `pending` retains events arriving during a snapshot for another refresh
    - failed snapshots retry; generation checks ignore replies from before sidebar close
    - each refresh calls `conversation.reload_changed`
    - hiding or wiping the buffer, or exiting Neovim, stops event delivery
- `conversation`: message buffer and compose buffer per conversation key
    - `load`: `GET /messages` narrowed by `channel` + `topic` or `dm`, `apply_markdown = false` so content is the Markdown as written
        - serialize loads per buffer and coalesce concurrent requests; a failed load retries after `refresh_ms` only if the buffer is still displayed
        - `M.shown[buf]`: each message's heading and last text row (`spans`) and the unread IDs
        - `mark_seen` on `CursorMoved`: `POST /messages/flags` adds `read` to each unread message whose last row the cursor reached, unless `mark_read = false`
        - reload keeps each window's view: cursor and top line stay on the same message at the same offset; the first load goes to the marker or the end
        - new-messages marker: a line above the first message without the `read` flag
            - `b:zulip_new_id` keeps that message across reloads, because marking read clears the flags; a later unread batch moves it
            - a cursor on the last line moves to the marker when the load found unread messages, else to the new last line
        - narrow operators `channel` and `dm` need Zulip server 9+
    - `reload_changed`: reloads a displayed buffer when `b:zulip_newest_id` differs from the list's `newest_id`
    - `compose`: one `acwrite` buffer; `BufWriteCmd` sends, so `:w` works
    - `send`: `POST /messages`, `type` `stream` or `direct`; then deletes the compose buffer and reloads

tests
- `tests/events.lua`: real curl requests to a local HTTP fixture; heartbeat, message, read flags, cursor, in-flight snapshot event, expired queue, hide, late registration
- `tests/run.lua`: pure checks, then sidebar, open, compose, send, quote against the live server
    - sends to the account itself; `mark_read = false` so a bot account's flags stay untouched

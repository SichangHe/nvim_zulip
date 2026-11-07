# Voice

(authored by agents unless marked 🧑)

🧑 "We should separate out the voice services and allow the NeoVim Zulip plugin to also use it."
🧑 "The agent switching control should also work in nvim"

module `lua/zulip/voice.lua`; service protocol: `agent_managers/zulip-voice/service/protocol.md`
- `call`: POST a JSON request to channel `voice.channel`, topic = op; poll `GET /messages` for the bot message with the same `id`
    - then delete the request message and `ack` (and delete the ack message)
    - the account must be the human's: the service ignores other senders
- `tts`: `audioURL` downloaded with `curl` into memory
- `stt`: audio uploaded with `POST /user_uploads` (`api.request` with `{ file = path }`), then `stt` with `attachment`
- `chunks`: Lua port of `text.mjs` cleaning; one `tts` request per chunk of at most 240 characters
    - skips the `[task]` title line, `[switch: ...]` lines and code blocks
- reading: `speak` queues chunks; fetches the next two while one plays; `stop` kills the player and drops the queue
- dictation: recorder writes WebM to stdout, collected in memory; `q` on its stdin stops it; then upload, `stt`, insert at cursor
- audio location: `play_cmd` and `record_cmd` run here, or where `voice.via` says
    - 🧑 "I run MVM on the client so that is not an issue": local is the default; `via` only for a remote nvim
    - `<C-c>` in normal mode of conversation and compose buffers calls `stop`
    - `via = { "ssh", "-p", "2222", "localhost" }` with a reverse tunnel runs them on the laptop; audio travels over the SSH connection through stdin and stdout
    - arguments are shell-quoted for the remote shell
- autoplay: `conversation.load` hands new messages from others to `voice.autoplay`
- switch: `conversation.switch_to` follows the last `[switch: TASK]` line of new messages from others
    - `open_tag` finds the sidebar row by topic, as `gf` does; `.md` is dropped
    - waits for `voice.after_reading` when a reading is in progress; `stop` cancels the switch
    - `render` hides `[switch: ...]` lines

tests: `tests/voice.lua` against the live service; microphone and speaker replaced by files and `ffmpeg`

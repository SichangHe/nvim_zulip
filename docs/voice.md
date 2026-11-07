# Voice

(authored by agents unless marked 🧑)

🧑 "We should separate out the voice services and allow the NeoVim Zulip plugin to also use it."
🧑 "The agent switching control should also work in nvim"
🧑 "Ideally, the experience would be similar to the web." (model: `agent_managers/zulip-voice/v2/design.md`)

`lua/zulip/voice.lua`: service client and dictation; protocol `agent_managers/zulip-voice/service/protocol.md`
- one event queue (`events.start` with `name = "voice"`, narrowed to the relay channel) delivers results and bundles
    - `call`: POST a JSON request to topic = op; a waiter keyed by request id gets the bot's result; no polling, no deletes or acks (the service sweeps)
    - proactive results with `bundle` are kept in `M.bundles` by message id; read back from topic `tts` after each registration
- `tts(texts, first_idx)`: one request, several chunks, one AAC bundle with `offsetsMs`; `fetch` downloads it, minting a new link when older than 50 s
- `stt`: `POST /user_uploads` (`api.request` with `{ file = path }`), then `stt` with `attachment`
- `blocks`/`chunks`: Lua port of `text.mjs`; blocks keep their line range for highlighting
- dictation: recorder writes 16 kHz 16-bit samples to stdout; `q` on stdin stops it
    - frames of 100 ms: level by root mean square; speech piece cut after `pause_ms` of quiet or `max_piece_s`
    - each piece becomes a WAV, uploaded and transcribed; results go in order to an extmark that follows the insertion
    - finishes when the recorder has exited and its output is read (`settle`); `<Esc>` cancels
    - `player.hold` pauses reading meanwhile
- speech level: threshold is the highest of `silence_rms`, 3 times a tracked quiet floor and a tenth of the decaying peak; on stop the remainder is always sent, and the whole recording when nothing passed
- microphone: `resolve_device`; `auto` on macOS lists avfoundation devices, drops virtual ones, probes candidates for 0.5 s and caches the first with a nonzero signal; all-zero capture clears the cache and reports with the device list
- `log`: in-memory ring of 400 lines (frames, levels, cuts, uploads, transcripts, insertions); `:ZulipVoiceLog` sends it with the relay `log` op
- a request also reads its own topic every 2.5 s (`FALLBACK_MS`), because the event queue can lose results across reconnects; registration backfills the whole channel
- `send_when_done` (`<CR>` while recording): flags the session, stops the recorder; `close` writes the buffer once every piece is in
- `check` (`:ZulipVoiceCheck`): plays 0.3 s of silence, records 4 s, transcribes it, pings the service

`lua/zulip/player.lua`: reading
- run: queue of items (message, blocks, chunks); `i` item, `idx` 0-based chunk, `state`
- a bundle plays in one `play_cmd` process started with `-ss` at the chunk's offset; a 100 ms timer maps elapsed time to the chunk for highlight and `last`
    - next bundle (or the next message's first) is fetched while one plays; with no pre-rendered bundle one `tts` request covers up to 6 chunks
- message end calls `mark(id)`, which marks it and earlier unread messages read (forward only)
- `autoplay`: unread messages of others, queued once per message id; ignored while dictating
- steps (`step_chunk`, `step_message`) move the position at once and restart after 250 ms, so quick presses add up
- speed: `atempo` filters (two chained above 2.0) passed with `-ss`; elapsed time scales by speed; changing it restarts the chunk
- follow: each chunk change moves the cursor to its block when `run.following`; a `CursorMoved` not caused by the player turns it off
- keys: `gv` + action letter, built from one table in `conversation.open`
- status line: winbar of conversation windows from `status_line`
- `after_reading` runs `conversation.switch_to` once the queue ends; `stop` cancels it

audio location: `play_cmd` and `record_cmd` run here, or where `voice.via` says
- 🧑 "I run MVM on the client so that is not an issue": local is the default; `via` for a remote nvim

tests: `tests/voice.lua` against the live service; speaker and microphone replaced by files and `ffmpeg`

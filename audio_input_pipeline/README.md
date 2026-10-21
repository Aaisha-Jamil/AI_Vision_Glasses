# Audio Input Pipeline

Backend for the audio part of **Privacy-Preserving Smart Glasses for Automated Seminar &
Workshop Synthesis**. It takes live lecture audio, turns it into timestamped text, flags
off-topic speech (side talk, mic checks, announcements), lets the user review those flags,
and produces a clean transcript for note generation. Data is stored in Supabase
(PostgreSQL + pgvector), and the audio of each chunk is stored in Supabase Storage.

The mobile app (Flutter) is a separate project. This repository contains only the backend.
The [Client integration guide](#client-integration-guide) explains how an app connects to it.

---

## Contents

- [Features](#features)
- [How it works](#how-it-works)
- [Tech stack](#tech-stack)
- [Project structure](#project-structure)
- [Setup](#setup)
- [Configuration](#configuration)
- [API reference](#api-reference)
- [Data model](#data-model)
- [Client integration guide](#client-integration-guide)
- [Noise detection](#noise-detection)
- [Limits and known limitations](#limits-and-known-limitations)
- [Developer tools](#developer-tools)
- [Security](#security)

---

## Features

**Audio intake**
- Three input sources:
  - a client streams microphone audio over a WebSocket (used by the mobile app and the browser console),
  - the server's own microphone,
  - a WAV file played in real time (for repeatable tests).
- Pause-aware chunking: audio is cut into 3–7 second chunks at natural pauses, so words
  are not split between chunks.
- Adaptive microphone warm-up: the noisy first seconds after a mic opens are discarded
  until real silence is detected (3–10 s).
- Clicks, taps and silent chunks are filtered out before transcription.
- Every chunk is saved to disk before transcription, so no audio is lost if a later step fails.

**Speech-to-text**
- Groq Whisper `whisper-large-v3`. Urdu and mixed Urdu-English speech is returned as English text.
- Local `faster-whisper` is used automatically as a fallback if Groq is unavailable.
- A hallucination guard drops low-confidence segments and the phrases Whisper is known
  to invent from noise (for example "Thank you.").
- The live transcript is pushed to clients over a WebSocket as each chunk is transcribed.

**Noise detection** (runs when the session ends)
- Sentence embeddings (`all-MiniLM-L6-v2`, 384 dimensions) and cosine similarity
  against the session topic and the lecture itself.
- **NOISE**: a whole chunk is off-topic.
- **MIXED**: a chunk mixes lecture and side talk. Only the off-topic sentence is removed
  from the notes; the rest of the chunk is kept.
- **Topic guard**: if a whole session does not match the chosen topic, the client gets a warning.
- Optional LLM mode (`openai/gpt-oss-20b` on Groq) that gives a reason for each flag.

**Review**
- Keep, Dismiss or Edit any flagged chunk. Edits never overwrite the original transcript,
  and an edit can be undone.
- Unflagged chunks are kept automatically. Only flagged chunks wait for review.

**Output and storage**
- A clean transcript endpoint returns the text that should go into the notes.
- Chunks are grouped into 10-minute containers for timelines and topic-drift views.
- All data is stored in Supabase Postgres with pgvector, and each chunk's audio is uploaded
  as lossless FLAC to a private Supabase Storage bucket.
- A browser test console is served at `/`.

---

## How it works

```
Client mic ──PCM──► /ws/audio ─┐
Server mic ────────────────────┼─► mic warm-up ─► pause-based chunker (3–7 s) ─► WAV on disk
WAV file (tests) ──────────────┘                                                 │
                                                                                 ▼
                    silence/click filter ─► Groq Whisper (local fallback) ─► hallucination guard
                                                                                 │
                       ┌─────────────────────────────────────────────────────────┤
                       ▼                                                         ▼
          INSERT audio_chunks row                         "transcript" event ─► /ws/transcript
                       │
                       ▼ (background)
          FLAC upload to Supabase Storage, audio_filepath = supabase://...

Session stop ─► noise detection (embeddings, topic guard, MIXED sentences)
             ─► flags + status saved per chunk ─► "noise_alert" / "mixed_alert" events
             ─► 10-minute containers ─► session COMPLETED
             ─► user review (Keep / Dismiss / Edit) ─► clean transcript for notes
```

---

## Tech stack

| Area | Technology |
|---|---|
| API server | Python, FastAPI, Uvicorn, WebSockets |
| Audio capture and processing | sounddevice, NumPy, SciPy, PyAV (FLAC) |
| Speech-to-text | Groq Whisper `whisper-large-v3`; `faster-whisper` as local fallback |
| Embeddings | sentence-transformers `all-MiniLM-L6-v2` (runs locally on CPU) |
| Optional LLM noise mode | Groq `openai/gpt-oss-20b` |
| Database | Supabase PostgreSQL + pgvector (psycopg 3, connection pool) |
| Audio storage | Supabase Storage (private bucket, via HTTPS API) |

---

## Project structure

```
audio_input_pipeline/
├── main.py                 FastAPI app: REST endpoints and WebSockets
├── audio_pipeline.py       capture, warm-up, chunking, STT worker, upload worker, session flush
├── stt.py                  Groq Whisper + local fallback + hallucination guard
├── semantic.py             embeddings, noise / MIXED scoring, topic guard
├── llm_filter.py           optional LLM noise classifier
├── db.py                   Postgres access (Supabase)
├── storage.py              FLAC encoding and Supabase Storage upload
├── schema_postgres.sql     database schema (single source of truth)
├── supabase_storage.sql    creates the private audio bucket
├── static/index.html       browser test console
├── tools/                  command-line test helpers
├── requirements.txt
└── .env.example            configuration template
```

`data/` (local chunk recordings) and `.env` (secrets) are created locally and are not
committed.

---

## Setup

### 1. Requirements
- Python 3.10 or newer (developed and tested on Python 3.12, Windows 10).
- A Groq API key (free tier works): <https://console.groq.com/keys>
- A Supabase project: <https://supabase.com>

### 2. Install

```bash
cd audio_input_pipeline
python -m venv .venv
# Windows:      .venv\Scripts\activate
# macOS/Linux:  source .venv/bin/activate
pip install -r requirements.txt
```

The first start downloads the embedding model (about 90 MB) to the Hugging Face cache.

### 3. Supabase
1. Create a project. Pick the region closest to your users; from Pakistan, Mumbai
   (`ap-south-1`) was about 5 times faster per query than Sydney.
2. Open **SQL Editor**, paste `schema_postgres.sql`, and run it. This creates all tables,
   pgvector and row-level security.
3. In **SQL Editor**, run `supabase_storage.sql`. This creates the private bucket `lecture-audio`.
4. Copy the database connection string: **Connect → Transaction pooler** (or Session
   pooler), and replace `[YOUR-PASSWORD]` with your database password.
5. Copy the **service_role** key: **Project Settings → API Keys → Legacy API Keys**. It starts
   with `eyJ`. Keep it on the server only.

### 4. Configure

```bash
cp .env.example .env      # Windows: copy .env.example .env
```

Fill in `GROQ_API_KEY`, `DATABASE_URL`, `SUPABASE_URL` and `SUPABASE_SECRET_KEY`.

### 5. Run

```bash
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

- `--host 0.0.0.0` lets a phone on the same Wi-Fi network connect.
- Health check: <http://localhost:8000/health> should show `"database": "postgres"` and
  `"audio_storage": "supabase"`.
- Interactive API docs: <http://localhost:8000/docs>
- Browser test console: <http://localhost:8000/>. Browsers allow microphone access only
  on `localhost` or HTTPS.

On startup the server checks that every table and column in `schema_postgres.sql` exists,
and stops with a clear message if anything is missing.

---

## Configuration

All settings are read from `.env`. The values below are those in `.env.example`.

| Variable | Default | Meaning |
|---|---|---|
| `GROQ_API_KEY` | — | Groq API key (required for cloud STT) |
| `STT_PROVIDER` | `groq` | `groq` (local fallback on failure) or `local` |
| `GROQ_STT_MODEL` | `whisper-large-v3` | Groq Whisper model |
| `LOCAL_STT_MODEL` | `base` | faster-whisper fallback model (`tiny`, `base`, `small`) |
| `MIN_CHUNK_SECONDS` / `MAX_CHUNK_SECONDS` | `3` / `7` | chunk length range (see [Limits](#limits-and-known-limitations)) |
| `NOISE_SCORING` | `two_pass` | `two_pass`, `seed_only` or `llm` |
| `NOISE_LLM_MODEL` | `openai/gpt-oss-20b` | model for `llm` mode |
| `FLUSH_INTERVAL_SECONDS` | `0` | `0` = detect noise once when the session ends; `N` = also every N seconds |
| `SENTENCE_THRESHOLD` | `0.20` | a sentence below this similarity makes its chunk MIXED |
| `CONTAINER_SECONDS` | `600` | container length in seconds |
| `DATABASE_URL` | — | Supabase Postgres connection string (required) |
| `SUPABASE_URL` | — | Supabase project URL; empty = audio stays on local disk |
| `SUPABASE_SECRET_KEY` | — | service_role key for Storage uploads |
| `AUDIO_BUCKET` | `lecture-audio` | Storage bucket name |

Advanced settings with code defaults: `PAUSE_SECONDS` (0.4), `SILENCE_RMS` (150),
`MIC_WARMUP_MIN_SECONDS` (3), `MIC_WARMUP_MAX_SECONDS` (10), `COLD_THRESHOLD` (0.28),
`NOISE_THRESHOLD` (0.40), `TOPIC_GUARD` (0.20), `CENTROID_OLD_WEIGHT` (0.6),
`MIN_AVG_LOGPROB` (-1.0).

---

## API reference

Base URL: `http://<server-ip>:8000`. All bodies are JSON.

### REST

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Server status and active configuration |
| POST | `/api/v1/session/start` | Start a recording session |
| POST | `/api/v1/session/stop` | Stop the session, run noise detection, return a summary |
| GET | `/api/v1/session/{session_id}/chunks` | All chunks of a session |
| GET | `/api/v1/session/{session_id}/flagged` | Review list: NOISE and MIXED chunks |
| GET | `/api/v1/session/{session_id}/clean-transcript` | Text for note generation |
| GET | `/api/v1/session/{session_id}/containers` | 10-minute containers |
| PATCH | `/api/v1/chunk/{chunk_id}/override` | Keep / Dismiss / reset a chunk |
| PATCH | `/api/v1/chunk/{chunk_id}/text` | Edit a chunk's text, or undo the edit |
| GET | `/api/v1/transcript/buffer` | Chunks transcribed but not yet scored (debugging) |

**Start a session.** `POST /api/v1/session/start`

```json
{
  "title": "Lecture 2026-10-22",
  "seminar_topic": "Machine Learning: KNN and supervised learning",
  "source": "browser"
}
```

| Field | Values | Notes |
|---|---|---|
| `title` | text | Shown in the database; default `"Untitled Lecture"` |
| `seminar_topic` | text | Used for noise detection. A specific topic gives better results |
| `source` | `"browser"` or `"server_mic"` | `"browser"` = the client streams audio to `/ws/audio` |
| `warmup` | `true`, `false` or omitted | Mic warm-up; on by default for microphone sources |
| `device` | integer or omitted | Server microphone index (`server_mic` only) |
| `source_file` | server path or omitted | Testing: play a 16 kHz mono WAV instead of a microphone |

Response:
```json
{ "session_id": "5874caf6-71ed-4ea7-9c77-94bda44da2f7", "title": "...",
  "seminar_topic": "...", "status": "ACTIVE" }
```
The server generates the `session_id` (UUID4). It returns `409` if a session is already active.

**Stop a session.** `POST /api/v1/session/stop` (no body)

```json
{ "session_id": "...", "status": "COMPLETED",
  "chunks_transcribed": 13, "chunks_flagged": 3, "chunks_mixed": 0,
  "topic_match": 0.57, "topic_guard": false }
```
If `topic_guard` is `true`, the session did not match the chosen topic. Show the user a
warning and suggest checking the topic. Returns `409` if no session is active.

**Chunk object** (returned by the chunk, flagged, override and text endpoints):

```json
{
  "chunk_id": "…", "index": 15,
  "start_timestamp": 1761078057.7, "end_timestamp": 1761078061.2,
  "transcript": "I have to go home. I am hungry.",
  "provider": "groq",
  "cosine_similarity": 0.19,
  "is_noise": true, "is_mixed": false,
  "reason": null,
  "off_topic": [],
  "edited_text": null,
  "user_override": "PENDING",
  "container_index": 0
}
```
- Timestamps are epoch seconds from the server clock.
- `off_topic` lists the sentences of a MIXED chunk that are removed from the notes.
- `edited_text` is the user's correction; `transcript` always keeps the original text.

**Review actions**

- `PATCH /api/v1/chunk/{id}/override` with `{"status": "KEPT"}`, `{"status": "DELETED"}`
  or `{"status": "PENDING"}`. The SRS values `KEEP` and `DISMISS` are also accepted.
- `PATCH /api/v1/chunk/{id}/text` with `{"text": "corrected text"}` saves the edit and keeps
  the chunk. `{"text": null}` undoes the edit. Empty text returns `422`; use `DELETED` to
  drop a chunk.

Both actions return the updated chunk object, and `404` if the chunk does not exist.

**Clean transcript.** `GET /api/v1/session/{id}/clean-transcript`

```json
{ "session_id": "…", "title": "…", "seminar_topic": "…", "chunks": 11,
  "clean_text": "Hello everyone, today we are going to be talking about …",
  "items": [ { …chunk object…, "clean_text": "…" } ] }
```

### WebSockets

**`/ws/transcript`**: live events, sent from the server to every connected client. Connect
before starting a session. The client does not need to send anything.

| `type` | When | Main fields |
|---|---|---|
| `session_started` | after start | `session_id`, `title`, `seminar_topic` |
| `mic_status` | mic warm-up | `status`: `calibrating` (with `max_seconds`) or `ready` |
| `transcript` | each transcribed chunk | `chunk_id`, `index`, `start_offset`, `end_offset`, `transcript`, `provider`, `stt_ms` |
| `noise_alert` / `mixed_alert` | noise detection | chunk fields + `cosine_similarity`, `reason`, `off_topic` |
| `topic_mismatch` | topic guard fired | `seminar_topic`, `topic_match` |
| `buffer_flushed` | after noise detection | `chunks`, `flagged`, `mixed`, `mode`, `threshold`, `topic_guard` |
| `session_stopped` | after stop | `session_id` |
| `override_updated` / `chunk_edited` | after a review action | the updated chunk object |

**`/ws/audio`**: audio upload for `source: "browser"`. Send **binary** frames containing
**16 kHz, mono, signed 16-bit little-endian PCM**. 100 ms frames (3,200 bytes) are
recommended. The server closes the socket with code `1008` if no browser-source session is
active, and with `1000` when the session ends.

**`/ws/test`**: echo socket for checking connectivity.

---

## Data model

The full schema is in `schema_postgres.sql`. It contains the SRS section 7.2 tables plus
the audio additions.

| Table | Content |
|---|---|
| `sessions` | one row per lecture: title, topic, topic vector, status, start/end time, topic-guard result |
| `audio_chunks` | one row per transcribed chunk: times, transcript, audio path, embedding, flags, review status, edit |
| `audio_containers` | 10-minute groups: counts, centroid embedding, topic similarity |
| `image_snapshots`, `ocr_extractions`, `generated_notes` | vision and notes modules (other team members) |

Each chunk has a review status (`user_override_status`):

| Status | Meaning |
|---|---|
| `PENDING` | not scored yet (during recording), or flagged and waiting for review |
| `KEEP` | not flagged (set automatically), or kept or edited by the user |
| `DISMISS` | removed by the user; the row is kept for traceability but excluded from notes |

A chunk goes into the notes if it is not flagged and not dismissed, or if it is `KEEP`.
`KEEP` together with `is_flagged_noise = true` means the user overruled a flag. This is
useful when evaluating detection accuracy.

---

## Client integration guide

This section is for developers building the mobile app (or any other client). It lists
what each input is and where it comes from.

### Inputs and their sources

| Input | Where it comes from | Used in |
|---|---|---|
| **Server address** | Entered by the user in the app settings and stored on the device. Use the LAN IP of the machine running the backend, for example `http://192.168.1.5:8000`. The Android emulator uses `http://10.0.2.2:8000`. | every request |
| **Seminar topic** | A text field the user fills in before starting. Ask for a specific topic (for example "Machine Learning: KNN"), because detection quality depends on it. | `POST /session/start` |
| **Title** | Generated by the app, for example `"Lecture " + date/time`. | `POST /session/start` |
| **Audio source** | The user's choice: phone microphone → `"browser"`, laptop microphone → `"server_mic"`. | `POST /session/start` |
| **Microphone audio** | The phone microphone, recorded as a PCM stream: 16,000 Hz, 1 channel, 16-bit. Disable the OS noise suppression (the server handles noise); auto gain can stay on. | binary frames on `/ws/audio` |
| **Session ID** | **Not created by the app.** Read `session_id` from the start response and keep it. | all session and review calls |
| **Chunk ID** | From `transcript` events or from the `flagged` list. | review actions |
| **Review decision** | The user's Keep / Dismiss / Edit buttons. | `PATCH /chunk/{id}/override` or `/text` |

### Call sequence

1. `GET /health` to confirm the server is reachable.
2. Open `/ws/transcript` and listen for events.
3. `POST /api/v1/session/start` and save `session_id`.
4. If `source` is `"browser"`: open `/ws/audio` and stream 100 ms PCM frames. While
   `mic_status` is `calibrating`, show "calibrating, please stay quiet".
5. Show `transcript` events as they arrive.
6. When the user ends: stop sending audio, close `/ws/audio`, then
   `POST /api/v1/session/stop`. This can take a few seconds while noise detection runs.
7. If `topic_guard` is `true`, show a topic warning.
8. `GET /api/v1/session/{id}/flagged` and show the review list:
   - NOISE chunks: the whole chunk is out of the notes unless kept.
   - MIXED chunks: show `off_topic` sentences struck through.
9. Send `override` or `text` requests for the user's decisions.
10. `GET /api/v1/session/{id}/clean-transcript` for the final text.

### Notes for app developers
- Only one session can be active at a time. A second start returns `409`.
- Keep the Supabase keys out of the app. The app talks only to this backend.
- Do not split int16 samples across WebSocket frames. Buffer and send complete frames.
- In smart-glasses mode, the glasses' Start and Stop buttons can call the same start and
  stop endpoints.

---

## Noise detection

1. **Embedding.** Each chunk is converted into a 384-dimension MiniLM vector.
2. **Reference.** A topic vector is built from the seminar topic. The two-pass reference
   mixes it with the session's own average, so that real lecture content scores high even
   when the topic text is short.
3. **Flag.** A chunk whose cosine similarity is below 0.28 (first pass) is flagged NOISE.
4. **Topic guard.** If the whole session is far from the topic (below 0.20), chunks are
   scored against the topic alone and a `topic_mismatch` warning is sent. The guard is off
   for the default generic topic.
5. **MIXED.** Unflagged chunks with two or more sentences are checked sentence by sentence.
   A sentence below 0.20 marks the chunk MIXED and is cut from the notes.
6. **Learning.** The topic vector is updated from the clean chunks for the next pass.

Optional `NOISE_SCORING=llm` sends the transcript to `gpt-oss-20b`, which returns noise and
mixed labels with a reason. If the call fails, the embedding method is used instead.

---

## Limits and known limitations

- **Free-tier STT capacity.** Groq bills every request as at least 10 seconds, and the
  free tier allows 2,000 requests per day per organisation, shared by all users. With 3–7 s
  chunks this is about **2.7 hours of lecture per day**. 6–7 s chunks give about 3.6 hours,
  and 10–15 s chunks about 6 hours (live text then arrives every 10–15 s). On the paid
  Developer plan, large-v3 costs about USD 0.111 per audio hour.
- **One active session** at a time per server.
- **Detection accuracy is preliminary.** It was measured on a small set of recordings.
  Short sessions, lectures that use examples unrelated to the topic, and STT errors cause
  missed or extra flags. The review step exists for this reason.
- **Overlapping speech.** Whisper may drop quieter background speech that overlaps the
  main speaker.
- **Output language.** Output is English only; Urdu speech is translated, not transcribed.
- **Planned, not yet implemented:** listing sessions, deleting sessions or chunks
  permanently (including their audio), changing the topic and re-scoring, and signed URLs
  for audio playback.

---

## Developer tools

Run from this folder with the virtual environment active.

| Command | Purpose |
|---|---|
| `python tools/record_audio.py --seconds 10` | Record a 16 kHz mono WAV from the microphone |
| `python tools/stt_test.py data/audio/test_recording.wav` | Transcribe a WAV file |
| `python tools/ws_client_test.py --seconds 30` | Act as a client: start, print live events, stop |
| `python tools/e2e_test.py --topic "Machine Learning"` | End-to-end: session, noise flags, review, clean transcript |

---

## Security

- `.env` holds the Groq key, the database password and the service_role key. It is listed
  in `.gitignore`; never commit it.
- The service_role key bypasses row-level security. Use it only on the server.
- Row-level security is enabled with no policies on `sessions`, `audio_chunks`,
  `audio_containers`, `ocr_extractions` and `generated_notes`, so the public anon key
  cannot read or write them. The backend connects as the database owner.
- The audio bucket is private.
- CORS is open (`*`) for local development. Restrict it before any public deployment.

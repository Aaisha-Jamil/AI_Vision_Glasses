"""
Continuous live audio pipeline.

    Laptop mic --(sounddevice thread)--> asyncio queue --> PauseChunker
        --> 3-7 s chunk WAV on disk --> STT worker (Groq, local fallback)
        --> DB row + text_accumulator + WebSocket push
        --> (Supabase Storage on) upload worker: FLAC upload, audio_filepath updated
        --> every FLUSH_INTERVAL_SECONDS (and on stop): batch embedding, noise flagging,
            topic centroid update, noise_alert push (see semantic.py)
            FLUSH_INTERVAL_SECONDS=0: no flush during the lecture, one flush on stop
        --> on stop, after the flush: chunks grouped into CONTAINER_SECONDS containers
            (audio_containers: counts, clean-chunk centroid, topic similarity)

- Chunks are cut at natural pauses so words are never split between chunks.
- Every chunk is written to disk before transcription (SRS 5.2: no audio loss).
- One STT worker processes chunks in order, so the accumulator stays chronological
  and the lazy local-model load (fallback) never races.
- Chunks with almost no sound skip STT: Whisper hallucinates text from silence/noise.
"""

import asyncio
import logging
import os
import time
import uuid
from pathlib import Path
from typing import Awaitable, Callable

import numpy as np
import sounddevice as sd
from scipy.io import wavfile

import db
import llm_filter
import semantic
import storage
import stt

log = logging.getLogger("pipeline")

SAMPLE_RATE = 16000
BLOCK_SAMPLES = SAMPLE_RATE // 10  # 100 ms blocks -> pause detection resolution
# Groq bills every request as >= 10 s and the free tier allows 2,000 requests/day, so
# chunk length sets the daily capacity. Measured on 3 recorded sessions:
#   3-7 s ~738 requests/audio hour (~2.7 h/day), 6-7 s ~553 (~3.6 h/day),
#   10-15 s ~326 (~6.1 h/day, but live text only every ~10-15 s).
MIN_CHUNK_SECONDS = float(os.getenv("MIN_CHUNK_SECONDS", "3"))  # don't cut before this
MAX_CHUNK_SECONDS = float(os.getenv("MAX_CHUNK_SECONDS", "7"))  # safety cut
PAUSE_SECONDS = float(os.getenv("PAUSE_SECONDS", "0.4"))  # silence that ends a chunk
PREROLL_SECONDS = 0.3  # silence kept before speech starts, so the first word isn't clipped
SILENCE_RMS = float(os.getenv("SILENCE_RMS", "150"))  # int16 RMS below this = silence
MIN_SOUND_RUN_SECONDS = 0.5  # chunk needs this much continuous sound to be sent to STT
# Mic mode only: audio discarded after the mic opens. The laptop's noise suppression
# takes a variable 4.5-9 s to settle; until then a steady hum (RMS ~300-500) leaks
# through and Whisper turns it into confident fake sentences. Warm-up ends at the first
# QUIET_SECONDS of real silence (= suppression has settled), bounded by MIN/MAX.
MIC_WARMUP_MIN_SECONDS = float(os.getenv("MIC_WARMUP_MIN_SECONDS", "3"))
MIC_WARMUP_MAX_SECONDS = float(os.getenv("MIC_WARMUP_MAX_SECONDS", "10"))
MIC_WARMUP_QUIET_SECONDS = 0.5
AUDIO_DIR = Path("data/audio")
FLUSH_INTERVAL_SECONDS = float(os.getenv("FLUSH_INTERVAL_SECONDS", "600"))  # 10 min; 0 = on stop only
CONTAINER_SECONDS = float(os.getenv("CONTAINER_SECONDS", "600"))  # chunk -> container by start

# In-memory buffer of transcribed chunks not yet scored by a flush.
# Each item: {"chunk_id", "index", "timestamp", "start_offset", "end_offset",
#             "transcript", "provider", "audio_filepath"}
text_accumulator: list[dict] = []


def _rms(audio: np.ndarray) -> float:
    return float(np.sqrt(np.mean(audio.astype(np.float32) ** 2))) if len(audio) else 0.0


def summarize_containers(chunks: list, topic: np.ndarray) -> list[dict]:
    """Group scored chunk rows (db.scored_chunks) by container_index. The centroid uses
    only chunks that are neither noise nor mixed, so it describes the lecture content."""
    groups: dict[int, list] = {}
    for c in chunks:
        groups.setdefault(c["container_index"], []).append(c)
    rows = []
    for idx, cs in sorted(groups.items()):
        clean = [db.from_vec(c["embedding"]) for c in cs
                 if not c["is_flagged_noise"] and not c["is_mixed"]]
        centroid = semantic._norm(np.mean(clean, axis=0)) if clean else None
        rows.append({
            "container_index": idx,
            "start_timestamp": cs[0]["start_timestamp"],
            "end_timestamp": max(c["end_timestamp"] for c in cs),
            "chunk_count": len(cs),
            "noise_count": sum(bool(c["is_flagged_noise"]) for c in cs),
            "mixed_count": sum(bool(c["is_mixed"]) for c in cs),
            "centroid": centroid,
            "topic_similarity": None if centroid is None else float(centroid @ topic),
        })
    return rows


class PauseChunker:
    """Splits a stream of audio blocks into speech chunks at natural pauses.

    Rules:
      - cut when buffer >= MIN_CHUNK_SECONDS and the last PAUSE_SECONDS were silent
      - if no pause by MAX_CHUNK_SECONDS, cut at the quietest block in [MIN, MAX]
      - silence before any speech is dropped (only PREROLL_SECONDS kept)
    feed()/flush() return a list of (audio, start_sample); start_sample counts from
    stream start, including dropped silence, so timestamps stay exact.
    """

    def __init__(self, sr: int = SAMPLE_RATE, min_s: float = MIN_CHUNK_SECONDS,
                 max_s: float = MAX_CHUNK_SECONDS, pause_s: float = PAUSE_SECONDS,
                 silence_rms: float = SILENCE_RMS, preroll_s: float = PREROLL_SECONDS):
        self.sr, self.silence_rms = sr, silence_rms
        self.min_n, self.max_n = int(min_s * sr), int(max_s * sr)
        self.pause_n, self.preroll_n = int(pause_s * sr), int(preroll_s * sr)
        self.blocks: list[np.ndarray] = []
        self.voiced: list[bool] = []
        self.levels: list[float] = []
        self.buf_start = 0  # stream sample index of blocks[0]

    @property
    def _buffered(self) -> int:
        return sum(len(b) for b in self.blocks)

    def _trailing_silence(self) -> int:
        n = 0
        for b, v in zip(reversed(self.blocks), reversed(self.voiced)):
            if v:
                break
            n += len(b)
        return n

    def feed(self, block: np.ndarray) -> list[tuple[np.ndarray, int]]:
        level = _rms(block)
        self.blocks.append(block)
        self.levels.append(level)
        self.voiced.append(level >= self.silence_rms)

        if not any(self.voiced):
            # No speech yet: keep only a short pre-roll of silence.
            while self._buffered - len(self.blocks[0]) >= self.preroll_n:
                self.buf_start += len(self.blocks.pop(0))
                self.voiced.pop(0)
                self.levels.pop(0)
            return []

        buffered = self._buffered
        if buffered >= self.min_n and self._trailing_silence() >= self.pause_n:
            return [self._cut(len(self.blocks))]
        if buffered >= self.max_n:
            return [self._cut(self._quietest_cut())]
        return []

    def skip(self, block: np.ndarray):
        """Discard a block but keep the timeline moving (used during mic warm-up)."""
        self.buf_start += len(block)

    def flush(self) -> list[tuple[np.ndarray, int]]:
        return [self._cut(len(self.blocks))] if any(self.voiced) else []

    def _quietest_cut(self) -> int:
        """Number of blocks to emit: up to and including the quietest block in [min, max]."""
        best, best_level, pos = len(self.blocks), float("inf"), 0
        for i, (b, level) in enumerate(zip(self.blocks, self.levels)):
            pos += len(b)
            if self.min_n <= pos <= self.max_n and level < best_level:
                best, best_level = i + 1, level
        return best

    def _cut(self, n: int) -> tuple[np.ndarray, int]:
        audio = np.concatenate(self.blocks[:n])
        start = self.buf_start
        self.buf_start += len(audio)
        del self.blocks[:n], self.voiced[:n], self.levels[:n]
        return audio, start


class AudioPipeline:
    def __init__(self, broadcast: Callable[[dict], Awaitable[None]]):
        self._broadcast = broadcast
        self.session_id: str | None = None
        self._stream: sd.InputStream | None = None
        self._feeder: asyncio.Task | None = None  # file-source mode only
        self._blocks: asyncio.Queue | None = None
        self._chunks: asyncio.Queue | None = None
        self._uploads: asyncio.Queue | None = None  # Supabase Storage only
        self._tasks: list[asyncio.Task] = []
        self._session_start = 0.0
        self._active = False
        self._warmup = False
        self.source = "server_mic"  # server_mic | browser | file
        self._flush_task: asyncio.Task | None = None
        self._flush_lock = asyncio.Lock()
        self._lecture_context: list[str] = []  # recent clean transcripts, for llm_filter
        self.mic_status = "off"  # off | calibrating | ready

    @property
    def running(self) -> bool:
        return self._active

    async def start(self, session_id: str, device: int | None = None,
                    source_file: str | None = None, source: str = "server_mic",
                    warmup: bool | None = None):
        """Start capturing. Input sources (everything after the input is identical):
          server_mic - laptop mic read on the server via sounddevice
          browser    - 16 kHz int16 PCM pushed by the web page through push_audio()
          source_file (testing) - play a 16 kHz mono WAV in real time
        warmup: override mic calibration (default: on for server_mic/browser)."""
        if self.running:
            raise RuntimeError("pipeline already running")
        self.session_id = session_id
        self._session_start = time.time()
        self._lecture_context = []
        (AUDIO_DIR / session_id).mkdir(parents=True, exist_ok=True)

        loop = asyncio.get_running_loop()
        self._blocks = asyncio.Queue()
        self._chunks = asyncio.Queue()

        if source_file:
            self.source = "file"
            self._warmup = False
            self._feeder = asyncio.create_task(self._feed_file(source_file))
        elif source == "browser":
            self.source = "browser"
            self._warmup = True
        else:
            self.source = "server_mic"
            self._warmup = True
            def on_audio(indata, frames, time_info, status):
                # Runs on the sounddevice thread - hand data to the event loop.
                if status:
                    log.warning("mic status: %s", status)
                loop.call_soon_threadsafe(self._blocks.put_nowait, indata[:, 0].copy())

            self._stream = sd.InputStream(
                samplerate=SAMPLE_RATE, channels=1, dtype="int16",
                blocksize=BLOCK_SAMPLES, device=device, callback=on_audio,
            )
            self._stream.start()
        if warmup is not None:
            self._warmup = warmup
        self._active = True
        self._tasks = [
            asyncio.create_task(self._chunker()),
            asyncio.create_task(self._stt_worker()),
        ]
        if storage.ENABLED:
            self._uploads = asyncio.Queue()
            self._tasks.append(asyncio.create_task(self._upload_worker()))
        self._flush_task = (asyncio.create_task(self._flush_loop())
                            if FLUSH_INTERVAL_SECONDS > 0 else None)
        log.info("pipeline started: session=%s chunks=%.0f-%.0fs pause=%.1fs flush=%.0fs "
                 "source=%s warmup=%s", session_id, MIN_CHUNK_SECONDS, MAX_CHUNK_SECONDS,
                 PAUSE_SECONDS, FLUSH_INTERVAL_SECONDS, source_file or self.source, self._warmup)

    def push_audio(self, pcm: np.ndarray) -> bool:
        """Browser source: feed 16 kHz mono int16 samples. Returns False if not accepted."""
        if not (self.running and self.source == "browser"):
            return False
        for i in range(0, len(pcm), BLOCK_SAMPLES):
            self._blocks.put_nowait(pcm[i:i + BLOCK_SAMPLES])
        return True

    async def stop(self):
        """Stop the input, flush the last partial chunk, finish pending STT."""
        if not self.running:
            return
        self._active = False
        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        if self._feeder:
            self._feeder.cancel()
            self._feeder = None
        await self._blocks.put(None)       # tell chunker: flush + exit
        await self._tasks[0]
        await self._chunks.put(None)       # tell worker: drain + exit
        await self._tasks[1]
        if self._uploads:
            await self._uploads.put(None)  # tell uploader: finish pending uploads + exit
            await self._tasks[2]
            self._uploads = None
        self._tasks = []
        if self._flush_task:
            self._flush_task.cancel()
        await self.flush_buffer()          # leftover buffer (whole lecture if interval=0)
        try:
            await asyncio.to_thread(self._build_containers)
        except Exception:
            log.exception("building containers failed")
        log.info("pipeline stopped: session=%s", self.session_id)

    def _build_containers(self):
        session = db.get_session(self.session_id)
        rows = summarize_containers(db.scored_chunks(self.session_id),
                                    db.from_vec(session["topic_centroid_vector"]))
        db.save_containers(self.session_id, rows)
        for r in rows:
            log.info("container %d: %d chunks, %d noise, %d mixed, topic_similarity=%s",
                     r["container_index"], r["chunk_count"], r["noise_count"],
                     r["mixed_count"], None if r["topic_similarity"] is None
                     else round(r["topic_similarity"], 2))

    async def flush_buffer(self):
        """Score all buffered chunks: embed, flag noise, update topic centroid, alert."""
        async with self._flush_lock:
            batch = text_accumulator[:]
            text_accumulator.clear()
            if not batch:
                return
            session = await asyncio.to_thread(db.get_session, self.session_id)
            cold = session["flush_count"] == 0
            topic = db.from_vec(session["topic_centroid_vector"])

            t0 = time.perf_counter()
            labels, mode = await self._llm_labels(session["seminar_topic"], batch)
            override = None if labels is None else np.array(
                [c["index"] in labels and not labels[c["index"]]["is_mixed"] for c in batch])
            res = await asyncio.to_thread(
                semantic.score_batch, [c["transcript"] for c in batch], topic, cold, override,
                session["seminar_topic"] != semantic.DEFAULT_SEMINAR_TOPIC)
            if labels is None:  # embedding mode: MIXED comes from the sentence split
                labels = {c["index"]: {"is_mixed": True, "reason": r, "off_topic": o}
                          for c, m, r, o in zip(batch, res["is_mixed"], res["mixed_reason"],
                                                res["off_topic"]) if m}
            mode = mode or res["mode"]
            await asyncio.to_thread(db.save_scores, [
                (c["chunk_id"], e, s, n, labels.get(c["index"], {}).get("is_mixed", False),
                 labels.get(c["index"], {}).get("reason"),
                 labels.get(c["index"], {}).get("off_topic", []))
                for c, e, s, n
                in zip(batch, res["embeddings"], res["similarities"], res["is_noise"])
            ])
            await asyncio.to_thread(db.update_topic, self.session_id, res["topic"],
                                    res["topic_match"], res["topic_guard"])
            self._lecture_context += [c["transcript"] for c in batch
                                      if c["index"] not in labels]
            del self._lecture_context[:-llm_filter.CONTEXT_CHUNKS]
            flush_ms = (time.perf_counter() - t0) * 1000

            flagged = int(res["is_noise"].sum())
            log.info("flush: %d chunks, %d noise (%s, threshold %.2f, cold=%s, "
                     "topic_match %.2f) in %.0f ms", len(batch), flagged, mode,
                     res["threshold"], cold, res["topic_match"], flush_ms)
            if res["topic_guard"]:
                log.warning("topic guard: batch vs topic %.2f < %.2f - scored against the "
                            "topic only (two_pass column = what it would have scored)",
                            res["topic_match"], semantic.TOPIC_GUARD)
                await self._broadcast({
                    "type": "topic_mismatch",
                    "session_id": self.session_id,
                    "seminar_topic": session["seminar_topic"],
                    "topic_match": round(res["topic_match"], 3),
                })
            for c, s, s2, n in zip(batch, res["similarities"], res["two_pass_similarities"],
                                   res["is_noise"]):
                label = labels.get(c["index"], {})
                tag = "NOISE" if n else "MIXED" if label.get("is_mixed") else "     "
                log.info("   %.2f%s %s %s%s", s, f" (two_pass {s2:.2f})" if res["topic_guard"]
                         else "", tag, c["transcript"],
                         f"  [{label['reason']}]" if label.get("reason") else "")
                if n or label.get("is_mixed"):
                    await self._broadcast({
                        "type": "noise_alert" if n else "mixed_alert",
                        "session_id": self.session_id,
                        "chunk_id": c["chunk_id"],
                        "start_offset": c["start_offset"],
                        "end_offset": c["end_offset"],
                        "transcript": c["transcript"],
                        "cosine_similarity": round(float(s), 3),
                        "is_noise": bool(n),
                        "is_mixed": bool(label.get("is_mixed")),
                        "reason": label.get("reason"),
                        "off_topic": label.get("off_topic", []),
                        "user_override": "PENDING",
                    })
            await self._broadcast({
                "type": "buffer_flushed",
                "session_id": self.session_id,
                "chunks": len(batch),
                "flagged": flagged,
                "mixed": sum(1 for v in labels.values() if v["is_mixed"]),
                "mode": mode,
                "threshold": res["threshold"],
                "cold_start": cold,
                "topic_updated": res["topic_updated"],
                "topic_match": round(res["topic_match"], 3),
                "topic_guard": res["topic_guard"],
            })

    async def _llm_labels(self, topic: str, batch: list[dict]) -> tuple[dict | None, str | None]:
        """NOISE_SCORING=llm: ask llm_filter. Returns (labels, mode); labels None means
        'use the embedding threshold' (llm mode off, or the LLM call failed)."""
        if semantic.NOISE_SCORING != "llm":
            return None, None
        try:
            labels = await asyncio.to_thread(
                llm_filter.classify, topic,
                [{"id": c["index"], "text": c["transcript"]} for c in batch],
                self._lecture_context)
            return labels, "llm"
        except Exception as e:  # network down, rate limit, bad JSON...
            log.warning("LLM noise filter failed (%s: %s) - falling back to embeddings",
                        type(e).__name__, e)
            return None, "llm_fallback_embeddings"

    async def _flush_loop(self):
        while True:
            await asyncio.sleep(FLUSH_INTERVAL_SECONDS)
            try:
                await self.flush_buffer()
            except Exception:
                log.exception("buffer flush failed")

    # ------------------------------------------------------------ internals

    async def _feed_file(self, path: str):
        """Push a WAV file into the pipeline in 100 ms blocks at real-time speed."""
        sr, audio = wavfile.read(path)
        if sr != SAMPLE_RATE or audio.ndim != 1 or audio.dtype != np.int16:
            raise ValueError(f"{path}: need 16 kHz mono int16 WAV")
        for i in range(0, len(audio), BLOCK_SAMPLES):
            self._blocks.put_nowait(audio[i:i + BLOCK_SAMPLES])
            await asyncio.sleep(0.1)
        log.info("source file finished: %s", path)

    async def _chunker(self):
        """Group incoming blocks into pause-delimited chunks and write them to disk."""
        chunker = PauseChunker()
        index = 0
        warming = self._warmup
        warm_elapsed = warm_quiet = 0
        await self._set_mic_status("calibrating" if warming else "ready")
        while True:
            block = await self._blocks.get()
            final = block is None
            if not final and warming:
                chunker.skip(block)
                warm_elapsed += len(block)
                warm_quiet = warm_quiet + len(block) if _rms(block) < SILENCE_RMS else 0
                settled = (warm_elapsed >= MIC_WARMUP_MIN_SECONDS * SAMPLE_RATE
                           and warm_quiet >= MIC_WARMUP_QUIET_SECONDS * SAMPLE_RATE)
                if settled or warm_elapsed >= MIC_WARMUP_MAX_SECONDS * SAMPLE_RATE:
                    warming = False
                    log.info("mic calibrated after %.1fs (%s)", warm_elapsed / SAMPLE_RATE,
                             "settled" if settled else "max time reached")
                    await self._set_mic_status("ready")
                continue
            for audio, start_sample in (chunker.flush() if final else chunker.feed(block)):
                self._write_chunk(audio, index, start_sample)
                index += 1
            if final:
                self.mic_status = "off"
                return

    async def _set_mic_status(self, status: str):
        self.mic_status = status
        msg = {"type": "mic_status", "session_id": self.session_id, "status": status}
        if status == "calibrating":
            msg["max_seconds"] = MIC_WARMUP_MAX_SECONDS
        log.info("mic status: %s", status)
        await self._broadcast(msg)

    def _write_chunk(self, audio: np.ndarray, index: int, start_sample: int):
        chunk_id = str(uuid.uuid4())
        path = AUDIO_DIR / self.session_id / f"chunk_{index:05d}.wav"
        wavfile.write(path, SAMPLE_RATE, audio)
        start_offset = start_sample / SAMPLE_RATE
        # Longest stretch of continuous sound: speech is sustained, clicks/taps are not.
        run = longest = 0
        for i in range(0, len(audio), BLOCK_SAMPLES):
            run = run + 1 if _rms(audio[i:i + BLOCK_SAMPLES]) >= SILENCE_RMS else 0
            longest = max(longest, run)
        self._chunks.put_nowait({
            "chunk_id": chunk_id,
            "index": index,
            "timestamp": round(self._session_start + start_offset, 3),  # epoch, ms precision
            "start_offset": round(start_offset, 3),
            "end_offset": round(start_offset + len(audio) / SAMPLE_RATE, 3),
            "container_index": int(start_offset // CONTAINER_SECONDS),
            "audio_filepath": str(path),
            "sound_run_seconds": longest * BLOCK_SAMPLES / SAMPLE_RATE,
        })

    async def _stt_worker(self):
        while True:
            chunk = await self._chunks.get()
            if chunk is None:
                return
            sound_run = chunk.pop("sound_run_seconds")
            if sound_run < MIN_SOUND_RUN_SECONDS:  # clicks/taps: Whisper turns them into "Thank you."
                log.info("chunk %d: longest sound %.1fs - not speech, skipped",
                         chunk["index"], sound_run)
                continue
            try:
                t0 = time.perf_counter()
                result = await asyncio.to_thread(stt.transcribe, chunk["audio_filepath"])
                stt_ms = (time.perf_counter() - t0) * 1000
            except Exception:
                log.exception("STT failed for chunk %d", chunk["index"])
                continue
            if not result.text:
                continue

            record = {**chunk, "transcript": result.text, "provider": result.provider}
            await asyncio.to_thread(db.insert_chunk, self.session_id, record)
            text_accumulator.append(record)
            if self._uploads:
                self._uploads.put_nowait((record["chunk_id"], record["audio_filepath"]))
            log.info("chunk %d [%s %.0f ms]: %s",
                     chunk["index"], result.provider, stt_ms, result.text)
            await self._broadcast({
                "type": "transcript",
                "session_id": self.session_id,
                **record,
                "stt_ms": round(stt_ms),
            })

    async def _upload_worker(self):
        """Supabase Storage: upload each transcribed chunk as FLAC, then point its
        audio_filepath at the bucket. Own queue, so slow uploads never delay STT."""
        while True:
            item = await self._uploads.get()
            if item is None:
                return
            chunk_id, wav_path = item
            try:
                t0 = time.perf_counter()
                remote = await asyncio.to_thread(storage.upload_chunk, self.session_id, wav_path)
                await asyncio.to_thread(db.set_audio_path, chunk_id, remote)
                log.info("uploaded %s [%.0f ms]", remote, (time.perf_counter() - t0) * 1000)
            except Exception as e:
                log.warning("upload failed, keeping local file %s (%s)", wav_path, e)

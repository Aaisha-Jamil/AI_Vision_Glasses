"""
Audio storage. Every chunk is first written as WAV to data/audio/ (STT reads it there;
SRS 5.2: no audio loss). Optionally each chunk is also uploaded to Supabase Storage:

    SUPABASE_URL / SUPABASE_SECRET_KEY empty -> local disk only (current mode)
    both set -> after transcription, every chunk that got a DB row is uploaded as FLAC
        to the private bucket AUDIO_BUCKET and audio_chunks.audio_filepath becomes
        supabase://<bucket>/<session_id>/chunk_00012.flac
        (if an upload fails the local path stays; the WAV is still on disk)

FLAC is lossless; on 282 recorded chunks it was 61% of the WAV size (WAV 115 MB/hour,
FLAC 70 MB/hour -> the free plan's 1 GB holds ~14 h of lecture). Chunks STT skipped
(silence, clicks, no text) are never uploaded. The bucket is created by supabase_storage.sql.
"""

import io
import logging
import os
import time
from pathlib import Path

import av
import httpx
import numpy as np
from scipy.io import wavfile

log = logging.getLogger("storage")

SUPABASE_URL = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SECRET_KEY", "").strip()
AUDIO_BUCKET = os.getenv("AUDIO_BUCKET", "lecture-audio").strip()
ENABLED = bool(SUPABASE_URL and SUPABASE_SECRET_KEY)
UPLOAD_ATTEMPTS = 3


def to_flac(audio: np.ndarray, sr: int) -> bytes:
    """int16 mono samples -> FLAC file bytes (PyAV/ffmpeg, installed with faster-whisper)."""
    buf = io.BytesIO()
    with av.open(buf, "w", format="flac") as out:
        stream = out.add_stream("flac", rate=sr)
        stream.layout = "mono"
        frame = av.AudioFrame.from_ndarray(audio.reshape(1, -1), format="s16", layout="mono")
        frame.sample_rate = sr
        for packet in stream.encode(frame):
            out.mux(packet)
        for packet in stream.encode(None):
            out.mux(packet)
    return buf.getvalue()


def _headers() -> dict:
    headers = {"apikey": SUPABASE_SECRET_KEY, "Content-Type": "audio/flac", "x-upsert": "true"}
    # Legacy service_role keys are JWTs and also go in Authorization. The newer
    # sb_secret_... keys are not JWTs: they are sent only as apikey.
    if SUPABASE_SECRET_KEY.startswith("eyJ"):
        headers["Authorization"] = f"Bearer {SUPABASE_SECRET_KEY}"
    return headers


def upload(object_path: str, data: bytes) -> str:
    """PUT one object into AUDIO_BUCKET (overwrites). Returns the supabase:// path.
    Retries network errors, 429 and 5xx; other 4xx (bad key, no bucket) fail at once."""
    url = f"{SUPABASE_URL}/storage/v1/object/{AUDIO_BUCKET}/{object_path}"
    for attempt in range(1, UPLOAD_ATTEMPTS + 1):
        try:
            resp = httpx.post(url, content=data, headers=_headers(), timeout=30)
            if resp.status_code < 400:
                return f"supabase://{AUDIO_BUCKET}/{object_path}"
            if resp.status_code != 429 and resp.status_code < 500:
                raise RuntimeError(f"Supabase Storage {resp.status_code}: {resp.text[:200]}")
            err = f"HTTP {resp.status_code}"
        except httpx.HTTPError as e:
            err = f"{type(e).__name__}: {e}"
        if attempt < UPLOAD_ATTEMPTS:
            log.warning("upload %s failed (%s), retry %d", object_path, err, attempt)
            time.sleep(2 ** (attempt - 1))
    raise RuntimeError(f"upload {object_path} failed after {UPLOAD_ATTEMPTS} attempts: {err}")


def upload_chunk(session_id: str, wav_path: str) -> str:
    """Encode a chunk WAV as FLAC and upload it as <session_id>/<chunk name>.flac."""
    sr, audio = wavfile.read(wav_path)
    data = to_flac(audio, sr)
    return upload(f"{session_id}/{Path(wav_path).stem}.flac", data)

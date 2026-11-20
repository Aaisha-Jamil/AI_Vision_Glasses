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

try:
    import av
except Exception as _e:
    av = None

import httpx
import numpy as np
from scipy.io import wavfile
from dotenv import load_dotenv

load_dotenv()

log = logging.getLogger("storage")


SUPABASE_URL = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SECRET_KEY", "").strip()
AUDIO_BUCKET = os.getenv("AUDIO_BUCKET", "lecture-audio").strip()
ENABLED = bool(SUPABASE_URL and SUPABASE_SECRET_KEY)
UPLOAD_ATTEMPTS = 3


def to_flac(audio: np.ndarray, sr: int) -> bytes:
    """int16 mono samples -> FLAC file bytes (PyAV/ffmpeg, installed with faster-whisper)."""
    if av is not None:
        try:
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
        except Exception as e:
            log.warning("PyAV encoding failed (%s), falling back to WAV format.", e)

    # Fallback: WAV bytes if PyAV is unavailable or blocked by system policies
    buf = io.BytesIO()
    wavfile.write(buf, sr, audio)
    return buf.getvalue()


def _headers() -> dict:
    headers = {"apikey": SUPABASE_SECRET_KEY, "Content-Type": "audio/flac", "x-upsert": "true",
               "Authorization": f"Bearer {SUPABASE_SECRET_KEY}"}
    return headers


def _auth_headers() -> dict:
    """Auth only - for JSON requests (list/delete), where audio/flac would be wrong."""
    return {"apikey": SUPABASE_SECRET_KEY, "Authorization": f"Bearer {SUPABASE_SECRET_KEY}"}


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


def delete_session_audio(session_id: str) -> bool:
    """Deletes all audio files for a session from the private lecture-audio bucket."""
    if not ENABLED:
        return False
    try:
        # First list files in the session folder
        list_url = f"{SUPABASE_URL}/storage/v1/object/list/{AUDIO_BUCKET}"
        resp = httpx.post(
            list_url,
            json={"prefix": f"{session_id}/", "limit": 1000},
            headers={"apikey": SUPABASE_SECRET_KEY, "Authorization": f"Bearer {SUPABASE_SECRET_KEY}"},
            timeout=15,
        )
        if resp.status_code == 200:
            files = resp.json()
            prefixes = [f"{session_id}/{f['name']}" for f in files if "name" in f]
            if prefixes:
                del_url = f"{SUPABASE_URL}/storage/v1/object/{AUDIO_BUCKET}"
                del_resp = httpx.request("DELETE", del_url, json={"prefixes": prefixes},
                                         headers=_auth_headers(), timeout=15)
                log.info("Deleted %d audio files for session %s from Supabase Storage (%d)", len(prefixes), session_id, del_resp.status_code)
                return del_resp.status_code < 400
        return True
    except Exception as e:
        log.warning("Failed to delete audio storage for session %s: %s", session_id, e)
        return False


def delete_snapshot_images(snapshot_ids: list[str], bucket: str = "lecture-slides") -> bool:
    """Deletes slide snapshot image files from the lecture-slides bucket."""
    if not ENABLED or not snapshot_ids:
        return False
    try:
        prefixes = []
        for sid in snapshot_ids:
            prefixes.extend([f"public/{sid}.jpg", f"{sid}.jpg"])
        del_url = f"{SUPABASE_URL}/storage/v1/object/{bucket}"
        del_resp = httpx.request("DELETE", del_url, json={"prefixes": prefixes},
                                 headers=_auth_headers(), timeout=15)
        log.info("Deleted slide images from %s: %s (%d)", bucket, snapshot_ids, del_resp.status_code)
        return del_resp.status_code < 400
    except Exception as e:
        log.warning("Failed to delete snapshot images: %s", e)
        return False


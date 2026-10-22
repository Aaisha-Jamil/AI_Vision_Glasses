"""
Speech-to-Text module.

Primary:  Groq Cloud Whisper API (whisper-large-v3) - fast, no local CPU load.
          language=en: Urdu / mixed Urdu-English speech comes out as English.
Fallback: local faster-whisper (SRS SW-3) - used when Groq is unavailable
          (no API key, no internet, rate limit hit). Loaded lazily, only if needed.

Config (.env):
    GROQ_API_KEY=...                  # get free key at https://console.groq.com/keys
    STT_PROVIDER=groq                 # groq | local
    GROQ_STT_MODEL=whisper-large-v3   # turbo is cheaper but changed the meaning of Urdu speech
    LOCAL_STT_MODEL=base              # tiny | base | small
"""

import logging
import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()
log = logging.getLogger("stt")

STT_PROVIDER = os.getenv("STT_PROVIDER", "groq").lower()
GROQ_API_KEY = os.getenv("GROQ_API_KEY", "")
GROQ_STT_MODEL = os.getenv("GROQ_STT_MODEL", "whisper-large-v3")
LOCAL_STT_MODEL = os.getenv("LOCAL_STT_MODEL", "base")
LANGUAGE = "en"

# Hallucination guard: Whisper invents sentences from background noise.
# Groq always returns no_speech_prob=0, but avg_logprob separates them well
# (tested: noise hallucination -1.52, real speech -0.19). -1.0 = Whisper's own default.
MIN_AVG_LOGPROB = float(os.getenv("MIN_AVG_LOGPROB", "-1.0"))

# Phrases Whisper is known to invent from clicks/noise (it learned them from video
# subtitles), often with high confidence. Dropped only when they are the WHOLE transcript.
KNOWN_HALLUCINATIONS = {
    "thank you", "thanks", "thank you very much", "thanks for watching",
    "thank you for watching", "bye", "you", "please subscribe",
}


@dataclass
class Segment:
    start: float
    end: float
    text: str


@dataclass
class TranscriptResult:
    text: str
    segments: list[Segment]
    provider: str  # "groq" or "local" - which engine actually produced this


# ---------------------------------------------------------------- Groq (cloud)

_groq_client = None


def _get_groq_client():
    global _groq_client
    if _groq_client is None:
        from groq import Groq

        # max_retries: SDK retries 429 / 5xx with exponential backoff (SRS 5.2)
        _groq_client = Groq(api_key=GROQ_API_KEY, max_retries=3, timeout=30)
    return _groq_client


def _transcribe_groq(audio_path: str) -> TranscriptResult:
    path = Path(audio_path)
    resp = _get_groq_client().audio.transcriptions.create(
        file=(path.name, path.read_bytes()),
        model=GROQ_STT_MODEL,
        language=LANGUAGE,
        response_format="verbose_json",  # includes per-segment timestamps
        temperature=0.0,
    )
    raw_segments = getattr(resp, "segments", None) or []
    segments = []
    for s in raw_segments:
        if s.get("avg_logprob", 0.0) < MIN_AVG_LOGPROB:
            log.info("dropped low-confidence segment (avg_logprob=%.2f): %r",
                     s["avg_logprob"], s["text"])
            continue
        segments.append(Segment(float(s["start"]), float(s["end"]), s["text"].strip()))
    return _result(segments, "groq")


# ------------------------------------------------------ faster-whisper (local)

_local_model = None


def _get_local_model():
    global _local_model
    if _local_model is None:
        from faster_whisper import WhisperModel

        log.info("Loading local faster-whisper model '%s'...", LOCAL_STT_MODEL)
        _local_model = WhisperModel(LOCAL_STT_MODEL, device="cpu", compute_type="int8")
    return _local_model


def _transcribe_local(audio_path: str) -> TranscriptResult:
    segs, _ = _get_local_model().transcribe(
        audio_path, language=LANGUAGE, vad_filter=True, beam_size=1
    )
    segments = [
        Segment(s.start, s.end, s.text.strip())
        for s in segs
        if s.avg_logprob >= MIN_AVG_LOGPROB
    ]
    return _result(segments, "local")


def _result(segments: list[Segment], provider: str) -> TranscriptResult:
    # Drop punctuation-only segments like "." that Whisper emits for noise.
    segments = [s for s in segments if any(ch.isalnum() for ch in s.text)]
    text = " ".join(s.text for s in segments).strip()
    normalized = "".join(ch for ch in text.lower() if ch.isalnum() or ch == " ").strip()
    if normalized in KNOWN_HALLUCINATIONS:
        log.info("dropped known hallucination: %r", text)
        return TranscriptResult("", [], provider)
    return TranscriptResult(text, segments, provider)


# ------------------------------------------------------------------ public API


def transcribe(audio_path: str) -> TranscriptResult:
    """Transcribe a WAV file. Uses Groq if configured, else/on failure local."""
    if STT_PROVIDER == "groq" and GROQ_API_KEY:
        try:
            return _transcribe_groq(audio_path)
        except Exception as e:  # network down, rate limit exhausted, bad key...
            log.warning("Groq STT failed (%s: %s) - falling back to local model",
                        type(e).__name__, e)
    elif STT_PROVIDER == "groq":
        log.warning("GROQ_API_KEY not set - using local faster-whisper")
    return _transcribe_local(audio_path)

"""
Transcribe a WAV file using the STT module (Groq, with local fallback).

Usage:
    python tools/stt_test.py                          # data/audio/test_recording.wav
    python tools/stt_test.py data/audio/my_test.wav
"""

import argparse
import logging
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # repo root (stt.py)
import stt  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Transcribe a WAV file")
    parser.add_argument("audio", nargs="?", default="data/audio/test_recording.wav")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    t0 = time.perf_counter()
    result = stt.transcribe(args.audio)
    elapsed = time.perf_counter() - t0

    print("\n--- Segments ---")
    for s in result.segments:
        print(f"[{s.start:6.2f}s -> {s.end:6.2f}s] {s.text}")

    print("\n--- Transcript ---")
    print(result.text or "(no speech detected)")
    print(f"\nProvider: {result.provider}")
    print(f"Time: {elapsed:.2f} s  (SRS target: <= 3 s per 15 s chunk)")


if __name__ == "__main__":
    main()

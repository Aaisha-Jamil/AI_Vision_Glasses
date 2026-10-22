"""
Record audio from the laptop microphone and save it as a WAV file.

Audio format follows SRS HW-2: 16 kHz, mono, 16-bit PCM (what Whisper expects).

Usage:
    python tools/record_audio.py                 # 10 s -> data/audio/test_recording.wav
    python tools/record_audio.py --seconds 15
    python tools/record_audio.py --out data/audio/my_test.wav
    python tools/record_audio.py --list-devices  # show available mics
    python tools/record_audio.py --device 12     # use a specific mic
"""

import argparse
from pathlib import Path

import numpy as np
import sounddevice as sd
from scipy.io import wavfile

SAMPLE_RATE = 16000  # 16 kHz
CHANNELS = 1         # mono


def record(seconds: float, device: int | None = None) -> np.ndarray:
    """Record `seconds` of audio from the mic and return int16 samples."""
    print(f"Recording {seconds:.0f} s from mic... speak now!")
    audio = sd.rec(
        int(seconds * SAMPLE_RATE),
        samplerate=SAMPLE_RATE,
        channels=CHANNELS,
        dtype="int16",
        device=device,
    )
    sd.wait()  # block until recording is finished
    print("Recording finished.")
    return audio.flatten()


def main():
    parser = argparse.ArgumentParser(description="Record audio from laptop mic")
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--out", default="data/audio/test_recording.wav")
    parser.add_argument("--device", type=int, default=None, help="input device index")
    parser.add_argument("--list-devices", action="store_true")
    args = parser.parse_args()

    if args.list_devices:
        print(sd.query_devices())
        return

    audio = record(args.seconds, args.device)

    # Quick sanity check: is the mic actually picking something up?
    peak = int(np.abs(audio).max())
    print(f"Peak level: {peak} / 32767")
    if peak < 300:
        print("WARNING: audio is almost silent - check that the mic is on / not muted.")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    wavfile.write(out_path, SAMPLE_RATE, audio)
    print(f"Saved: {out_path}")


if __name__ == "__main__":
    main()

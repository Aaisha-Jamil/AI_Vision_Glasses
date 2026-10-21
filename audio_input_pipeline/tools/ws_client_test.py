"""
Test client that behaves like the Flutter app:
connect to /ws/transcript, start a session, print live messages, stop the session.

Usage:
    python tools/ws_client_test.py                       # 30 s, localhost
    python tools/ws_client_test.py --seconds 60 --host 192.168.1.43
    python tools/ws_client_test.py --seconds 40 --file data/audio/lecture_playback.wav
"""

import argparse
import asyncio
import json
import time

import httpx
import websockets


async def main(host: str, seconds: float, source_file: str | None):
    base = f"http://{host}:8000"
    async with websockets.connect(f"ws://{host}:8000/ws/transcript") as ws:
        async def listen():
            async for raw in ws:
                msg = json.loads(raw)
                if msg["type"] == "transcript":
                    print(f"#{msg['index']:<3} t={msg['start_offset']:5.1f}-{msg['end_offset']:5.1f}s "
                          f"[{msg['provider']} {msg['stt_ms']} ms] {msg['transcript']}")
                else:
                    print(">>", msg)

        listener = asyncio.create_task(listen())
        async with httpx.AsyncClient(base_url=base, timeout=60) as http:
            body = {"title": "WS test"}
            if source_file:
                body["source_file"] = source_file
            r = await http.post("/api/v1/session/start", json=body)
            print("START:", r.json())
            t0 = time.time()
            await asyncio.sleep(seconds)
            r = await http.post("/api/v1/session/stop")
            print(f"STOP after {time.time() - t0:.1f}s:", r.json())
            await asyncio.sleep(0.5)  # let the last messages arrive
            buf = (await http.get("/api/v1/transcript/buffer")).json()
            print(f"\nAccumulator: {buf['chunks']} chunks\nMerged text: {buf['merged_text']}")
        listener.cancel()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--seconds", type=float, default=30)
    p.add_argument("--file", help="stream this WAV instead of the mic (server-side path)")
    a = p.parse_args()
    asyncio.run(main(a.host, a.seconds, a.file))

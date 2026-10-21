"""
End-to-end test: session with seminar_topic -> live transcripts -> buffer flushes
with noise_alert events -> user overrides -> clean transcript.

Run the server with a short flush interval first, e.g.:
    $env:FLUSH_INTERVAL_SECONDS="38"; python -m uvicorn main:app --port 8000
Then:
    python tools/e2e_test.py --topic "Machine Learning"
"""

import argparse
import asyncio
import json

import httpx
import websockets


async def main(host: str, topic: str | None, file: str, seconds: float):
    base = f"http://{host}:8000"
    alerts = []
    async with websockets.connect(f"ws://{host}:8000/ws/transcript") as ws:
        async def listen():
            async for raw in ws:
                m = json.loads(raw)
                t = m["type"]
                if t == "transcript":
                    print(f"  [transcript #{m['index']}] {m['transcript']}")
                elif t == "noise_alert":
                    alerts.append(m)
                    print(f"  [NOISE ALERT] sim={m['cosine_similarity']:.2f} {m['transcript']}")
                elif t == "buffer_flushed":
                    print(f"  [FLUSH] {m['chunks']} chunks, {m['flagged']} flagged, "
                          f"threshold={m['threshold']}, cold_start={m['cold_start']}, "
                          f"topic_updated={m['topic_updated']}")
                elif t == "override_updated":
                    print(f"  [override_updated] {m['user_override']}: {m['transcript'][:50]}")

        listener = asyncio.create_task(listen())
        async with httpx.AsyncClient(base_url=base, timeout=120) as http:
            body = {"title": "End-to-end test", "source_file": file}
            if topic:
                body["seminar_topic"] = topic
            r = (await http.post("/api/v1/session/start", json=body)).json()
            sid = r["session_id"]
            print(f"START seminar_topic={r['seminar_topic']!r}")
            await asyncio.sleep(seconds)
            print("STOP:", (await http.post("/api/v1/session/stop")).json())
            await asyncio.sleep(0.5)

            chunks = (await http.get(f"/api/v1/session/{sid}/chunks")).json()["chunks"]
            print("\nAll chunks in DB (sim / noise / override):")
            for c in chunks:
                print(f"  {c['cosine_similarity']:5.2f}  {'NOISE' if c['is_noise'] else '     '}"
                      f"  {c['user_override']:8} {c['transcript']}")

            # Review: KEEP the first flagged chunk, DELETE the rest; also exercise
            # "DELETED" on a non-noise chunk so the WHERE clause is fully tested.
            if alerts:
                await http.patch(f"/api/v1/chunk/{alerts[0]['chunk_id']}/override",
                                 json={"status": "KEPT"})
                for a in alerts[1:]:
                    await http.patch(f"/api/v1/chunk/{a['chunk_id']}/override",
                                     json={"status": "DELETED"})
            clean_ids = [c["chunk_id"] for c in chunks if not c["is_noise"]]
            if clean_ids:
                await http.patch(f"/api/v1/chunk/{clean_ids[0]}/override",
                                 json={"status": "DELETED"})
            bad = await http.patch("/api/v1/chunk/nope/override", json={"status": "KEPT"})
            bad2 = await http.patch(f"/api/v1/chunk/{chunks[0]['chunk_id']}/override",
                                    json={"status": "MAYBE"})
            print(f"\nunknown chunk -> {bad.status_code}, bad status -> {bad2.status_code}")
            await asyncio.sleep(0.3)

            clean = (await http.get(f"/api/v1/session/{sid}/clean-transcript")).json()
            print(f"\nCLEAN TRANSCRIPT ({clean['chunks']} of {len(chunks)} chunks):")
            for c in clean["items"]:
                print(f"  {'NOISE' if c['is_noise'] else '     '} {c['user_override']:8} {c['transcript']}")
        listener.cancel()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--topic", default=None, help="seminar_topic (omit for default)")
    p.add_argument("--file", default="data/audio/e2e_test.wav")
    p.add_argument("--seconds", type=float, default=69)
    a = p.parse_args()
    asyncio.run(main(a.host, a.topic, a.file, a.seconds))

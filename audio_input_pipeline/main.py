"""
AI Vision Notes - Audio Pipeline Backend

Run (from this folder, venv active - see README.md):
      python -m uvicorn main:app --host 0.0.0.0 --port 8000
      (--host 0.0.0.0 so the Flutter mobile app on the same Wi-Fi can connect)
Docs: http://127.0.0.1:8000/docs
UI:   http://localhost:8000/   (browser mic needs localhost or https)
"""

from dotenv import load_dotenv

load_dotenv()  # before project imports: modules read their settings at import time

import asyncio
import logging
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

import numpy as np
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import audio_pipeline
import db
import semantic
import storage
from audio_pipeline import AudioPipeline

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("main")


class ConnectionManager:
    """Keeps track of connected WebSocket clients and pushes JSON to all of them."""

    def __init__(self):
        self.clients: set[WebSocket] = set()

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.clients.add(ws)

    def disconnect(self, ws: WebSocket):
        self.clients.discard(ws)

    async def broadcast(self, message: dict):
        for ws in list(self.clients):
            try:
                await ws.send_json(message)
            except Exception:
                self.disconnect(ws)


manager = ConnectionManager()
pipeline = AudioPipeline(broadcast=manager.broadcast)


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    # Load the embedding model in the background so startup stays fast;
    # a session started before it finishes just waits on the model lock.
    asyncio.create_task(asyncio.to_thread(semantic.get_model))
    yield
    await pipeline.stop()  # release the mic on server shutdown
    db.close()  # Postgres connection pool


app = FastAPI(
    title="AI Vision Notes - Audio Pipeline",
    description="Audio Input -> STT -> Buffer -> Vector Storage -> Noise Flagging",
    version="0.4.0",
    lifespan=lifespan,
)

# Flutter web (flutter run -d chrome) is served from another port, so the browser
# needs CORS for the REST calls. Mobile builds don't need it.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

STATIC_DIR = Path(__file__).parent / "static"
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


class SessionStart(BaseModel):
    title: str = "Untitled Lecture"
    seminar_topic: str = semantic.DEFAULT_SEMINAR_TOPIC  # seeds the topic vector
    # server_mic: laptop mic read by the server | browser: web page streams PCM to /ws/audio
    source: Literal["server_mic", "browser"] = "server_mic"
    warmup: bool | None = None  # mic calibration; None = on for mic sources
    device: int | None = None  # server_mic device index; None = system default
    source_file: str | None = None  # testing: stream this WAV instead of the mic


class OverrideRequest(BaseModel):
    status: str  # KEPT / DELETED (also accepts SRS values KEEP / DISMISS, and PENDING)


class EditRequest(BaseModel):
    text: str | None  # corrected text; null = undo the edit (original text, default status)


def _chunk_json(row) -> dict:
    return {
        "chunk_id": row["chunk_id"],
        "index": row["chunk_index"],
        "start_timestamp": row["start_timestamp"],
        "end_timestamp": row["end_timestamp"],
        "transcript": row["transcript_text"],
        "provider": row["stt_provider"],
        "cosine_similarity": None if row["similarity_score"] is None
        else round(row["similarity_score"], 3),
        "is_noise": bool(row["is_flagged_noise"]),
        "is_mixed": bool(row["is_mixed"]),
        "reason": row["noise_reason"],
        "off_topic": db.off_topic_sentences(row),  # MIXED: cut from the notes unless KEEP
        "edited_text": row["edited_text"],  # user's correction; transcript stays the original
        "user_override": row["user_override_status"],
        "container_index": row["container_index"],
    }


@app.get("/", include_in_schema=False)
def root():
    """Browser test console (static/index.html)."""
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/health")
def health():
    return {
        "status": "healthy",
        "recording": pipeline.running,
        "mic_status": pipeline.mic_status,
        "flush_interval_seconds": audio_pipeline.FLUSH_INTERVAL_SECONDS,
        "noise_scoring": semantic.NOISE_SCORING,
        "database": "postgres",
        "audio_storage": "supabase" if storage.ENABLED else "local",
    }


@app.post("/api/v1/session/start")
async def session_start(body: SessionStart):
    if pipeline.running:
        raise HTTPException(409, f"session {pipeline.session_id} already active")
    session_id = str(uuid.uuid4())
    topic = body.seminar_topic.strip() or semantic.DEFAULT_SEMINAR_TOPIC
    seed = await asyncio.to_thread(semantic.seed_vector, topic)
    await asyncio.to_thread(db.create_session, session_id, body.title, topic, seed)
    audio_pipeline.text_accumulator.clear()
    await pipeline.start(session_id, device=body.device, source_file=body.source_file,
                         source=body.source, warmup=body.warmup)
    await manager.broadcast({"type": "session_started", "session_id": session_id,
                             "title": body.title, "seminar_topic": topic})
    return {"session_id": session_id, "title": body.title, "seminar_topic": topic,
            "status": "ACTIVE"}


@app.post("/api/v1/session/stop")
async def session_stop():
    if not pipeline.running:
        raise HTTPException(409, "no active session")
    await pipeline.stop()  # also flushes the leftover buffer
    session_id = pipeline.session_id
    await asyncio.to_thread(db.end_session, session_id)
    await manager.broadcast({"type": "session_stopped", "session_id": session_id})
    chunks = await asyncio.to_thread(db.list_chunks, session_id)
    session = await asyncio.to_thread(db.get_session, session_id)
    return {
        "session_id": session_id,
        "status": "COMPLETED",
        "chunks_transcribed": len(chunks),
        "chunks_flagged": sum(1 for c in chunks if c["is_flagged_noise"]),
        "chunks_mixed": sum(1 for c in chunks if c["is_mixed"]),
        # topic guard fired: the session didn't match seminar_topic - is the topic right?
        "topic_match": None if session["topic_match"] is None
        else round(session["topic_match"], 3),
        "topic_guard": bool(session["topic_guard"]),
    }


@app.patch("/api/v1/chunk/{chunk_id}/override")
async def chunk_override(chunk_id: str, body: OverrideRequest):
    """Red-Box console action: KEPT (include in notes, whole chunk) or DELETED (exclude).
    PENDING: noise stays out, a MIXED chunk goes in without its off-topic sentence(s)."""
    status = db.OVERRIDE_ALIASES.get(body.status.strip().upper())
    if status is None:
        raise HTTPException(422, "status must be KEPT, DELETED or PENDING")
    row = await asyncio.to_thread(db.set_override, chunk_id, status)
    if row is None:
        raise HTTPException(404, "chunk not found")
    chunk = _chunk_json(row)
    await manager.broadcast({"type": "override_updated", "session_id": row["session_id"], **chunk})
    return chunk


@app.patch("/api/v1/chunk/{chunk_id}/text")
async def chunk_edit(chunk_id: str, body: EditRequest):
    """Red-Box console action: Edit. Saves the corrected text and KEEPs the chunk;
    the notes use it as-is. text=null undoes the edit: original text, and PENDING if
    the chunk is flagged (back to review) or KEEP if it is not."""
    text = None if body.text is None else " ".join(body.text.split())
    if text == "":
        raise HTTPException(422, "text is empty - use DELETED to drop the chunk")
    row = await asyncio.to_thread(db.set_edited_text, chunk_id, text)
    if row is None:
        raise HTTPException(404, "chunk not found")
    chunk = _chunk_json(row)
    await manager.broadcast({"type": "chunk_edited", "session_id": row["session_id"], **chunk})
    return chunk


@app.get("/api/v1/session/{session_id}/chunks")
async def session_chunks(session_id: str):
    """All chunks incl. flagged noise - for the Red-Box review console."""
    if await asyncio.to_thread(db.get_session, session_id) is None:
        raise HTTPException(404, "session not found")
    rows = await asyncio.to_thread(db.list_chunks, session_id)
    return {"session_id": session_id, "chunks": [_chunk_json(r) for r in rows]}


@app.get("/api/v1/session/{session_id}/flagged")
async def session_flagged(session_id: str):
    """The Red-Box review list: chunks flagged as noise plus MIXED chunks."""
    if await asyncio.to_thread(db.get_session, session_id) is None:
        raise HTTPException(404, "session not found")
    rows = await asyncio.to_thread(db.list_chunks, session_id, False, True)
    return {"session_id": session_id, "chunks": [_chunk_json(r) for r in rows]}


@app.get("/api/v1/session/{session_id}/containers")
async def session_containers(session_id: str):
    """10-minute containers (built on stop) - for the timeline/heatmap."""
    if await asyncio.to_thread(db.get_session, session_id) is None:
        raise HTTPException(404, "session not found")
    rows = await asyncio.to_thread(db.list_containers, session_id)
    return {"session_id": session_id,
            "container_seconds": audio_pipeline.CONTAINER_SECONDS,
            "containers": [{**dict(r), "topic_similarity": None if r["topic_similarity"] is None
                            else round(r["topic_similarity"], 3)} for r in rows]}


@app.get("/api/v1/session/{session_id}/clean-transcript")
async def clean_transcript(session_id: str):
    """Transcript for note synthesis: noise removed unless the user KEPT it, and the
    off-topic sentences of MIXED chunks removed unless the user KEPT the chunk."""
    session = await asyncio.to_thread(db.get_session, session_id)
    if session is None:
        raise HTTPException(404, "session not found")
    rows = await asyncio.to_thread(db.list_chunks, session_id, True)
    items = [{**_chunk_json(r), "clean_text": db.clean_text(r)} for r in rows]
    items = [i for i in items if i["clean_text"]]
    return {
        "session_id": session_id,
        "title": session["title"],
        "seminar_topic": session["seminar_topic"],
        "chunks": len(items),
        "clean_text": " ".join(i["clean_text"] for i in items),
        "items": items,
    }


@app.get("/api/v1/transcript/buffer")
def transcript_buffer():
    """Chunks transcribed since the last flush (not yet noise-scored)."""
    buf = audio_pipeline.text_accumulator
    return {
        "session_id": pipeline.session_id,
        "chunks": len(buf),
        "merged_text": " ".join(c["transcript"] for c in buf),
        "items": buf,
    }


@app.websocket("/ws/transcript")
async def ws_transcript(websocket: WebSocket):
    """Live transcript stream. Server pushes JSON; client doesn't need to send anything."""
    await manager.connect(websocket)
    try:
        while True:
            await websocket.receive_text()  # keeps the connection open; input ignored
    except WebSocketDisconnect:
        manager.disconnect(websocket)


@app.websocket("/ws/audio")
async def ws_audio(websocket: WebSocket):
    """Audio upstream for source="browser": binary frames of 16 kHz mono int16 LE PCM."""
    await websocket.accept()
    if not (pipeline.running and pipeline.source == "browser"):
        await websocket.close(code=1008, reason="no active browser-source session")
        return
    frames = 0
    try:
        while True:
            data = await websocket.receive_bytes()
            if len(data) % 2:
                data = data[:-1]
            if not pipeline.push_audio(np.frombuffer(data, dtype="<i2").copy()):
                await websocket.close(code=1000, reason="session ended")
                break
            frames += 1
    except WebSocketDisconnect:
        pass
    log.info("browser audio stream closed after %d frames", frames)


@app.websocket("/ws/test")
async def ws_test(websocket: WebSocket):
    """Echo WebSocket - just to verify the client (Flutter/browser) can connect."""
    await websocket.accept()
    try:
        while True:
            msg = await websocket.receive_text()
            await websocket.send_text(f"echo: {msg}")
    except WebSocketDisconnect:
        pass

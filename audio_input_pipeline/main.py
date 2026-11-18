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
import sys
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

import cv2
import numpy as np
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import audio_pipeline
import db
import semantic
import storage
from audio_pipeline import AudioPipeline

from authentication.routes import router as auth_router
from feedback.routes import router as feedback_router

# Bridge Image/Vision Pipeline components
IMAGE_DIR = Path(__file__).resolve().parent.parent / "Image_input_pipeline"
if str(IMAGE_DIR) not in sys.path:
    sys.path.insert(0, str(IMAGE_DIR))

# Bridge Notes Generation Subsystem
ROOT_DIR = Path(__file__).resolve().parent.parent
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

try:
    from model import PrivacyModel
    from enhance import enhance_slide
    import ocr
    import approve_store
    privacy_model_instance = PrivacyModel()
except Exception as _e:
    privacy_model_instance = None
    enhance_slide = None
    ocr = None
    approve_store = None

try:
    import notes_generation
except Exception as _e:
    notes_generation = None

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
    try:
        db.init_db()
        log.info("Supabase database connection initialized successfully.")
    except Exception as e:
        log.warning("Database connection failed or not configured (%s). Server starting in memory/streaming mode.", e)
    # Load the embedding model in the background so startup stays fast;
    # a session started before it finishes just waits on the model lock.
    asyncio.create_task(asyncio.to_thread(semantic.get_model))

    # 7-day auto-deletion background loop: purges expired completed session inputs
    async def _periodic_retention_cleanup():
        while True:
            try:
                purged = await asyncio.to_thread(db.cleanup_expired_sessions)
                if purged:
                    log.info("7-day auto-cleanup purged %d expired session(s): %s", len(purged), purged)
                    for sid in purged:
                        await asyncio.to_thread(storage.delete_session_audio, sid)
            except Exception as e:
                log.warning("Periodic retention cleanup check: %s", e)
            await asyncio.sleep(3600)

    cleanup_loop_task = asyncio.create_task(_periodic_retention_cleanup())

    yield
    cleanup_loop_task.cancel()
    await pipeline.stop()  # release the mic on server shutdown
    try:
        db.close()  # Postgres connection pool
    except Exception:
        pass



app = FastAPI(
    title="AI Vision Notes - Audio Pipeline",
    description="Audio Input -> STT -> Buffer -> Vector Storage -> Noise Flagging",
    version="0.4.0",
    lifespan=lifespan,
)

# Register Authentication and Feedback API routes
app.include_router(auth_router)
app.include_router(feedback_router)

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
    session_id: str | None = None  # optional client-provided session id for audio/vision alignment
    user_id: str | None = None  # owner of the session (e.g. email)


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
        "vision_model": "yolov8_loaded" if privacy_model_instance is not None else "bypass",
        "ocr_available": ocr is not None,
        "notes_generation_available": notes_generation is not None,
    }


@app.get("/api/v1/user/{user_id}/session-quota")
async def user_session_quota(user_id: str):
    """Enforce Scenario 2: Maximum of 2 unfinished sessions per user."""
    unfinished_count = await asyncio.to_thread(db.count_unfinished_sessions, user_id)
    return {
        "user_id": user_id,
        "unfinished_sessions": unfinished_count,
        "max_allowed": 2,
        "can_create_new": unfinished_count < 2,
        "message": "Storage limit reached (2/2 unfinished sessions). Please complete or delete an existing session first." if unfinished_count >= 2 else "Quota OK",
    }


@app.post("/api/v1/session/start")
async def session_start(body: SessionStart):
    if pipeline.running:
        raise HTTPException(409, f"session {pipeline.session_id} already active")

    # Enforce Scenario 2: Maximum of 2 unfinished sessions per user
    if body.user_id:
        unfinished_count = await asyncio.to_thread(db.count_unfinished_sessions, body.user_id)
        if unfinished_count >= 2:
            raise HTTPException(
                403,
                f"Storage limit reached: You have {unfinished_count} unfinished sessions saved. "
                "A maximum of 2 unfinished sessions is allowed due to Supabase storage limitations. "
                "Please generate notes for an existing session or delete it before starting a new one."
            )

    session_id = body.session_id or str(uuid.uuid4())
    topic = body.seminar_topic.strip() or semantic.DEFAULT_SEMINAR_TOPIC
    seed = await asyncio.to_thread(semantic.seed_vector, topic)
    await asyncio.to_thread(db.create_session, session_id, body.title, topic, seed, body.user_id)
    audio_pipeline.text_accumulator.clear()
    await pipeline.start(session_id, device=body.device, source_file=body.source_file,
                         source=body.source, warmup=body.warmup)
    await manager.broadcast({"type": "session_started", "session_id": session_id,
                             "title": body.title, "seminar_topic": topic, "user_id": body.user_id})
    return {"session_id": session_id, "title": body.title, "seminar_topic": topic,
            "status": "ACTIVE", "user_id": body.user_id}


@app.delete("/api/v1/session/{session_id}/inputs")
async def delete_session_inputs_endpoint(session_id: str):
    """Scenario 1: Permanently deletes session inputs from Supabase DB and Storage while preserving the generated note."""
    success = await asyncio.to_thread(db.purge_session_inputs, session_id)
    await asyncio.to_thread(storage.delete_session_audio, session_id)
    return {
        "session_id": session_id,
        "status": "INPUTS_DISCARDED",
        "message": "Raw audio chunks, containers, and snapshots purged from Supabase. Generated notes preserved.",
        "success": success,
    }


@app.post("/api/v1/sessions/cleanup-expired")
async def cleanup_expired_sessions_endpoint():
    """7-day automatic deletion mechanism for completed sessions whose inputs were retained."""
    purged_ids = await asyncio.to_thread(db.cleanup_expired_sessions)
    for sid in purged_ids:
        await asyncio.to_thread(storage.delete_session_audio, sid)
    return {
        "purged_count": len(purged_ids),
        "purged_session_ids": purged_ids,
        "status": "SUCCESS",
    }


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



# ==============================================================================
# Vision & Board Snapshot REST Endpoints
# ==============================================================================

SNAPSHOTS_DIR = STATIC_DIR / "snapshots"
SNAPSHOTS_DIR.mkdir(parents=True, exist_ok=True)


class SnapshotPreferenceRequest(BaseModel):
    preference: str  # IMAGE_ONLY, OCR_TEXT_ONLY, BOTH


@app.post("/api/v1/vision/process-snapshot")
async def process_snapshot(
    file: UploadFile = File(...),
    session_id: str = Form("lecture_session_01"),
    privacy_target: str = Form("full_body"),
    enhancement_mode: str = Form("magic_color"),
    note_preference: str = Form("BOTH"),
):
    """
    Receives an uploaded board image from mobile camera, applies YOLOv8 privacy blur,
    enhances slide contrast, extracts OCR text, uploads to Supabase (if configured),
    and saves locally in static/snapshots/.
    """
    try:
        contents = await file.read()
        np_arr = np.frombuffer(contents, np.uint8)
        frame = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
        if frame is None:
            raise HTTPException(400, "Invalid image data received.")
    except Exception as e:
        raise HTTPException(400, f"Error decoding image: {e}")

    snapshot_id = f"snap_{uuid.uuid4().hex[:10]}"
    timestamp = 0.0

    # 1. Privacy Blurring (YOLOv8)
    human_count = 0
    human_mask = None
    processed_frame = frame
    if privacy_model_instance is not None:
        try:
            processed_frame, human_count, human_mask = privacy_model_instance.apply_privacy_blur(
                frame, timestamp=timestamp, target_mode=privacy_target
            )
        except Exception as e:
            log.warning("YOLOv8 blur failed (%s), proceeding with original frame.", e)
            processed_frame = frame

    # 2. Slide Enhancement (CamScanner-style leveling & sharpening)
    if enhance_slide is not None:
        try:
            processed_frame = enhance_slide(
                processed_frame, timestamp=timestamp, mode=enhancement_mode, human_mask=human_mask
            )
        except Exception as e:
            log.warning("Enhancement failed (%s), keeping processed frame.", e)

    # 3. Save locally to static/snapshots/
    local_filename = f"{snapshot_id}.jpg"
    local_path = SNAPSHOTS_DIR / local_filename
    cv2.imwrite(str(local_path), processed_frame)
    local_image_url = f"/static/snapshots/{local_filename}"

    # 4. Extract OCR text
    extracted_text = ""
    avg_conf = 0.0
    if ocr is not None:
        try:
            extracted_text, avg_conf = ocr.process_ocr_worker(
                snapshot_id, session_id, processed_frame, human_mask, note_preference
            )
        except Exception as e:
            log.warning("OCR processing failed (%s).", e)
            extracted_text = "[No legible text extracted]"
            avg_conf = 0.0
    else:
        extracted_text = "[OCR module not available]"

    # 5. Save to Supabase Storage & Database (if configured)
    if approve_store is not None:
        try:
            snapshot_data = {
                "snapshot_id": snapshot_id,
                "session_id": session_id,
                "sequence_timestamp": timestamp,
                "captured_timestamp": timestamp,
                "frame": processed_frame,
                "status": "APPROVED",
                "note_inclusion_preference": note_preference,
                "is_replacement": False,
            }
            approve_store.save_snapshot_to_supabase(snapshot_data)
        except Exception as e:
            log.warning("Supabase snapshot persistence failed (%s).", e)

    # Broadcast event to WebSocket clients
    await manager.broadcast({
        "type": "snapshot_captured",
        "snapshot_id": snapshot_id,
        "session_id": session_id,
        "blurred_image_url": local_image_url,
        "extracted_text": extracted_text,
        "people_detected": human_count,
        "confidence_score": round(avg_conf, 2),
    })

    return {
        "snapshot_id": snapshot_id,
        "session_id": session_id,
        "blurred_image_url": local_image_url,
        "extracted_text": extracted_text,
        "confidence_score": round(avg_conf, 2),
        "people_detected": human_count,
        "note_inclusion_preference": note_preference,
        "status": "APPROVED",
    }


@app.patch("/api/v1/vision/snapshot/{snapshot_id}/preference")
async def update_snapshot_preference(snapshot_id: str, body: SnapshotPreferenceRequest):
    """Updates whether the snapshot includes IMAGE_ONLY, OCR_TEXT_ONLY, or BOTH."""
    pref = body.preference.strip().upper()
    if pref not in ("IMAGE_ONLY", "OCR_TEXT_ONLY", "BOTH"):
        raise HTTPException(422, "preference must be IMAGE_ONLY, OCR_TEXT_ONLY, or BOTH")
    if approve_store is not None and approve_store.is_supabase_configured():
        url, key = approve_store.get_supabase_config()
        endpoint = f"{url}/rest/v1/image_snapshots?snapshot_id=eq.{snapshot_id}"
        headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
        import urllib.request, json as _json
        req = urllib.request.Request(endpoint, data=_json.dumps({"note_inclusion_preference": pref}).encode("utf-8"), headers=headers, method="PATCH")
        try:
            with urllib.request.urlopen(req, timeout=5):
                pass
        except Exception as e:
            log.warning("Failed updating preference in Supabase: %s", e)
    return {"snapshot_id": snapshot_id, "note_inclusion_preference": pref, "status": "UPDATED"}


# ==============================================================================
# Notes Generation REST Endpoints
# ==============================================================================

class GenerateNotesRequest(BaseModel):
    session_id: str
    user_id: str = "default_user"
    session_data: dict | None = None


@app.post("/api/v1/notes/generate")
async def generate_notes_endpoint(body: GenerateNotesRequest):
    """
    Synthesizes academic lecture notes from transcribed audio chunks and board snapshots.
    Integrates Gemini AI multimodal synthesis, builds styled Word .docx,
    uploads to Supabase Storage, and saves record to public.generated_notes.
    """
    if notes_generation is None:
        raise HTTPException(500, "Notes generation module not available on server.")

    result = await asyncio.to_thread(
        notes_generation.generate_notes_for_session,
        body.session_id,
        body.user_id,
        body.session_data,
    )
    return result


@app.get("/api/v1/notes/session/{session_id}")
async def get_session_notes_endpoint(session_id: str):
    """Fetches generated notes record for a given session."""
    if notes_generation is not None:
        note = await asyncio.to_thread(notes_generation.get_note_by_session, session_id)
        if note:
            return note
    raise HTTPException(404, f"No generated notes found for session '{session_id}'")


@app.get("/api/v1/notes/{session_id}/docx")
async def download_note_docx(session_id: str):
    """Downloads or streams the generated Word .docx document for a session."""
    for d in [Path.home() / "Desktop", Path.home() / "Documents", ROOT_DIR / "generated_notes_docs"]:
        candidate = d / f"{session_id}_notes.docx"
        if candidate.exists():
            return FileResponse(
                path=candidate,
                filename=f"{session_id}_notes.docx",
                media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            )
    raise HTTPException(404, f"DOCX file for session '{session_id}' not found.")


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


if __name__ == "__main__":
    import uvicorn
    print("\n" + "=" * 65)
    print("  AI VISION GLASSES - AUDIO BACKEND SERVER")
    print("  Open in Browser: http://localhost:8000/")
    print("  API Docs:        http://localhost:8000/docs")
    print("  (Note: In Windows browsers, open localhost:8000, not 0.0.0.0)")
    print("=" * 65 + "\n")
    uvicorn.run(app, host="0.0.0.0", port=8000)



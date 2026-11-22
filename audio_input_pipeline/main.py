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
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal
import httpx

# Ensure local pipeline modules can be imported regardless of execution working directory
CURRENT_DIR = Path(__file__).resolve().parent
if str(CURRENT_DIR) not in sys.path:
    sys.path.insert(0, str(CURRENT_DIR))

import cv2
import numpy as np
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, UploadFile, File, Form, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import audio_pipeline
import db
import semantic
import storage
from audio_pipeline import AudioPipeline

from fastapi import Depends
from authentication.dependencies import AUTH_REQUIRED, get_request_user, user_from_token
from authentication.routes import router as auth_router
from authentication.schemas import AuthenticatedUser
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
    """Keeps track of connected WebSocket clients and pushes each session's events only
    to its owner. A client connected without a token (AUTH_REQUIRED=false) gets all."""

    def __init__(self):
        self.clients: dict[WebSocket, str | None] = {}  # ws -> user id (None = no token)
        self.owners: dict[str, str | None] = {}          # session_id -> owner user id

    async def connect(self, ws: WebSocket, user_id: str | None = None):
        await ws.accept()
        self.clients[ws] = user_id

    def disconnect(self, ws: WebSocket):
        self.clients.pop(ws, None)

    def _receives(self, client_user: str | None, message: dict) -> bool:
        # Hardware device events (glasses/ESP32) broadcast to ALL authenticated clients
        # so images always appear in the Flutter studio regardless of session ownership.
        msg_type = message.get("type", "")
        if msg_type in ("glasses_snapshot", "snapshot_captured", "ocr_ready"):
            return True
        if client_user is None:
            return not AUTH_REQUIRED
        owner = self.owners.get(message.get("session_id"))
        return owner is not None and owner == client_user

    async def broadcast(self, message: dict):
        for ws, client_user in list(self.clients.items()):
            if not self._receives(client_user, message):
                continue
            try:
                await ws.send_json(message)
            except Exception:
                self.disconnect(ws)


manager = ConnectionManager()
pipeline = AudioPipeline(broadcast=manager.broadcast)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # The embedding model (~30 s+, mostly importing torch) and the database connection
    # load in parallel; the server reports ready only when both are done, so the first
    # session start doesn't hang while the app already thinks the server is up.
    t0 = time.perf_counter()
    model_task = asyncio.create_task(asyncio.to_thread(semantic.get_model))
    try:
        # switches to in-memory mode (and logs why) if Postgres stays unusable
        await asyncio.to_thread(db.init_db)
    except Exception as e:
        log.error("Database init raised unexpectedly (%s).", e)
    if not db.is_memory_mode():
        log.info("Supabase database connection initialized successfully.")
    await model_task
    log.info("Embedding model ready in %.1f s - server ready.", time.perf_counter() - t0)

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
import os
from authentication.dependencies import set_auth_provider
from authentication.providers import SupabaseAuthProvider

_SUPABASE_URL = os.getenv("SUPABASE_URL", "").strip()
_SUPABASE_ANON_KEY = os.getenv("SUPABASE_KEY", "").strip()  # publishable/anon key
if _SUPABASE_URL and _SUPABASE_ANON_KEY:
    set_auth_provider(SupabaseAuthProvider(_SUPABASE_URL, _SUPABASE_ANON_KEY))
else:
    log.warning("SUPABASE_URL / SUPABASE_KEY not set: /api/v1/auth/* will return 503.")

from feedback.dependencies import set_feedback_repository
from feedback.repository import PostgresFeedbackRepository

set_feedback_repository(PostgresFeedbackRepository())

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


CurrentUser = Depends(get_request_user)  # AuthenticatedUser, or None if AUTH_REQUIRED=false


async def _owned_session(session_id: str, user: AuthenticatedUser | None) -> dict:
    """The session if `user` owns it. 404 (not 403) for someone else's session, so a
    caller can't tell whether a session id exists."""
    session = await asyncio.to_thread(db.get_session, session_id) if session_id else None
    if session is None or (user is not None and session.get("user_id") != user.id):
        raise HTTPException(404, "session not found")
    manager.owners[session_id] = session.get("user_id")  # live events go to this owner
    return session


async def _owned_chunk_session(chunk_id: str, user: AuthenticatedUser | None) -> dict:
    session_id = await asyncio.to_thread(db.chunk_session_id, chunk_id)
    if session_id is None:
        raise HTTPException(404, "chunk not found")
    try:
        return await _owned_session(session_id, user)
    except HTTPException:
        raise HTTPException(404, "chunk not found")


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
        "database": "memory" if db.is_memory_mode() else "postgres",
        "audio_storage": "supabase" if storage.ENABLED else "local",
        "vision_model": "yolov8_loaded" if privacy_model_instance is not None else "bypass",
        "ocr_available": ocr is not None,
        "notes_generation_available": notes_generation is not None,
    }


MAX_UNFINISHED_SESSIONS = int(os.getenv("MAX_UNFINISHED_SESSIONS", "5"))


@app.get("/api/v1/user/{user_id}/session-quota")
async def user_session_quota(user_id: str, user: AuthenticatedUser | None = CurrentUser):
    """Enforce Scenario 2: Maximum unfinished sessions per user."""
    if user is not None and user_id not in (user.id, "me"):
        raise HTTPException(403, "You can only check your own quota.")
    if user is not None:
        user_id = user.id
    unfinished_count = await asyncio.to_thread(db.count_unfinished_sessions, user_id)
    return {
        "user_id": user_id,
        "unfinished_sessions": unfinished_count,
        "max_allowed": MAX_UNFINISHED_SESSIONS,
        "can_create_new": unfinished_count < MAX_UNFINISHED_SESSIONS,
        "message": f"Storage limit reached ({MAX_UNFINISHED_SESSIONS}/{MAX_UNFINISHED_SESSIONS} unfinished sessions). Please complete or delete an existing session first." if unfinished_count >= MAX_UNFINISHED_SESSIONS else "Quota OK",
    }


@app.post("/api/v1/session/start")
async def session_start(body: SessionStart, user: AuthenticatedUser | None = CurrentUser):
    if pipeline.running:
        # don't reveal another user's session id
        mine = user is None or manager.owners.get(pipeline.session_id) == user.id
        raise HTTPException(409, f"session {pipeline.session_id} already active" if mine
                            else "Another recording is already running on the server.")

    # the owner comes from the token; body.user_id is only used without login (dev mode)
    owner_id = user.id if user is not None else body.user_id
    if body.session_id and user is not None:
        existing = await asyncio.to_thread(db.get_session, body.session_id)
        if existing is not None and existing.get("user_id") != user.id:
            raise HTTPException(409, "session_id is already in use - start without one.")

    # Enforce Scenario 2: Maximum unfinished sessions per user
    if owner_id:
        unfinished_count = await asyncio.to_thread(db.count_unfinished_sessions, owner_id)
        if unfinished_count >= MAX_UNFINISHED_SESSIONS:
            raise HTTPException(
                403,
                f"Storage limit reached: You have {unfinished_count} unfinished sessions saved. "
                f"A maximum of {MAX_UNFINISHED_SESSIONS} unfinished sessions is allowed due to Supabase storage limitations. "
                "Please generate notes for an existing session or delete it before starting a new one."
            )

    session_id = body.session_id or str(uuid.uuid4())
    topic = body.seminar_topic.strip() or semantic.DEFAULT_SEMINAR_TOPIC
    seed = await asyncio.to_thread(semantic.seed_vector, topic)
    await asyncio.to_thread(db.create_session, session_id, body.title, topic, seed, owner_id)
    manager.owners[session_id] = owner_id
    audio_pipeline.text_accumulator.clear()
    await pipeline.start(session_id, device=body.device, source_file=body.source_file,
                         source=body.source, warmup=body.warmup)
    await manager.broadcast({"type": "session_started", "session_id": session_id,
                             "title": body.title, "seminar_topic": topic, "user_id": owner_id})
    return {"session_id": session_id, "title": body.title, "seminar_topic": topic,
            "status": "ACTIVE", "user_id": owner_id}


@app.delete("/api/v1/session/{session_id}/inputs")
async def delete_session_inputs_endpoint(session_id: str, user: AuthenticatedUser | None = CurrentUser):
    """Scenario 1: Permanently deletes session inputs from Supabase DB and Storage while preserving the generated note."""
    await _owned_session(session_id, user)
    success = await asyncio.to_thread(db.purge_session_inputs, session_id)
    await asyncio.to_thread(storage.delete_session_audio, session_id)
    return {
        "session_id": session_id,
        "status": "INPUTS_DISCARDED",
        "message": "Raw audio chunks, containers, and snapshots purged from Supabase. Generated notes preserved.",
        "success": success,
    }


@app.post("/api/v1/sessions/cleanup-expired")
async def cleanup_expired_sessions_endpoint(user: AuthenticatedUser | None = CurrentUser):
    """7-day automatic deletion mechanism for completed sessions whose inputs were retained.
    Runs by itself every hour; this manual trigger touches every user's data, so admin only."""
    if user is not None and user.role != "admin":
        raise HTTPException(403, "Admin only.")
    purged_ids = await asyncio.to_thread(db.cleanup_expired_sessions)
    for sid in purged_ids:
        await asyncio.to_thread(storage.delete_session_audio, sid)
    return {
        "purged_count": len(purged_ids),
        "purged_session_ids": purged_ids,
        "status": "SUCCESS",
    }


class SessionStop(BaseModel):
    """Optional: the name the user gives when stopping. Applied before the final flush,
    so noise scoring uses it (with FLUSH_INTERVAL_SECONDS=0 that is the only flush)."""
    title: str | None = None
    seminar_topic: str | None = None  # empty/None = keep the start topic


@app.post("/api/v1/session/stop")
async def session_stop(body: SessionStop | None = None,
                       user: AuthenticatedUser | None = CurrentUser):
    if not pipeline.running:
        raise HTTPException(409, "no active session")
    if user is not None and manager.owners.get(pipeline.session_id) != user.id:
        raise HTTPException(409, "no active session")  # someone else's recording
    session_id = pipeline.session_id
    if body is not None:
        title = (body.title or "").strip() or None
        topic = (body.seminar_topic or "").strip() or None
        if title or topic:
            seed = await asyncio.to_thread(semantic.seed_vector, topic) if topic else None
            await asyncio.to_thread(db.rename_session, session_id, title, topic, seed)
    await pipeline.stop()  # also flushes the leftover buffer
    await asyncio.to_thread(db.end_session, session_id)
    await manager.broadcast({"type": "session_stopped", "session_id": session_id})
    chunks = await asyncio.to_thread(db.list_chunks, session_id)
    session = await asyncio.to_thread(db.get_session, session_id)
    return {
        "session_id": session_id,
        "status": "COMPLETED",
        "title": session["title"],
        "seminar_topic": session["seminar_topic"],
        "chunks_transcribed": len(chunks),
        "chunks_flagged": sum(1 for c in chunks if c["is_flagged_noise"]),
        "chunks_mixed": sum(1 for c in chunks if c["is_mixed"]),
        # topic guard fired: the session didn't match seminar_topic - is the topic right?
        "topic_match": None if session["topic_match"] is None
        else round(session["topic_match"], 3),
        "topic_guard": bool(session["topic_guard"]),
    }


@app.patch("/api/v1/chunk/{chunk_id}/override")
async def chunk_override(chunk_id: str, body: OverrideRequest,
                         user: AuthenticatedUser | None = CurrentUser):
    """Red-Box console action: KEPT (include in notes, whole chunk) or DELETED (exclude).
    PENDING: noise stays out, a MIXED chunk goes in without its off-topic sentence(s)."""
    status = db.OVERRIDE_ALIASES.get(body.status.strip().upper())
    if status is None:
        raise HTTPException(422, "status must be KEPT, DELETED or PENDING")
    await _owned_chunk_session(chunk_id, user)
    row = await asyncio.to_thread(db.set_override, chunk_id, status)
    if row is None:
        raise HTTPException(404, "chunk not found")
    chunk = _chunk_json(row)
    await manager.broadcast({"type": "override_updated", "session_id": row["session_id"], **chunk})
    return chunk


@app.patch("/api/v1/chunk/{chunk_id}/text")
async def chunk_edit(chunk_id: str, body: EditRequest,
                     user: AuthenticatedUser | None = CurrentUser):
    """Red-Box console action: Edit. Saves the corrected text and KEEPs the chunk;
    the notes use it as-is. text=null undoes the edit: original text, and PENDING if
    the chunk is flagged (back to review) or KEEP if it is not."""
    text = None if body.text is None else " ".join(body.text.split())
    if text == "":
        raise HTTPException(422, "text is empty - use DELETED to drop the chunk")
    await _owned_chunk_session(chunk_id, user)
    row = await asyncio.to_thread(db.set_edited_text, chunk_id, text)
    if row is None:
        raise HTTPException(404, "chunk not found")
    chunk = _chunk_json(row)
    await manager.broadcast({"type": "chunk_edited", "session_id": row["session_id"], **chunk})
    return chunk


@app.get("/api/v1/session/{session_id}/chunks")
async def session_chunks(session_id: str, user: AuthenticatedUser | None = CurrentUser):
    """All chunks incl. flagged noise - for the Red-Box review console."""
    await _owned_session(session_id, user)
    rows = await asyncio.to_thread(db.list_chunks, session_id)
    return {"session_id": session_id, "chunks": [_chunk_json(r) for r in rows]}


@app.get("/api/v1/session/{session_id}/flagged")
async def session_flagged(session_id: str, user: AuthenticatedUser | None = CurrentUser):
    """The Red-Box review list: chunks flagged as noise plus MIXED chunks."""
    await _owned_session(session_id, user)
    rows = await asyncio.to_thread(db.list_chunks, session_id, False, True)
    return {"session_id": session_id, "chunks": [_chunk_json(r) for r in rows]}


@app.get("/api/v1/session/{session_id}/containers")
async def session_containers(session_id: str, user: AuthenticatedUser | None = CurrentUser):
    """10-minute containers (built on stop) - for the timeline/heatmap."""
    await _owned_session(session_id, user)
    rows = await asyncio.to_thread(db.list_containers, session_id)
    return {"session_id": session_id,
            "container_seconds": audio_pipeline.CONTAINER_SECONDS,
            "containers": [{**dict(r), "topic_similarity": None if r["topic_similarity"] is None
                            else round(r["topic_similarity"], 3)} for r in rows]}


@app.get("/api/v1/session/{session_id}/clean-transcript")
async def clean_transcript(session_id: str, user: AuthenticatedUser | None = CurrentUser):
    """Transcript for note synthesis: noise removed unless the user KEPT it, and the
    off-topic sentences of MIXED chunks removed unless the user KEPT the chunk."""
    session = await _owned_session(session_id, user)
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
    user: AuthenticatedUser | None = CurrentUser,
):
    """
    Receives an uploaded board image from mobile camera, applies YOLOv8 privacy blur,
    enhances slide contrast, extracts OCR text, uploads to Supabase (if configured),
    and saves locally in static/snapshots/.
    """
    if user is not None:
        # The standalone board camera sends a new id of its own (sess_<millis>): create
        # that session for this user. An existing session must be the user's own.
        if await asyncio.to_thread(db.get_session, session_id) is None:
            if await asyncio.to_thread(db.count_unfinished_sessions, user.id) >= MAX_UNFINISHED_SESSIONS:
                raise HTTPException(403, f"Storage limit reached: a maximum of {MAX_UNFINISHED_SESSIONS} unfinished "
                                         "sessions is allowed. Generate notes for or delete "
                                         "an existing session first.")
            await asyncio.to_thread(db.create_session_if_missing, session_id,
                                    "Board Capture", user.id)
        await _owned_session(session_id, user)  # snapshots only go into your own session
    try:
        contents = await file.read()
        np_arr = np.frombuffer(contents, np.uint8)
        frame = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
        if frame is None:
            raise HTTPException(400, "Invalid image data received.")
    except Exception as e:
        raise HTTPException(400, f"Error decoding image: {e}")

    snapshot_id = f"snap_{uuid.uuid4().hex[:10]}"

    # Blur + enhance + save (~1 s) on the vision thread, so the event loop (audio, live
    # transcript, other requests) is never blocked by image work.
    loop = asyncio.get_running_loop()
    processed_frame, human_count, human_mask, local_image_url = await loop.run_in_executor(
        _vision_pool, _blur_enhance_save, frame, snapshot_id, session_id,
        privacy_target, enhancement_mode, note_preference)

    # OCR (EasyOCR, 5-19 s on this CPU) runs in the background; the app gets the image
    # now and the text from GET /api/v1/vision/snapshot/{id}/ocr (or the ocr_ready event).
    # Notes generation waits for a session's pending OCR, so no text is lost.
    if ocr is not None:
        _start_ocr(snapshot_id, session_id, processed_frame, human_mask, note_preference)
        extracted_text, ocr_status = OCR_PENDING_TEXT, "PENDING"
    else:
        extracted_text, ocr_status = "[OCR module not available]", "DONE"

    await manager.broadcast({
        "type": "snapshot_captured",
        "snapshot_id": snapshot_id,
        "session_id": session_id,
        "blurred_image_url": local_image_url,
        "extracted_text": extracted_text,
        "ocr_status": ocr_status,
        "people_detected": human_count,
        "confidence_score": 0.0,
    })

    return {
        "snapshot_id": snapshot_id,
        "session_id": session_id,
        "blurred_image_url": local_image_url,
        "extracted_text": extracted_text,
        "ocr_status": ocr_status,
        "confidence_score": 0.0,
        "people_detected": human_count,
        "note_inclusion_preference": note_preference,
        "status": "APPROVED",
    }


_latest_glasses_capture: dict | None = None
_last_glasses_ip: str | None = None
_last_glasses_seen: float = 0.0


def _get_most_recent_snapshot() -> dict | None:
    """Returns the latest glasses capture, or the latest saved snapshot from disk."""
    if _latest_glasses_capture:
        return _latest_glasses_capture
    try:
        files = sorted(SNAPSHOTS_DIR.glob("*.jpg"), key=lambda p: p.stat().st_mtime, reverse=True)
        if files:
            latest = files[0]
            snap_id = latest.stem
            text = _ocr_results.get(snap_id, ("[OCR extraction saved with slide]", 0.0))[0]
            return {
                "snapshot_id": snap_id,
                "session_id": "recent_session",
                "image_url": f"/static/snapshots/{latest.name}",
                "extracted_text": text,
                "ocr_status": "DONE",
                "people_detected": 0,
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(latest.stat().st_mtime)),
            }
    except Exception:
        pass
    return None


@app.get("/api/v1/glasses/recent-captures")
async def glasses_recent_captures(limit: int = 20):
    """
    Returns the last N glasses captures as JSON so Flutter can load them
    on startup without needing to have been connected via WebSocket at capture time.
    Each item includes snapshot_id, image_url, extracted_text, timestamp.
    """
    try:
        files = sorted(
            SNAPSHOTS_DIR.glob("snap_glasses_*.jpg"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )[:limit]
    except Exception:
        files = []

    results = []
    for f in files:
        snap_id = f.stem
        ocr_text, _ = _ocr_results.get(snap_id, ("[OCR extraction saved with slide]", 0.0))
        results.append({
            "snapshot_id": snap_id,
            "image_url": f"/static/snapshots/{f.name}",
            "blurred_image_url": f"/static/snapshots/{f.name}",
            "extracted_text": ocr_text,
            "ocr_status": "DONE",
            "source": "esp32_cam",
            "people_detected": 0,
            "timestamp": time.strftime(
                "%Y-%m-%d %H:%M:%S", time.localtime(f.stat().st_mtime)
            ),
        })
    return {"captures": results, "total": len(results)}


@app.get("/api/v1/glasses/capture")
async def glasses_capture_status(request: Request, format: str | None = None):
    """
    Live Visual Monitor for AI Vision Glasses:
    - In Browser: Displays the captured slide photo, YOLOv8 privacy blur, and extracted OCR text.
    - As JSON: Returns system status and latest capture metadata.
    """
    wants_json = format == "json" or "application/json" in request.headers.get("accept", "")
    recent = _get_most_recent_snapshot()

    if wants_json:
        return {
            "status": "ready",
            "endpoint": "/api/v1/glasses/capture",
            "method": "POST",
            "latest_capture": recent,
            "active_session_id": pipeline.session_id if pipeline.running else None,
            "is_recording": pipeline.running,
        }

    # Render interactive live preview HTML page for browser
    if recent:
        img_src = recent.get("image_url") or ""
        ocr_text = recent.get("extracted_text") or "OCR processing…"
        snap_id = recent.get("snapshot_id") or ""
        ts = recent.get("timestamp") or time.strftime("%Y-%m-%d %H:%M:%S")
        people = recent.get("people_detected", 0)
        content_html = f"""
        <div class="card">
            <div class="header">
                <span class="badge live">📸 LATEST CAPTURED SLIDE</span>
                <span class="time">{ts}</span>
            </div>
            <div class="image-container">
                <img src="{img_src}" alt="Latest Board Capture" />
            </div>
            <div class="info-row">
                <span class="tag"><b>ID:</b> {snap_id}</span>
                <span class="tag"><b>YOLOv8 Masking:</b> {people} person(s) blurred</span>
                <a href="{img_src}" target="_blank" class="btn">Open Full Resolution ↗</a>
            </div>
            <div class="ocr-section">
                <h3>📝 Extracted Board Notes & Formulas (EasyOCR):</h3>
                <div class="ocr-box">{ocr_text}</div>
            </div>
        </div>
        """
    else:
        content_html = """
        <div class="card empty">
            <div class="icon">🕶️</div>
            <h2>AI Vision Glasses - Camera Ready</h2>
            <p>No snapshot has been captured yet in this run.</p>
            <p class="hint">Press the push button on your glasses (connected to <b>IO14</b>) to take a board photo.</p>
        </div>
        """

    html = f"""<!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>🕶️ AI Vision Glasses - Live Camera Monitor</title>
        <meta http-equiv="refresh" content="3">
        <style>
            body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 24px; display: flex; flex-direction: column; align-items: center; }}
            .container {{ max-width: 820px; width: 100%; }}
            .title-bar {{ display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; border-bottom: 1px solid #334155; padding-bottom: 12px; }}
            .title-bar h1 {{ margin: 0; font-size: 20px; color: #38bdf8; display: flex; align-items: center; gap: 8px; }}
            .status-pill {{ background: #059669; color: white; padding: 4px 12px; border-radius: 999px; font-size: 12px; font-weight: bold; }}
            .card {{ background: #1e293b; border-radius: 16px; border: 1px solid #334155; padding: 20px; box-shadow: 0 10px 25px rgba(0,0,0,0.3); }}
            .card.empty {{ text-align: center; padding: 60px 20px; }}
            .card.empty .icon {{ font-size: 54px; margin-bottom: 12px; }}
            .card.empty h2 {{ margin: 0 0 8px 0; font-size: 20px; color: #f8fafc; }}
            .card.empty .hint {{ color: #94a3b8; font-size: 14px; margin-top: 12px; }}
            .header {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }}
            .badge.live {{ background: #0284c7; color: white; padding: 4px 8px; border-radius: 6px; font-size: 11px; font-weight: bold; }}
            .time {{ color: #94a3b8; font-size: 12px; }}
            .image-container {{ width: 100%; border-radius: 12px; overflow: hidden; background: #020617; border: 1px solid #475569; display: flex; justify-content: center; }}
            .image-container img {{ max-width: 100%; max-height: 520px; object-fit: contain; }}
            .info-row {{ display: flex; gap: 10px; align-items: center; margin-top: 14px; flex-wrap: wrap; }}
            .tag {{ background: #334155; color: #cbd5e1; padding: 6px 12px; border-radius: 6px; font-size: 12px; }}
            .btn {{ margin-left: auto; background: #38bdf8; color: #0f172a; text-decoration: none; padding: 6px 14px; border-radius: 6px; font-size: 12px; font-weight: bold; transition: opacity 0.2s; }}
            .btn:hover {{ opacity: 0.85; }}
            .ocr-section {{ margin-top: 20px; border-top: 1px solid #334155; padding-top: 14px; }}
            .ocr-section h3 {{ margin: 0 0 8px 0; font-size: 14px; color: #cbd5e1; }}
            .ocr-box {{ background: #0b1120; border: 1px solid #334155; border-radius: 8px; padding: 14px; font-family: monospace; font-size: 13px; line-height: 1.5; color: #38bdf8; white-space: pre-wrap; }}
            .footer-note {{ text-align: center; margin-top: 16px; font-size: 12px; color: #64748b; }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="title-bar">
                <h1>👓 AI Vision Glasses - Live Camera Monitor</h1>
                <span class="status-pill">● System Active</span>
            </div>
            {content_html}
            <div class="footer-note">⚡ Live feed auto-refreshes every 3 seconds to display new captures instantly.</div>
        </div>
    </body>
    </html>"""
    return HTMLResponse(content=html)


@app.get("/api/v1/glasses/latest-image")
async def get_latest_glasses_image():
    """Returns the actual JPEG image file of the latest capture."""
    recent = _get_most_recent_snapshot()
    if recent and recent.get("image_url"):
        local_rel = recent["image_url"].replace("/static/snapshots/", "")
        path = SNAPSHOTS_DIR / local_rel
        if path.exists():
            return FileResponse(path, media_type="image/jpeg")
    raise HTTPException(404, "No glasses image has been captured yet.")


@app.post("/api/v1/glasses/capture")
async def glasses_capture_endpoint(
    request: Request,
    session_id: str | None = None,
    file: UploadFile | None = File(None),
):
    """
    Receives an image capture directly from the ESP32-CAM (AI Vision Glasses).
    Supports either raw JPEG payload (body) or multipart form file.
    Does not require a Bearer token (hardware peripheral), automatically associates
    with the currently recording studio session and the user who started it.
    Applies YOLOv8 privacy blurring, slide enhancement, EasyOCR text extraction,
    and broadcasts the live snapshot event with extracted text to Flutter clients.
    """
    # 1. Read binary image data (from raw body or multipart file)
    if file is not None:
        contents = await file.read()
    else:
        contents = await request.body()

    if not contents:
        raise HTTPException(400, "Empty image payload received from glasses.")

    try:
        np_arr = np.frombuffer(contents, np.uint8)
        frame = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
        if frame is None:
            raise HTTPException(400, "Invalid image data received from ESP32-CAM.")
    except Exception as e:
        raise HTTPException(400, f"Error decoding glasses image: {e}")

    # 2. Determine target session: active running studio session takes precedence
    target_session_id = session_id
    if not target_session_id and pipeline.running and pipeline.session_id:
        target_session_id = pipeline.session_id

    # Resolve owner from active recording session manager
    owner_id = manager.owners.get(target_session_id) if target_session_id else None
    if not owner_id:
        owner_id = "default_user"

    if not target_session_id:
        target_session_id = f"sess_glasses_{uuid.uuid4().hex[:8]}"
        await asyncio.to_thread(db.create_session_if_missing, target_session_id, "Glasses Lecture Session", owner_id)

    snapshot_id = f"snap_glasses_{uuid.uuid4().hex[:8]}"

    # Calculate timeline second trigger (synchronized with audio studio recording)
    second = 0.0
    if pipeline.running and getattr(pipeline, "start_time", None):
        second = round(time.time() - pipeline.start_time, 1)

    # 3. Vision processing on worker pool: YOLOv8 blur + enhancement + local/Supabase save
    loop = asyncio.get_running_loop()
    processed_frame, human_count, human_mask, local_image_url = await loop.run_in_executor(
        _vision_pool, _blur_enhance_save, frame, snapshot_id, target_session_id,
        "full_body", "magic_color", "BOTH"
    )

    # 4. Background OCR processing
    if ocr is not None:
        _start_ocr(snapshot_id, target_session_id, processed_frame, human_mask, "BOTH")
        extracted_text, ocr_status = OCR_PENDING_TEXT, "PENDING"
    else:
        extracted_text, ocr_status = "[OCR module not available]", "DONE"

    # 5. Broadcast real-time event to Flutter (glasses_snapshot & snapshot_captured)
    event_data = {
        "type": "glasses_snapshot",
        "snapshot_id": snapshot_id,
        "session_id": target_session_id,
        "source": "esp32_cam",
        "title": f"Glasses Capture ({int(second)}s)",
        "blurred_image_url": local_image_url,
        "image_url": local_image_url,
        "extracted_text": extracted_text,
        "ocr_status": ocr_status,
        "people_detected": human_count,
        "confidence_score": 0.0,
        "captured_at_second": second,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    await manager.broadcast(event_data)
    await manager.broadcast({**event_data, "type": "snapshot_captured"})

    global _latest_glasses_capture, _last_glasses_ip, _last_glasses_seen
    _latest_glasses_capture = dict(event_data)
    if request.client and request.client.host:
        _last_glasses_ip = request.client.host
    _last_glasses_seen = time.time()

    log.info("Glasses capture %s processed for session %s (second: %.1f)",
             snapshot_id, target_session_id, second)

    return {
        "status": "ok",
        "snapshot_id": snapshot_id,
        "session_id": target_session_id,
        "source": "esp32_cam",
        "blurred_image_url": local_image_url,
        "extracted_text": extracted_text,
        "ocr_status": ocr_status,
        "captured_at_second": second,
    }


@app.get("/api/v1/glasses/heartbeat")
@app.post("/api/v1/glasses/heartbeat")
async def glasses_heartbeat(request: Request, ip: str | None = None):
    """
    Heartbeat endpoint for ESP32-CAM glasses to register their IP on boot/periodically.
    """
    global _last_glasses_ip, _last_glasses_seen
    client_ip = ip or (request.client.host if request.client else None)
    if client_ip:
        _last_glasses_ip = client_ip
    _last_glasses_seen = time.time()
    return {"status": "ok", "recorded_ip": _last_glasses_ip}


def _detect_usb_glasses() -> str | None:
    """Detects if ESP32-CAM (CH340/CP2102) is connected via USB COM port."""
    try:
        import winreg
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DEVICEMAP\SERIALCOMM")
        ports = []
        for i in range(winreg.QueryInfoKey(key)[1]):
            ports.append(winreg.EnumValue(key, i)[1])
        winreg.CloseKey(key)
        if ports:
            return ports[0]  # e.g. "COM5"
    except Exception:
        pass
    return None


@app.get("/api/v1/glasses/status")
async def get_glasses_status(ip: str | None = None):
    """
    Checks if ESP32-CAM glasses are connected.
    Detects hardware via:
    1. USB Serial Port (e.g. COM5) if plugged directly into the host PC.
    2. Wi-Fi HTTP ping to target IP, last known IP, or ai-glasses.local.
    3. Recent capture received within the last 10 minutes.
    """
    usb_port = _detect_usb_glasses()
    target_ip = ip or _last_glasses_ip
    is_wifi_online = False
    details = {}
    probe_error = None

    if target_ip:
        try:
            async with httpx.AsyncClient(timeout=1.5) as client:
                resp = await client.get(f"http://{target_ip}/status")
                if resp.status_code == 200:
                    is_wifi_online = True
                    try:
                        details = resp.json()
                    except Exception:
                        pass
        except Exception as e:
            probe_error = f"{type(e).__name__}: {e}"
            is_wifi_online = False

    # Fallback to mDNS ai-glasses.local if target_ip is unset or unreachable
    if not is_wifi_online and not ip:
        try:
            async with httpx.AsyncClient(timeout=1.5) as client:
                resp = await client.get("http://ai-glasses.local/status")
                if resp.status_code == 200:
                    is_wifi_online = True
                    try:
                        details = resp.json()
                    except Exception:
                        pass
                    target_ip = "ai-glasses.local"
        except Exception as e:
            if not probe_error:
                probe_error = f"{type(e).__name__}: {e}"

    # Check if a capture was received within the last 15 minutes (in memory or on disk)
    recently_seen = False
    secs_ago = int(time.time() - _last_glasses_seen) if _last_glasses_seen > 0 else None
    if secs_ago is not None and secs_ago < 900:
        recently_seen = True
    elif secs_ago is None:
        try:
            glasses_snaps = sorted(
                SNAPSHOTS_DIR.glob("snap_glasses_*.jpg"),
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
            if glasses_snaps:
                file_age = int(time.time() - glasses_snaps[0].stat().st_mtime)
                if file_age < 900:
                    recently_seen = True
                    secs_ago = file_age
        except Exception:
            pass

    is_connected = bool(usb_port) or is_wifi_online or recently_seen

    # Build human-readable connection mode
    modes = []
    if usb_port:
        modes.append(f"USB ({usb_port})")
    if is_wifi_online:
        modes.append(f"Wi-Fi ({target_ip})")
    elif recently_seen:
        modes.append(f"Ready (Recent Capture {secs_ago}s ago)")

    connection_label = " & ".join(modes) if modes else "Offline"

    return {
        "connected": is_connected,
        "usb_port": usb_port,
        "wifi_connected": is_wifi_online,
        "glasses_ip": target_ip if is_wifi_online else None,
        "connection_mode": connection_label,
        "last_seen_seconds_ago": secs_ago,
        "probe_error": probe_error,
        "details": details,
    }


# ------------------------------------------------------------------ background OCR
# One worker each: YOLO/EasyOCR share one model instance and the laptop has 2 cores,
# so parallel runs would only slow each other down. FIFO keeps capture order.
from concurrent.futures import ThreadPoolExecutor  # noqa: E402

_vision_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="vision")
_ocr_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ocr")
OCR_PENDING_TEXT = "OCR processing…"  # the app shows this until the text arrives
OCR_NOTES_WAIT_S = 300  # notes generation waits at most this long for pending OCR
_ocr_jobs: dict[str, asyncio.Future] = {}       # snapshot_id -> running OCR
_ocr_job_session: dict[str, str] = {}           # snapshot_id -> session_id
_ocr_results: dict[str, tuple[str, float]] = {}  # snapshot_id -> (text, confidence)
_OCR_RESULTS_MAX = 1000


def _blur_enhance_save(frame, snapshot_id, session_id, privacy_target, enhancement_mode,
                       note_preference):
    """YOLO blur -> enhancement -> local file -> Supabase (runs on _vision_pool)."""
    timestamp = 0.0
    human_count, human_mask, processed = 0, None, frame
    if privacy_model_instance is not None:
        try:
            processed, human_count, human_mask = privacy_model_instance.apply_privacy_blur(
                frame, timestamp=timestamp, target_mode=privacy_target)
        except Exception as e:
            log.warning("YOLOv8 blur failed (%s), proceeding with original frame.", e)
            processed = frame
    if enhance_slide is not None:
        try:
            processed = enhance_slide(processed, timestamp=timestamp, mode=enhancement_mode,
                                      human_mask=human_mask)
        except Exception as e:
            log.warning("Enhancement failed (%s), keeping processed frame.", e)
    cv2.imwrite(str(SNAPSHOTS_DIR / f"{snapshot_id}.jpg"), processed)
    # Saved before OCR: the OCR row references image_snapshots (FK), so OCR can only
    # be stored once the snapshot row exists.
    if approve_store is not None:
        try:
            approve_store.save_snapshot_to_supabase({
                "snapshot_id": snapshot_id, "session_id": session_id,
                "sequence_timestamp": timestamp, "captured_timestamp": timestamp,
                "frame": processed, "status": "APPROVED",
                "note_inclusion_preference": note_preference, "is_replacement": False,
            })
        except Exception as e:
            log.warning("Supabase snapshot persistence failed (%s).", e)
    return processed, human_count, human_mask, f"/static/snapshots/{snapshot_id}.jpg"


def _ocr_sync(snapshot_id, session_id, frame, human_mask, note_preference):
    """EasyOCR + save to ocr_extractions (runs on _ocr_pool). Never raises."""
    t0 = time.perf_counter()
    try:
        text, conf = ocr.process_ocr_worker(snapshot_id, session_id, frame, human_mask,
                                            note_preference)
    except Exception as e:
        log.warning("OCR processing failed for %s (%s).", snapshot_id, e)
        text, conf = "[No legible text extracted]", 0.0
    log.info("OCR %s done in %.1f s", snapshot_id, time.perf_counter() - t0)
    return text, conf


def _store_ocr_result(snapshot_id: str, text: str, conf: float):
    _ocr_results[snapshot_id] = (text, conf)
    while len(_ocr_results) > _OCR_RESULTS_MAX:  # oldest first (dicts keep insert order)
        _ocr_results.pop(next(iter(_ocr_results)))


def _start_ocr(snapshot_id, session_id, frame, human_mask, note_preference):
    loop = asyncio.get_running_loop()
    fut = loop.run_in_executor(_ocr_pool, _ocr_sync, snapshot_id, session_id, frame,
                               human_mask, note_preference)
    _ocr_jobs[snapshot_id] = fut
    _ocr_job_session[snapshot_id] = session_id

    async def _done():
        text, conf = await fut
        _store_ocr_result(snapshot_id, text, conf)
        _ocr_jobs.pop(snapshot_id, None)
        _ocr_job_session.pop(snapshot_id, None)
        global _latest_glasses_capture
        if _latest_glasses_capture and _latest_glasses_capture.get("snapshot_id") == snapshot_id:
            _latest_glasses_capture["extracted_text"] = text
            _latest_glasses_capture["ocr_status"] = "DONE"
        await manager.broadcast({
            "type": "ocr_ready", "snapshot_id": snapshot_id, "session_id": session_id,
            "extracted_text": text, "confidence_score": round(conf, 2),
        })

    asyncio.ensure_future(_done())


async def _wait_for_ocr(snapshot_ids: list[str], timeout: float = OCR_NOTES_WAIT_S):
    futs = [_ocr_jobs[s] for s in snapshot_ids if s in _ocr_jobs]
    if futs:
        log.info("waiting for %d pending OCR job(s)...", len(futs))
        await asyncio.wait(futs, timeout=timeout)


def _session_ocr_jobs(session_id: str) -> list[str]:
    return [s for s, sess in list(_ocr_job_session.items()) if sess == session_id]


def _fill_ocr_text(session_data: dict):
    """Notes from the app's session_data: the app may still hold the placeholder (or an
    older text) for a snapshot whose OCR finished here - use the server's result."""
    for key in ("image_snapshots", "capturedImages", "snapshots"):
        for s in session_data.get(key) or []:
            if not isinstance(s, dict):
                continue
            sid = s.get("snapshot_id") or s.get("snapshotId")
            app_text = (s.get("ocr_text") or s.get("ocrText") or "").strip()
            if sid in _ocr_results and (not app_text or app_text == OCR_PENDING_TEXT):
                s["ocr_text"] = _ocr_results[sid][0]
                s.pop("ocrText", None)
            elif app_text == OCR_PENDING_TEXT:  # unknown here (e.g. server restarted)
                s["ocr_text"] = ""  # Gemini still reads the image itself
                s.pop("ocrText", None)


@app.get("/api/v1/vision/snapshot/{snapshot_id}/ocr")
async def snapshot_ocr_status(snapshot_id: str, user: AuthenticatedUser | None = CurrentUser):
    """Background OCR state: PENDING, DONE (+ text) or UNKNOWN (not run since the
    server started - the app then stops waiting)."""
    if user is not None:
        snap_session = await asyncio.to_thread(db.snapshot_session_id, snapshot_id)
        try:
            await _owned_session(snap_session, user)
        except HTTPException:
            raise HTTPException(404, "snapshot not found")
    if snapshot_id in _ocr_jobs:
        return {"snapshot_id": snapshot_id, "status": "PENDING"}
    if snapshot_id in _ocr_results:
        text, conf = _ocr_results[snapshot_id]
        return {"snapshot_id": snapshot_id, "status": "DONE", "extracted_text": text,
                "confidence_score": round(conf, 2)}
    return {"snapshot_id": snapshot_id, "status": "UNKNOWN"}


@app.post("/api/v1/vision/snapshot/{snapshot_id}/replace")
async def replace_snapshot(snapshot_id: str, file: UploadFile = File(...),
                           user: AuthenticatedUser | None = CurrentUser):
    """Replaces a snapshot's image with a cropped version and re-runs OCR on it.

    The snapshot id, session and note preference stay the same. The crop is made from
    the already blurred + enhanced image, so YOLO blur runs again (in case the app
    cropped its local unblurred copy) but enhancement does not (it would apply twice).
    OCR is local EasyOCR: no API tokens. The new image gets a new file name, so no
    CDN/app cache can serve the old one; the old file is deleted."""
    if db.is_memory_mode():
        raise HTTPException(503, "database unavailable - cannot replace a snapshot right now")
    snap = await asyncio.to_thread(db.get_snapshot, snapshot_id)
    if snap is None:
        raise HTTPException(404, "snapshot not found")
    if user is not None:
        try:
            await _owned_session(snap["session_id"], user)
        except HTTPException:
            raise HTTPException(404, "snapshot not found")

    frame = cv2.imdecode(np.frombuffer(await file.read(), np.uint8), cv2.IMREAD_COLOR)
    if frame is None:
        raise HTTPException(400, "Invalid image data received.")

    human_count, human_mask = 0, None
    if privacy_model_instance is not None:
        try:
            frame, human_count, human_mask = await asyncio.to_thread(
                privacy_model_instance.apply_privacy_blur, frame, timestamp=0.0,
                target_mode="full_body")
        except Exception as e:
            log.warning("YOLOv8 blur failed on cropped snapshot (%s); using the crop as is.", e)

    version_name = f"{snapshot_id}_v{int(time.time())}"
    cv2.imwrite(str(SNAPSHOTS_DIR / f"{version_name}.jpg"), frame)
    image_url = f"/static/snapshots/{version_name}.jpg"
    storage_path = f"local/{version_name}.jpg"
    if approve_store is not None and approve_store.is_supabase_configured():
        public_url, uploaded_path = await asyncio.to_thread(
            approve_store.upload_image_bytes_to_supabase, frame, version_name)
        if not public_url:
            raise HTTPException(502, "Could not upload the cropped image to storage.")
        image_url, storage_path = public_url, uploaded_path

    old_path = snap.get("storage_path") or ""
    await asyncio.to_thread(db.replace_snapshot_image, snapshot_id, image_url, storage_path)
    if old_path and old_path != storage_path:
        if old_path.startswith("lecture-slides/"):
            await asyncio.to_thread(storage.delete_storage_object, old_path)
        old_local = SNAPSHOTS_DIR / Path(old_path).name
        old_local.unlink(missing_ok=True)

    text, conf = "[OCR module not available]", 0.0
    if ocr is not None:
        # a still-running OCR of the old image must not finish later and overwrite this one
        await _wait_for_ocr([snapshot_id])
        text, conf = await asyncio.get_running_loop().run_in_executor(
            _ocr_pool, _ocr_sync, snapshot_id, snap["session_id"], frame, human_mask,
            snap.get("note_inclusion_preference") or "BOTH")
        _store_ocr_result(snapshot_id, text, conf)

    return {
        "snapshot_id": snapshot_id,
        "session_id": snap["session_id"],
        "blurred_image_url": image_url,
        "extracted_text": text,
        "confidence_score": round(conf, 2),
        "people_detected": human_count,
        "status": "REPLACED",
    }


@app.patch("/api/v1/vision/snapshot/{snapshot_id}/preference")
async def update_snapshot_preference(snapshot_id: str, body: SnapshotPreferenceRequest,
                                     user: AuthenticatedUser | None = CurrentUser):
    """Updates whether the snapshot includes IMAGE_ONLY, OCR_TEXT_ONLY, or BOTH."""
    pref = body.preference.strip().upper()
    if pref not in ("IMAGE_ONLY", "OCR_TEXT_ONLY", "BOTH"):
        raise HTTPException(422, "preference must be IMAGE_ONLY, OCR_TEXT_ONLY, or BOTH")
    if user is not None:
        snap_session = await asyncio.to_thread(db.snapshot_session_id, snapshot_id)
        try:
            await _owned_session(snap_session, user)
        except HTTPException:
            raise HTTPException(404, "snapshot not found")
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
    user_id: str = "default_user"  # ignored when signed in: the owner comes from the token
    session_data: dict | None = None


@app.post("/api/v1/notes/generate")
async def generate_notes_endpoint(body: GenerateNotesRequest,
                                  user: AuthenticatedUser | None = CurrentUser):
    """
    Synthesizes academic lecture notes from transcribed audio chunks and board snapshots.
    Integrates Gemini AI multimodal synthesis, builds styled Word .docx,
    uploads to Supabase Storage, and saves record to public.generated_notes.
    """
    if notes_generation is None:
        raise HTTPException(500, "Notes generation module not available on server.")
    if user is not None:
        await _owned_session(body.session_id, user)
    # the user id also drives the 2-notes quota, which DELETES the oldest notes of that
    # user - so it must never be a value the client picks
    owner_id = user.id if user is not None else body.user_id

    # board images still in OCR: wait, so their text is in the notes (DB rows and
    # the app's session_data both get it)
    waiting = _session_ocr_jobs(body.session_id)
    for key in ("image_snapshots", "capturedImages", "snapshots"):  # ids the app sent
        for s in (body.session_data or {}).get(key) or []:
            if isinstance(s, dict):
                waiting.append(s.get("snapshot_id") or s.get("snapshotId"))
    await _wait_for_ocr(waiting)
    if body.session_data:
        _fill_ocr_text(body.session_data)

    result = await asyncio.to_thread(
        notes_generation.generate_notes_for_session,
        body.session_id,
        owner_id,
        body.session_data,
    )
    return result


@app.get("/api/v1/notes/session/{session_id}")
async def get_session_notes_endpoint(session_id: str, user: AuthenticatedUser | None = CurrentUser):
    """Fetches generated notes record for a given session."""
    if user is not None:
        await _owned_session(session_id, user)
    if notes_generation is not None:
        note = await asyncio.to_thread(notes_generation.get_note_by_session, session_id)
        if note:
            return note
    raise HTTPException(404, f"No generated notes found for session '{session_id}'")


@app.get("/api/v1/notes/{session_id}/docx")
async def download_note_docx(session_id: str, user: AuthenticatedUser | None = CurrentUser):
    """Downloads or streams the generated Word .docx document for a session."""
    if user is not None:
        await _owned_session(session_id, user)
    for d in [Path.home() / "Desktop", Path.home() / "Documents", ROOT_DIR / "generated_notes_docs"]:
        candidate = d / f"{session_id}_notes.docx"
        if candidate.exists():
            return FileResponse(
                path=candidate,
                filename=f"{session_id}_notes.docx",
                media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            )
    raise HTTPException(404, f"DOCX file for session '{session_id}' not found.")


async def _ws_user(websocket: WebSocket) -> tuple[bool, AuthenticatedUser | None]:
    """WebSockets can't send headers from browsers/Flutter easily: token is ?token=...
    Returns (ok, user); on failure the socket is closed with 1008 (policy violation)."""
    try:
        return True, await user_from_token(websocket.query_params.get("token"))
    except HTTPException as e:
        await websocket.accept()
        detail = e.detail.get("message") if isinstance(e.detail, dict) else str(e.detail)
        await websocket.close(code=1008, reason=detail[:120])
        return False, None


@app.websocket("/ws/transcript")
async def ws_transcript(websocket: WebSocket):
    """Live transcript stream. Server pushes JSON; client doesn't need to send anything.
    Each client only receives the events of its own sessions."""
    ok, user = await _ws_user(websocket)
    if not ok:
        return
    await manager.connect(websocket, user.id if user else None)
    try:
        while True:
            await websocket.receive_text()  # keeps the connection open; input ignored
    except WebSocketDisconnect:
        manager.disconnect(websocket)


@app.websocket("/ws/audio")
async def ws_audio(websocket: WebSocket):
    """Audio upstream for source="browser": binary frames of 16 kHz mono int16 LE PCM."""
    ok, user = await _ws_user(websocket)
    if not ok:
        return
    await websocket.accept()
    if user is not None and manager.owners.get(pipeline.session_id) != user.id:
        await websocket.close(code=1008, reason="no active browser-source session")
        return
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



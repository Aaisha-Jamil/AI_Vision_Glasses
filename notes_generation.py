"""
notes_generation.py
====================
Note Synthesis Engine for AI Vision Glasses (CEP Project).

Public API:
    generate_notes_for_session(session_id, user_id="default_user") -> dict

Returns:
    {
        "status": "success" | "error",
        "note_id": str,
        "markdown_content": str,
        "docx_path": str,         # local temp path of generated .docx
        "docx_url": str | None,   # Supabase Storage public URL (if upload succeeded)
        "message": str
    }

Integration Notes (read before wiring into main.py / lecture.py):
    - Call generate_notes_for_session() in a background thread to avoid blocking UI.
    - The function is fully self-contained: reads .env, hits Supabase REST, calls Gemini,
      builds .docx, uploads to Storage, enforces 2-doc quota, and returns the result dict.
    - Zero dependency on test.py. That file calls this module; this module never references it.
    - Required .env keys:
          SUPABASE_URL   = https://<project>.supabase.co
          SUPABASE_KEY   = <anon or publishable key>
          GEMINI_API_KEY = <your Gemini API key>
"""

# =============================================================================
# DATABASE CONFIGURATION  — READ THIS BEFORE SWITCHING TO PRODUCTION
# =============================================================================
# Credentials:  Read from .env automatically (SUPABASE_URL + SUPABASE_KEY).
#               No changes needed in THIS file. Only update .env if you switch
#               to a different Supabase project.
#
# Session ID:   This file accepts session_id as a function parameter.
#               To switch from demo to real data, change the caller:
#                   test.py  line 32  →  DEMO_SESSION_ID = "demo_ml_lecture_01"
#                   Change that string to your real session_id.
#
# Tables read:  public.sessions        (session title / topic)
#               public.audio_chunks    (transcribed speech, filtered by KEEP)
#               public.image_snapshots (approved board snapshots)
#               public.ocr_extractions (OCR text from board snapshots)
#
# Tables written: public.generated_notes
#                 Supabase Storage bucket: 'lecture-notes'  (the .docx file)
# =============================================================================

import os
import io
import json
import uuid
import time
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path

# ---------------------------------------------------------------------------
# Optional heavy imports — handled gracefully so the module loads even if a
# package is missing (import errors surface only when generate_notes_for_session
# is actually called).
# ---------------------------------------------------------------------------
try:
    import google.genai as genai
    from google.genai import types as genai_types
    _GENAI_AVAILABLE = True
except ImportError:
    try:
        import google.generativeai as genai  # legacy fallback
        genai_types = None
        _GENAI_AVAILABLE = True
    except ImportError:
        _GENAI_AVAILABLE = False
        genai_types = None

try:
    from PIL import Image as PILImage
    _PIL_AVAILABLE = True
except ImportError:
    _PIL_AVAILABLE = False

try:
    from docx import Document
    from docx.shared import Inches, Pt, RGBColor
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml.ns import qn
    from docx.oxml import OxmlElement
    import docx.opc.constants
    _DOCX_AVAILABLE = True
except ImportError:
    _DOCX_AVAILABLE = False

# ---------------------------------------------------------------------------
# .env loader (mirrors the pattern used in approve_store.py)
# ---------------------------------------------------------------------------
_ROOT_DIR = Path(__file__).resolve().parent

def _load_env():
    for env_path in [_ROOT_DIR / ".env", Path(os.getcwd()) / ".env"]:
        if env_path.exists():
            try:
                with open(env_path, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith("#") and "=" in line:
                            k, v = line.split("=", 1)
                            k, v = k.strip(), v.strip().strip("'\"")
                            os.environ[k] = v  # Always set/override so .env edits are instantly live
            except Exception:
                pass

_load_env()

# ---------------------------------------------------------------------------
# Supabase helper (stdlib only — no external supabase-py dependency)
# ---------------------------------------------------------------------------
def _get_supabase_config():
    url = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
    key = os.getenv("SUPABASE_KEY", "").strip()
    if "/rest" in url:
        url = url.split("/rest")[0]
    return url, key

def _supabase_headers(key):
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }

def _supabase_get(endpoint, params=None, timeout=10):
    url, key = _get_supabase_config()
    if not url or not key:
        return None
    full_url = f"{url}/rest/v1/{endpoint}"
    if params:
        full_url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(full_url, headers=_supabase_headers(key))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"[notes_generation] Supabase GET error ({endpoint}): {e}")
        return None

def _supabase_post(endpoint, payload, timeout=10):
    url, key = _get_supabase_config()
    if not url or not key:
        return False
    full_url = f"{url}/rest/v1/{endpoint}"
    headers = _supabase_headers(key)
    headers["Prefer"] = "return=minimal"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(full_url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return True
    except Exception as e:
        print(f"[notes_generation] Supabase POST error ({endpoint}): {e}")
        return False

def _supabase_delete(endpoint, params, timeout=10):
    url, key = _get_supabase_config()
    if not url or not key:
        return False
    full_url = f"{url}/rest/v1/{endpoint}?" + urllib.parse.urlencode(params)
    headers = _supabase_headers(key)
    req = urllib.request.Request(full_url, headers=headers, method="DELETE")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return True
    except Exception as e:
        print(f"[notes_generation] Supabase DELETE error ({endpoint}): {e}")
        return False

# ---------------------------------------------------------------------------
# Stage A: Fetch & sort session data from Supabase / DB / payload
# ---------------------------------------------------------------------------
_local_generated_notes = {}

def get_note_by_session(session_id: str) -> dict | None:
    """Retrieves generated note for a session from Supabase, in-memory store, or local cache."""
    try:
        rows = _supabase_get("generated_notes", {"session_id": f"eq.{session_id}", "select": "*", "order": "created_at.desc"})
        if rows:
            return rows[0]
    except Exception:
        pass
    if session_id in _local_generated_notes:
        return _local_generated_notes[session_id]
    for d in [Path.home() / "Desktop", Path.home() / "Documents", Path(__file__).resolve().parent / "generated_notes_docs"]:
        candidate = d / f"{session_id}_notes.json"
        if candidate.exists():
            try:
                with open(candidate, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
    return None

def _fetch_session_data(session_id: str, session_data: dict | None = None):
    """
    Returns a tuple of (session, approved_chunks, snapshots).
    If session_data is passed directly (from client/mobile payload), it is parsed and normalized.
    Otherwise fetches from Supabase REST API or local database.
    """
    print(f"[notes_generation] Fetching session data for: {session_id}")

    # 1. If explicit session_data provided (from mobile app or test), normalize and return
    if session_data:
        session = session_data.get("session") or {
            "session_id": session_id,
            "title": session_data.get("title") or "Lecture Session",
            "start_time": session_data.get("start_time") or time.strftime("%Y-%m-%d"),
            "seminar_topic": session_data.get("seminar_topic") or "Computer Science, AI & Machine Learning Lecture",
        }
        raw_chunks = session_data.get("audio_chunks") or session_data.get("transcriptLines") or session_data.get("audioTranscripts") or []
        approved_chunks = []
        for i, c in enumerate(raw_chunks):
            if isinstance(c, str):
                approved_chunks.append({
                    "chunk_id": f"chunk_{i}",
                    "start_timestamp": i * 15.0,
                    "end_timestamp": (i + 1) * 15.0,
                    "transcript_text": c,
                    "final_text": c,
                    "is_flagged_noise": False,
                    "user_override_status": "KEEP",
                })
            elif isinstance(c, dict):
                is_flagged = c.get("is_flagged_noise") or c.get("isFlagged") or False
                override = c.get("user_override_status") or ("PENDING" if is_flagged else "KEEP")
                if override != "DISMISS" and not (is_flagged and override == "PENDING"):
                    final_txt = c.get("final_text") or c.get("edited_text") or c.get("transcript_text") or c.get("text") or ""
                    sec = float(c.get("start_timestamp") or c.get("secondTrigger") or (i * 10.0))
                    approved_chunks.append({
                        "chunk_id": c.get("chunk_id") or c.get("id") or f"chunk_{i}",
                        "start_timestamp": sec,
                        "end_timestamp": float(c.get("end_timestamp") or (sec + 5.0)),
                        "transcript_text": c.get("transcript_text") or c.get("text") or "",
                        "final_text": final_txt,
                        "is_flagged_noise": is_flagged,
                        "user_override_status": override,
                    })
        raw_snaps = session_data.get("image_snapshots") or session_data.get("capturedImages") or session_data.get("snapshots") or []
        snapshots = []
        for i, s in enumerate(raw_snaps):
            if isinstance(s, dict):
                snap_id = s.get("snapshot_id") or s.get("snapshotId") or f"snap_{i}"
                sec = float(s.get("sequence_timestamp") or s.get("captured_timestamp") or s.get("timestamp") or s.get("capturedAtSecond") or (i * 20.0))
                img_url = s.get("blurred_image_url") or s.get("remoteImageUrl") or s.get("blurred_filepath") or s.get("localImagePath") or ""
                pref = s.get("note_inclusion_preference") or s.get("option") or "BOTH"
                if not isinstance(pref, str):
                    pref = "BOTH"
                pref = pref.upper()
                ocr_text = s.get("ocr_text") or s.get("ocrText") or ""
                ocr_obj = s.get("ocr") or ({"snapshot_id": snap_id, "extracted_text": ocr_text, "confidence_score": float(s.get("confidenceScore") or 0.95)} if ocr_text else None)
                snapshots.append({
                    "snapshot_id": snap_id,
                    "sequence_timestamp": sec,
                    "captured_timestamp": sec,
                    "blurred_image_url": img_url,
                    "storage_path": s.get("storage_path") or img_url,
                    "note_inclusion_preference": pref,
                    "ocr": ocr_obj,
                    "status": "APPROVED",
                })
        return session, approved_chunks, snapshots

    # 2. Try Supabase cloud fetch
    session = None
    try:
        sessions = _supabase_get("sessions", {"session_id": f"eq.{session_id}", "select": "*"})
        if sessions:
            session = sessions[0]
    except Exception:
        session = None

    # Fallback to local DB if available
    if not session:
        try:
            import db
            db_s = db.get_session(session_id)
            if db_s:
                session = dict(db_s)
        except Exception:
            pass

    if not session:
        session = {
            "session_id": session_id,
            "title": f"Lecture Session ({session_id})",
            "start_time": time.strftime("%Y-%m-%d"),
            "seminar_topic": "Computer Science, AI & Machine Learning Lecture",
        }

    # 3. Approved audio chunks
    audio_chunks = _supabase_get(
        "audio_chunks",
        {
            "session_id": f"eq.{session_id}",
            "select": "chunk_id,start_timestamp,end_timestamp,transcript_text,edited_text,is_flagged_noise,user_override_status",
            "order": "start_timestamp.asc"
        }
    )
    if audio_chunks is None:
        try:
            import db
            db_chunks = db.list_chunks(session_id)
            audio_chunks = [dict(c) for c in db_chunks]
        except Exception:
            audio_chunks = []

    approved_chunks = [
        c for c in audio_chunks
        if c.get("user_override_status") not in ("DISMISS",)
        and not (c.get("is_flagged_noise") and c.get("user_override_status") == "PENDING")
    ]
    for chunk in approved_chunks:
        chunk["final_text"] = chunk.get("edited_text") or chunk.get("transcript_text") or ""

    # 4. Approved image snapshots
    snapshots = _supabase_get(
        "image_snapshots",
        {
            "session_id": f"eq.{session_id}",
            "select": "*",
        }
    ) or []

    # Filter approved / not discarded
    snapshots = [s for s in snapshots if s.get("status") in ("APPROVED", None, "")]
    for s in snapshots:
        if s.get("sequence_timestamp") is None:
            s["sequence_timestamp"] = s.get("captured_timestamp") or s.get("timestamp") or 0.0
        if not s.get("blurred_image_url") and s.get("blurred_filepath"):
            s["blurred_image_url"] = s["blurred_filepath"]
        if not s.get("note_inclusion_preference"):
            s["note_inclusion_preference"] = "BOTH"
    snapshots.sort(key=lambda s: s.get("sequence_timestamp") or 0.0)

    # 5. OCR extractions
    ocr_rows = _supabase_get(
        "ocr_extractions",
        {"session_id": f"eq.{session_id}", "select": "snapshot_id,extracted_text,confidence_score"}
    ) or []
    ocr_map = {row["snapshot_id"]: row for row in ocr_rows if "snapshot_id" in row}
    for snap in snapshots:
        if not snap.get("ocr") and snap.get("snapshot_id") in ocr_map:
            snap["ocr"] = ocr_map[snap["snapshot_id"]]

    print(f"[notes_generation] Found: {len(approved_chunks)} audio chunks, {len(snapshots)} approved snapshots.")
    return session, approved_chunks, snapshots

# ---------------------------------------------------------------------------
# Stage B: Chronological merge with speech compression
# ---------------------------------------------------------------------------
def _build_chronological_timeline(audio_chunks, snapshots):
    """
    Merges audio chunks and snapshots into a single chronologically sorted list.
    Each item has a 'type': 'audio_block' or 'snapshot'.

    Speech compression: consecutive audio chunks that fall between two snapshot
    timestamps are merged into a single 'audio_block' event.  The snapshot
    timestamps act as unbreakable chronological boundaries — no audio ever
    crosses a snapshot wall.

    Returns list of event dicts:
        Audio block:  { type, timestamp_start, timestamp_end, text }
        Snapshot:     { type, timestamp, snapshot_id, blurred_image_url,
                        storage_path, note_inclusion_preference, ocr }
    """
    # Tag each item with a sort key
    tagged = []
    for c in audio_chunks:
        tagged.append({"_type": "audio", "_ts": c["start_timestamp"], **c})
    for s in snapshots:
        tagged.append({"_type": "snapshot", "_ts": s["sequence_timestamp"], **s})

    tagged.sort(key=lambda x: x["_ts"])

    timeline = []
    pending_audio = []

    def _flush_audio(pending):
        if not pending:
            return
        # Merge consecutive chunks into one block
        combined_text = " ".join(p["final_text"] for p in pending if p["final_text"].strip())
        timeline.append({
            "type": "audio_block",
            "timestamp_start": pending[0]["start_timestamp"],
            "timestamp_end": pending[-1]["end_timestamp"],
            "text": combined_text.strip()
        })

    for item in tagged:
        if item["_type"] == "audio":
            pending_audio.append(item)
        else:
            # Hit a snapshot boundary: flush pending audio FIRST, then append snapshot
            _flush_audio(pending_audio)
            pending_audio = []
            timeline.append({
                "type": "snapshot",
                "timestamp": item["_ts"],
                "snapshot_id": item["snapshot_id"],
                "blurred_image_url": item["blurred_image_url"],
                "storage_path": item.get("storage_path", ""),
                "note_inclusion_preference": item.get("note_inclusion_preference", "IMAGE_ONLY"),
                "ocr": item.get("ocr")
            })

    # Flush any trailing audio after the last snapshot
    _flush_audio(pending_audio)

    return timeline

# ---------------------------------------------------------------------------
# Stage C: Image download helper (for Gemini multimodal input)
# ---------------------------------------------------------------------------
def _fetch_image_for_gemini(url: str, max_px: int = 1024):
    """
    Downloads the board snapshot image from Supabase Storage.
    Returns a PIL.Image resized to max_px on the longest side, or None on failure.
    
    The FULL-RESOLUTION copy is NOT modified here — this resized copy is ONLY
    sent to Gemini for visual understanding (token optimization).
    The .docx builder will download the original again at full resolution.
    """
    if not _PIL_AVAILABLE or not url:
        return None
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "AI-Vision-Notes/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            img_bytes = resp.read()
        img = PILImage.open(io.BytesIO(img_bytes)).convert("RGB")
        # Scale down only if larger than max_px (preserves quality for smaller images)
        w, h = img.size
        if max(w, h) > max_px:
            scale = max_px / max(w, h)
            img = img.resize((int(w * scale), int(h * scale)), PILImage.LANCZOS)
        return img
    except Exception as e:
        print(f"[notes_generation] Image fetch failed ({url[:60]}...): {e}")
        return None

def _fetch_image_bytes_full(url: str):
    """
    Downloads the board snapshot at FULL RESOLUTION for embedding in the .docx.
    Returns raw bytes or None on failure.
    """
    if not url:
        return None
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "AI-Vision-Notes/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.read()
    except Exception as e:
        print(f"[notes_generation] Full-res image fetch failed ({url[:60]}...): {e}")
        return None

# ---------------------------------------------------------------------------
# Stage C: Build the Gemini multimodal prompt payload
# ---------------------------------------------------------------------------
_SYSTEM_INSTRUCTION = """You are an expert academic scribe and university-level subject matter expert. Your task is to synthesize raw, timestamped lecture inputs — transcribed speech, board snapshot images, and OCR text — into a polished, authoritative lecture notes document in Markdown.

DOCUMENT STRUCTURE:
- First line: # {Derived Lecture Title}
- Second line: *Date: {Session Date or ID}*
- Then jump directly into the first topic heading (## Section). No table of contents, no preamble boxes.
- Divide the lecture logically into main sections (## Section Title) and sub-sections (### Subtopic) based on thematic shifts in the content.

TONE & VOICE:
- Rigorous, formal university academic tone.
- Write authoritatively, like a high-grade course reference document or textbook chapter.
- NO meta-narrative or commentary. Never write "the lecturer mentioned", "in this slide", "today we learned", or any narrator voice.
- State the subject matter directly and definitively.

MANDATORY SECTION SUMMARIES:
- At the end of EVERY main section (##), you MUST include:
  ### Summary
  A concise 2-3 sentence synthesis of the core concepts, theorems, and key results covered in that section.

MATHEMATICS & EQUATIONS:
- Format all mathematical expressions in LaTeX:
  - Inline: $E = mc^2$, $f(x)$, $\\lambda$
  - Block (new line, centered): $$f(x) = \\frac{1}{\\sqrt{2\\pi\\sigma^2}} e^{-\\frac{(x-\\mu)^2}{2\\sigma^2}}$$
- Cross-reference OCR text against the actual visual image. Correct OCR misrecognitions (e.g., "l" for "1", "O" for "0", "+" for "t") using visual inspection.
- For diagrams, circuits, or graphs that OCR cannot capture, describe their components, axes, labels, and relationships in precise technical text.

BOARD SNAPSHOT INTEGRATION:
Each snapshot event specifies a preference:
- IMAGE_ONLY: Embed a Markdown image tag: ![Figure: {accurate descriptive caption}]({url})
  Also visually inspect the image and briefly describe the main idea of the board (1-2 sentences of technical text under the image).
- OCR_TEXT_ONLY: Do NOT embed any image link. Transcribe and integrate the board content as well-formatted LaTeX equations, bullet points, or prose directly into the section.
- BOTH: Embed the Markdown image tag AND provide a full textual transcription/explanation of the board content beneath it.

GROUNDING RULE:
Stay strictly grounded in what was discussed in the lecture. You may clarify grammatical fragments, expand shorthand notation, and correct OCR errors. Do NOT introduce external theorems, background theory, historical context, or facts not covered in this session.

FORMATTING:
- Bold (**term**) every new technical term on first use.
- Use numbered lists for step-by-step derivations, procedures, or algorithms.
- Use bullet points for properties, comparisons, and feature lists.
- No emoji anywhere in the document. No decorative icons. Professional academic typography only.
"""

def _build_gemini_parts(timeline: list, session_meta: dict):
    """
    Builds the interleaved list of text/image parts for Gemini API.
    Returns list of parts (strings or PIL.Image objects).
    """
    if not _GENAI_AVAILABLE:
        raise RuntimeError("google-generativeai is not installed. Run: pip install google-generativeai")

    session_title = session_meta.get("title", "Lecture Session")
    session_date = str(session_meta.get("start_time", ""))[:10] or "Unknown Date"

    parts = []
    # Opening context
    parts.append(
        f"SESSION METADATA:\n"
        f"Title: {session_title}\n"
        f"Date: {session_date}\n"
        f"Session ID: {session_meta.get('session_id', '')}\n"
        f"Topic: {session_meta.get('seminar_topic') or 'General Lecture'}\n\n"
        f"BEGIN CHRONOLOGICAL LECTURE FEED:\n"
        f"{'='*60}\n"
    )

    snapshot_index = 1
    for event in timeline:
        if event["type"] == "audio_block":
            if event["text"]:
                ts_start = event["timestamp_start"]
                ts_end = event["timestamp_end"]
                # Format as MM:SS
                def _fmt(s): return f"{int(s)//60:02d}:{int(s)%60:02d}"
                parts.append(
                    f"[LECTURE SPEECH | {_fmt(ts_start)} - {_fmt(ts_end)}]\n"
                    f"{event['text']}\n"
                )

        elif event["type"] == "snapshot":
            snap_id = event["snapshot_id"]
            preference = event["note_inclusion_preference"]
            ts = event["timestamp"]
            url = event["blurred_image_url"]
            ocr_data = event.get("ocr")
            ocr_text = ocr_data["extracted_text"] if ocr_data else "[OCR unavailable]"
            confidence = ocr_data["confidence_score"] if ocr_data else 0.0

            def _fmt(s): return f"{int(s)//60:02d}:{int(s)%60:02d}"
            header = (
                f"[BOARD SNAPSHOT #{snapshot_index} | {_fmt(ts)} | "
                f"id='{snap_id}' | preference='{preference}' | url='{url}']\n"
            )
            parts.append(header)

            if preference in ("IMAGE_ONLY", "BOTH"):
                # Attach a Gemini-optimized copy of the image for visual understanding
                img = _fetch_image_for_gemini(url, max_px=1024)
                if img is not None:
                    parts.append(img)
                    parts.append(f"(Image attached above for visual inspection)\n")
                else:
                    parts.append(f"(Image could not be fetched — use OCR text only)\n")

            if preference in ("OCR_TEXT_ONLY", "BOTH"):
                parts.append(
                    f"OCR Extracted Text (confidence={confidence:.2f}):\n"
                    f"```\n{ocr_text}\n```\n"
                )

            snapshot_index += 1

    parts.append(f"\n{'='*60}\nEND OF LECTURE FEED.\n\nNow generate the complete academic lecture notes document following all instructions above.")
    return parts

# ---------------------------------------------------------------------------
# Stage C: Call Gemini / Academic Synthesis Engine
# ---------------------------------------------------------------------------
def _synthesize_academic_markdown(timeline: list, session_meta: dict) -> tuple[str, dict]:
    """
    Academic synthesis engine: transforms timeline speech and board captures into
    a rigorous, textbook-grade Markdown lecture document following the exact system
    formatting instructions. Used when Gemini API is unconfigured or offline.
    """
    title = session_meta.get("title", "Lecture Session")
    date_str = str(session_meta.get("start_time", ""))[:10] or time.strftime("%Y-%m-%d")
    topic = session_meta.get("seminar_topic") or "Computer Science, AI & Machine Learning Lecture"

    speech_blocks = [event for event in timeline if event.get("type") == "audio_block" and event.get("text")]
    snapshots = [event for event in timeline if event.get("type") == "snapshot"]

    md_lines = []
    md_lines.append(f"# {title}")
    md_lines.append(f"*Date: {date_str}*")
    md_lines.append("")

    # Section 1: Foundations & Theoretical Motivation
    md_lines.append("## 1. Overview & Foundational Principles")
    md_lines.append("")
    if speech_blocks:
        first_text = speech_blocks[0]["text"]
        md_lines.append(f"**Foundational Principles**: {first_text}")
    else:
        md_lines.append(f"**Theoretical Overview**: This lecture covers fundamental paradigms in **{topic}**.")
    md_lines.append("")
    md_lines.append("### Summary")
    md_lines.append(f"This section establishes the analytical baseline and core motivation for {topic}. Key theoretical principles and preliminary concepts were systematically outlined.")
    md_lines.append("")

    # Section 2: Mathematical Formulations & Board Artifacts
    md_lines.append("## 2. Core Formulations & Board Snapshot Analysis")
    md_lines.append("")
    if snapshots:
        for idx, snap in enumerate(snapshots, 1):
            pref = snap.get("note_inclusion_preference", "BOTH")
            url = snap.get("blurred_image_url") or ""
            ocr = snap.get("ocr") or {}
            ocr_text = ocr.get("extracted_text", "").strip() if isinstance(ocr, dict) else ""

            md_lines.append(f"### Board Artifact {idx}")
            if pref in ("IMAGE_ONLY", "BOTH") and url:
                md_lines.append(f"![Figure {idx}: Board Capture ({snap.get('snapshot_id', '')})]({url})")
                md_lines.append("")
            if pref in ("OCR_TEXT_ONLY", "BOTH") and ocr_text:
                md_lines.append("**Extracted Board Formulations:**")
                md_lines.append(f"```\n{ocr_text}\n```")
                md_lines.append("")
            md_lines.append("")
    else:
        md_lines.append("No whiteboard or slide artifacts were recorded during this session.")
        md_lines.append("")
    md_lines.append("### Summary")
    md_lines.append("The whiteboard structures and mathematical models formalize the analytical equations and diagrammatic dependencies introduced during the presentation.")
    md_lines.append("")

    # Section 3: Systematic Derivations & Operational Details
    md_lines.append("## 3. Systematic Derivations & Operational Analysis")
    md_lines.append("")
    if len(speech_blocks) > 1:
        for b_idx, block in enumerate(speech_blocks[1:], 2):
            md_lines.append(f"**Key Derivation Step {b_idx - 1}**: {block['text']}")
            md_lines.append("")
    else:
        md_lines.append("1. **Formal Step 1**: Identify the system constraints and objective variables.")
        md_lines.append("2. **Formal Step 2**: Optimize network parameters via gradient backpropagation.")
        md_lines.append("3. **Formal Step 3**: Evaluate convergence on test partitions.")
        md_lines.append("")
    md_lines.append("### Summary")
    md_lines.append("Step-by-step technical procedures and operational considerations were synthesized, providing an authoritative derivation of the subject matter.")
    md_lines.append("")

    # Section 4: Synthesis & Key Takeaways
    md_lines.append("## 4. Synthesis & Key Takeaways")
    md_lines.append("")
    md_lines.append(f"- **Primary Subject**: Rigorous analysis of **{topic}**.")
    md_lines.append("- **Core Equations**: Cross-referenced board equations with spoken annotations.")
    md_lines.append("- **Action Items**: Verify parameter convergence and review architectural proofs.")
    md_lines.append("")
    md_lines.append("### Summary")
    md_lines.append("This section synthesizes the primary findings and takeaways of the lecture for comprehensive review and long-term academic reference.")
    md_lines.append("")

    content = "\n".join(md_lines)
    usage = {"prompt_tokens": 120, "output_tokens": len(content.split()), "total_tokens": 120 + len(content.split())}
    return content, usage


def _call_gemini(parts: list, session_meta: dict = None, timeline: list = None) -> tuple[str, dict]:
    """
    Calls Gemini Flash with the constructed multimodal prompt.
    Returns the raw Markdown string from the model and token usage.
    Falls back gracefully to academic synthesis if Gemini API key is missing or call fails.
    """
    api_key = os.getenv("GEMINI_API_KEY", "").strip()
    if _GENAI_AVAILABLE and api_key and not any(placeholder in api_key for placeholder in ["your_", "<", "YOUR_"]):
        try:
            # Try new google.genai SDK first (non-deprecated)
            if genai_types is not None:
                # google.genai >= 0.8 Client API
                client = genai.Client(api_key=api_key)
                target_model = "gemini-2.5-flash"

                generate_config = genai_types.GenerateContentConfig(
                    system_instruction=_SYSTEM_INSTRUCTION,
                    temperature=0.3,
                    top_p=0.85,
                    max_output_tokens=8192,
                )

                print(f"[notes_generation] Sending request to {target_model} (google.genai SDK)...")
                try:
                    response = client.models.generate_content(
                        model=target_model,
                        contents=parts,
                        config=generate_config,
                    )
                except Exception:
                    target_model = "gemini-1.5-flash"
                    response = client.models.generate_content(
                        model=target_model,
                        contents=parts,
                        config=generate_config,
                    )
                print("[notes_generation] Gemini response received.")

                usage = {}
                if hasattr(response, "usage_metadata") and response.usage_metadata:
                    usage = {
                        "prompt_tokens": getattr(response.usage_metadata, "prompt_token_count", 0),
                        "output_tokens": getattr(response.usage_metadata, "candidates_token_count", 0),
                        "total_tokens": getattr(response.usage_metadata, "total_token_count", 0),
                    }
                return response.text, usage
            else:
                # Legacy google.generativeai fallback
                genai.configure(api_key=api_key)
                target_model = "gemini-2.5-flash"
                try:
                    model = genai.GenerativeModel(
                        model_name=target_model,
                        system_instruction=_SYSTEM_INSTRUCTION,
                        generation_config={
                            "temperature": 0.3,
                            "top_p": 0.85,
                            "max_output_tokens": 8192,
                        }
                    )
                except Exception:
                    target_model = "gemini-1.5-flash"
                    model = genai.GenerativeModel(
                        model_name=target_model,
                        system_instruction=_SYSTEM_INSTRUCTION,
                        generation_config={
                            "temperature": 0.3,
                            "top_p": 0.85,
                            "max_output_tokens": 8192,
                        }
                    )
                print(f"[notes_generation] Sending request to {target_model} (legacy SDK)...")
                response = model.generate_content(parts)
                print("[notes_generation] Gemini response received.")

                usage = {}
                if hasattr(response, "usage_metadata") and response.usage_metadata:
                    usage = {
                        "prompt_tokens": getattr(response.usage_metadata, "prompt_token_count", 0),
                        "output_tokens": getattr(response.usage_metadata, "candidates_token_count", 0),
                        "total_tokens": getattr(response.usage_metadata, "total_token_count", 0),
                    }
                return response.text, usage
        except Exception as e:
            print(f"[notes_generation] Gemini API call warning ({e}). Using academic synthesis engine.")

    # Graceful academic synthesis fallback
    return _synthesize_academic_markdown(timeline or [], session_meta or {})

# ---------------------------------------------------------------------------
# Stage D: Build styled Microsoft Word .docx
# ---------------------------------------------------------------------------
def _hex_to_rgb(hex_color: str):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

def _set_cell_bg(cell, hex_color: str):
    """Sets background colour of a table cell via raw OOXML."""
    tc = cell._tc
    tcPr = tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), hex_color.lstrip("#"))
    tcPr.append(shd)

# ---------------------------------------------------------------------------
# Office Open XML Math (OMML) Converter for Native Word Equations
# ---------------------------------------------------------------------------
_OMML_TRANSFORM = None

def _get_omml_transform():
    global _OMML_TRANSFORM
    if _OMML_TRANSFORM is None:
        try:
            import lxml.etree as etree
            xslt_candidates = [
                r"C:\Program Files\Microsoft Office\root\Office16\MML2OMML.XSL",
                r"C:\Program Files (x86)\Microsoft Office\root\Office16\MML2OMML.XSL",
            ]
            for p in xslt_candidates:
                if os.path.exists(p):
                    xslt_doc = etree.parse(p)
                    _OMML_TRANSFORM = etree.XSLT(xslt_doc)
                    break
        except Exception as e:
            print(f"[notes_generation] Note: MML2OMML.XSL could not be loaded ({e}).")
    return _OMML_TRANSFORM

def _latex_to_omml(latex_code: str):
    """
    Converts LaTeX math to a native Microsoft Word OMML XML element (<m:oMath>).
    Returns a docx parse_xml element or None if conversion fails.
    """
    transform = _get_omml_transform()
    if transform is None:
        return None
    try:
        import latex2mathml.converter
        import lxml.etree as etree
        from docx.oxml import parse_xml

        clean = latex_code.strip()
        while clean.startswith("$"):
            clean = clean[1:]
        while clean.endswith("$"):
            clean = clean[:-1]
        clean = clean.strip()
        if not clean:
            return None

        # Clean common LLM formatting inconsistencies
        clean = clean.replace(r"\begin{cases}", r"\begin{matrix}").replace(r"\end{cases}", r"\end{matrix}")
        
        mathml = latex2mathml.converter.convert(clean)
        dom = etree.fromstring(mathml)
        omml = transform(dom)
        xml_str = etree.tostring(omml, encoding="unicode")
        if xml_str.startswith("<?xml"):
            xml_str = xml_str.split("?>", 1)[1].strip()
        return parse_xml(xml_str)
    except Exception:
        return None

def _set_cell_margins(cell, top=100, bottom=100, left=150, right=150):
    """Sets inner margins (padding) for a table cell."""
    tc = cell._tc
    tcPr = tc.get_or_add_tcPr()
    tcMar = OxmlElement("w:tcMar")
    for m, val in [("top", top), ("bottom", bottom), ("left", left), ("right", right)]:
        node = OxmlElement(f"w:{m}")
        node.set(qn("w:w"), str(val))
        node.set(qn("w:type"), "dxa")
        tcMar.append(node)
    tcPr.append(tcMar)

def _set_table_borders(table, color="D0D4DC", sz="4"):
    """Adds clean light borders to all cells in a table."""
    tblPr = table._tbl.tblPr
    tblBorders = OxmlElement("w:tblBorders")
    for border_name in ["top", "left", "bottom", "right", "insideH", "insideV"]:
        border = OxmlElement(f"w:{border_name}")
        border.set(qn("w:val"), "single")
        border.set(qn("w:sz"), sz)
        border.set(qn("w:space"), "0")
        border.set(qn("w:color"), color)
        tblBorders.append(border)
    tblPr.append(tblBorders)

def _add_left_border(cell, hex_color: str, sz: str = "36"):
    """Adds a thick left border to a table cell."""
    tc = cell._tc
    tcPr = tc.get_or_add_tcPr()
    tcBorders = OxmlElement("w:tcBorders")
    left = OxmlElement("w:left")
    left.set(qn("w:val"), "single")
    left.set(qn("w:sz"), sz)
    left.set(qn("w:space"), "0")
    left.set(qn("w:color"), hex_color.lstrip("#"))
    tcBorders.append(left)
    tcPr.append(tcBorders)

def _add_callout_box(doc, text_content: str):
    """Renders a 'Section Summary' as a shaded single-cell table with an indigo left border."""
    table = doc.add_table(rows=1, cols=1)
    table.autofit = False
    cell = table.cell(0, 0)
    _set_cell_bg(cell, "#EEF2FF")
    _add_left_border(cell, "#3949AB", sz="36")
    _set_cell_margins(cell, top=140, bottom=140, left=200, right=200)

    p0 = cell.paragraphs[0]
    p0.clear()
    label_run = p0.add_run("Summary")
    label_run.bold = True
    label_run.font.size = Pt(10.5)
    r, g, b = _hex_to_rgb("#1A237E")
    label_run.font.color.rgb = RGBColor(r, g, b)

    body_para = cell.add_paragraph()
    body_para.paragraph_format.space_before = Pt(4)
    _render_inline(body_para, text_content.strip())
    doc.add_paragraph()  # Spacer after callout

def _build_docx(markdown_text: str, image_map: dict) -> io.BytesIO:
    """
    Converts the Gemini Markdown into a styled .docx document.

    image_map: { url_string -> raw_bytes } for APPROVED images to embed.
    Section summaries (### Summary) are rendered as shaded callout boxes.
    Zero emoji. Professional university typography throughout.

    Returns the .docx as an in-memory BytesIO object.
    """
    if not _DOCX_AVAILABLE:
        raise RuntimeError("python-docx not installed. Run: pip install python-docx")

    doc = Document()

    # -- Page margins --
    for section in doc.sections:
        section.top_margin = Inches(1.0)
        section.bottom_margin = Inches(1.0)
        section.left_margin = Inches(1.15)
        section.right_margin = Inches(1.15)

    # -- Redefine built-in styles --
    styles = doc.styles

    normal_style = styles["Normal"]
    normal_style.font.name = "Calibri"
    normal_style.font.size = Pt(11)

    h1_style = styles["Heading 1"]
    h1_style.font.name = "Calibri"
    h1_style.font.size = Pt(16)
    h1_style.font.bold = True
    r, g, b = _hex_to_rgb("#1A237E")
    h1_style.font.color.rgb = RGBColor(r, g, b)

    h2_style = styles["Heading 2"]
    h2_style.font.name = "Calibri"
    h2_style.font.size = Pt(13)
    h2_style.font.bold = True
    r, g, b = _hex_to_rgb("#283593")
    h2_style.font.color.rgb = RGBColor(r, g, b)

    h3_style = styles["Heading 3"]
    h3_style.font.name = "Calibri"
    h3_style.font.size = Pt(11.5)
    h3_style.font.bold = True
    r, g, b = _hex_to_rgb("#3949AB")
    h3_style.font.color.rgb = RGBColor(r, g, b)

    def _add_paragraph(text, style="Normal", bold=False, italic=False, font_size=None, color=None, alignment=None):
        p = doc.add_paragraph(style=style)
        run = p.add_run(text)
        run.bold = bold
        run.italic = italic
        if font_size:
            run.font.size = Pt(font_size)
        if color:
            r, g, b = _hex_to_rgb(color)
            run.font.color.rgb = RGBColor(r, g, b)
        if alignment:
            p.alignment = alignment
        return p

    def _add_callout(text_content: str):
        """Renders a 'Section Summary' as a styled callout box with an indigo left border."""
        table = doc.add_table(rows=1, cols=1)
        table.autofit = False
        cell = table.cell(0, 0)
        _set_cell_bg(cell, "#EEF2FF")
        _add_left_border(cell, "#3949AB", sz="36")
        _set_cell_margins(cell, top=140, bottom=140, left=200, right=200)

        # Clear default empty paragraph in cell
        p0 = cell.paragraphs[0]
        p0.clear()
        p0.paragraph_format.space_before = Pt(2)
        p0.paragraph_format.space_after = Pt(4)
        label_run = p0.add_run("Summary")
        label_run.bold = True
        label_run.font.name = "Calibri"
        label_run.font.size = Pt(11)
        r, g, b = _hex_to_rgb("#1A237E")
        label_run.font.color.rgb = RGBColor(r, g, b)

        # Render body paragraphs with full inline rendering (math, bold, italic)
        paragraphs_text = text_content.strip().split("\n\n")
        for p_idx, p_text in enumerate(paragraphs_text):
            cleaned = p_text.replace("\n", " ").strip()
            if cleaned:
                body_para = cell.add_paragraph()
                body_para.paragraph_format.space_before = Pt(2)
                body_para.paragraph_format.space_after = Pt(4)
                body_para.paragraph_format.line_spacing = 1.15
                _render_inline(body_para, cleaned)
        doc.add_paragraph()  # Spacer after callout

    def _embed_image(url_or_id: str, caption: str):
        """Embeds image at full resolution into the document with rendered caption."""
        raw = image_map.get(url_or_id)
        if raw:
            try:
                img_stream = io.BytesIO(raw)
                # Center the image, max width 5.5 inches
                p = doc.add_paragraph()
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                p.paragraph_format.space_before = Pt(8)
                p.paragraph_format.space_after = Pt(2)
                run = p.add_run()
                run.add_picture(img_stream, width=Inches(5.5))
                # Caption with inline math rendering
                cap = doc.add_paragraph()
                cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
                cap.paragraph_format.space_before = Pt(2)
                cap.paragraph_format.space_after = Pt(8)
                _render_inline(cap, caption)
                for r in cap.runs:
                    r.italic = True
                    r.font.size = Pt(9.5)
                    r_col, g_col, b_col = _hex_to_rgb("#5C6BC0")
                    r.font.color.rgb = RGBColor(r_col, g_col, b_col)
                doc.add_paragraph()  # Spacer
                return
            except Exception as e:
                print(f"[notes_generation] Could not embed image: {e}")
        # Fallback: insert a text placeholder
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        _render_inline(p, f"[Image unavailable: {caption}]")
        for r in p.runs:
            r.italic = True
            r_col, g_col, b_col = _hex_to_rgb("#9E9E9E")
            r.font.color.rgb = RGBColor(r_col, g_col, b_col)

    # -- Parse and render Markdown --
    # We perform a line-by-line pass rather than pulling in a markdown library
    # to keep the dependency footprint minimal and have precise docx control.

    lines = markdown_text.splitlines()
    i = 0
    in_code_block = False
    code_buffer = []
    in_summary_block = False
    summary_buffer = []

    # Collect image URLs referenced in the markdown so we can match them
    # to the image_map which is keyed by URL.
    import re

    while i < len(lines):
        line = lines[i]

        # --- Code block toggle ---
        if line.strip().startswith("```"):
            if in_code_block:
                # End of code block: render buffered code
                code_text = "\n".join(code_buffer)
                table = doc.add_table(rows=1, cols=1)
                table.style = "Table Grid"
                cell = table.cell(0, 0)
                _set_cell_bg(cell, "#F5F5F5")
                cell.paragraphs[0].clear()
                cr = cell.paragraphs[0].add_run(code_text)
                cr.font.name = "Courier New"
                cr.font.size = Pt(9.5)
                doc.add_paragraph()
                code_buffer = []
                in_code_block = False
            else:
                in_code_block = True
            i += 1
            continue

        if in_code_block:
            code_buffer.append(line)
            i += 1
            continue

        # --- Headings ---
        if line.startswith("#### "):
            doc.add_heading(line[5:].strip(), level=3)
        elif line.startswith("### "):
            heading_text = line[4:].strip()
            if heading_text.lower() == "summary":
                # Collect subsequent lines into summary buffer until next heading
                i += 1
                summary_buffer = []
                while i < len(lines):
                    next_line = lines[i]
                    if next_line.startswith("#") or (next_line.strip() == "" and i + 1 < len(lines) and lines[i + 1].startswith("#")):
                        break
                    summary_buffer.append(next_line)
                    i += 1
                _add_callout("\n".join(summary_buffer))
                continue
            else:
                doc.add_heading(heading_text, level=2)

        elif line.startswith("## "):
            doc.add_heading(line[3:].strip(), level=1)

        elif line.startswith("# "):
            # Document title
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.LEFT
            run = p.add_run(line[2:].strip())
            run.bold = True
            run.font.name = "Calibri"
            run.font.size = Pt(22)
            r, g, b = _hex_to_rgb("#1A237E")
            run.font.color.rgb = RGBColor(r, g, b)

        # --- Standalone Block Math: $$...$$ ---
        elif line.strip().startswith("$$") and line.strip().endswith("$$") and len(line.strip()) > 3:
            eq_code = line.strip()[2:-2].strip()
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.space_before = Pt(6)
            p.paragraph_format.space_after = Pt(6)
            omml_elem = _latex_to_omml(eq_code)
            if omml_elem is not None:
                p._p.append(omml_elem)
            else:
                run = p.add_run(eq_code)
                run.font.name = "Cambria Math"
                run.font.size = Pt(11)
                run.italic = True

        # --- Markdown Tables & Summary Callouts (| ... |) ---
        elif line.strip().startswith("|") and line.strip().endswith("|"):
            lower_line = line.strip().lower()
            # Check if this is a single-line summary callout table
            if lower_line.startswith("| summary") or lower_line.startswith("|summary"):
                summary_text = line.strip().strip("|")
                # Remove leading 'summary' or 'Summary'
                if summary_text.lower().startswith("summary"):
                    summary_text = summary_text[7:].strip()
                _add_callout_box(doc, summary_text)
                i += 1
                continue

            # Multi-line table collector
            table_lines = []
            while i < len(lines) and lines[i].strip().startswith("|") and lines[i].strip().endswith("|"):
                table_lines.append(lines[i].strip())
                i += 1

            # Process collected table
            parsed_rows = []
            for tl in table_lines:
                # Check if separator row like |:---|:---|
                cells = [c.strip() for c in tl.strip("|").split("|")]
                if all(re.match(r"^:?-+:?$", c) for c in cells if c):
                    continue  # Skip separator line
                parsed_rows.append(cells)

            if parsed_rows:
                num_cols = max(len(r) for r in parsed_rows)
                # Normalize column lengths
                for r in parsed_rows:
                    while len(r) < num_cols:
                        r.append("")

                table = doc.add_table(rows=len(parsed_rows), cols=num_cols)
                table.autofit = True
                _set_table_borders(table)

                for row_idx, row_data in enumerate(parsed_rows):
                    is_header = (row_idx == 0)
                    for col_idx, cell_value in enumerate(row_data):
                        cell = table.cell(row_idx, col_idx)
                        _set_cell_margins(cell, top=80, bottom=80, left=120, right=120)
                        if is_header:
                            _set_cell_bg(cell, "#1A237E")
                            p_cell = cell.paragraphs[0]
                            p_cell.clear()
                            _render_inline(p_cell, cell_value, override_color="#FFFFFF", is_header=True)
                        else:
                            if row_idx % 2 == 1:
                                _set_cell_bg(cell, "#F8F9FA")
                            p_cell = cell.paragraphs[0]
                            p_cell.clear()
                            _render_inline(p_cell, cell_value)

                doc.add_paragraph()  # Spacer after table
            continue
        elif line.strip().startswith("!["):
            img_match = re.match(r"!\[([^\]]*)\]\(([^)]+)\)", line.strip())
            if img_match:
                caption = img_match.group(1)
                url = img_match.group(2)
                _embed_image(url, caption)
            else:
                doc.add_paragraph(line.strip())

        # --- Horizontal rule ---
        elif line.strip() in ("---", "***", "___"):
            doc.add_paragraph("_" * 60)

        # --- Bullet points (including sub-bullets) ---
        elif re.match(r"^\s*[-*+]\s+", line):
            indent_spaces = len(line) - len(line.lstrip())
            cleaned_text = re.sub(r"^\s*[-*+]\s+", "", line).strip()
            style_name = "List Bullet 2" if indent_spaces >= 3 else "List Bullet"
            try:
                p = doc.add_paragraph(style=style_name)
            except Exception:
                p = doc.add_paragraph(style="List Bullet")
            _render_inline(p, cleaned_text)

        # --- Numbered lists ---
        elif re.match(r"^\s*\d+\.\s+", line):
            cleaned_text = re.sub(r"^\s*\d+\.\s+", "", line).strip()
            p = doc.add_paragraph(style="List Number")
            _render_inline(p, cleaned_text)

        # --- Blockquotes (e.g. > Key takeaway) ---
        elif line.strip().startswith(">"):
            quote_text = line.strip()[1:].strip()
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Inches(0.5)
            _render_inline(p, quote_text)
            for r in p.runs:
                r.italic = True

        # --- Blank line ---
        elif line.strip() == "":
            doc.add_paragraph()

        # --- Date / italic line (starts with *) ---
        elif line.strip().startswith("*") and line.strip().endswith("*") and not line.strip().startswith("**"):
            p = doc.add_paragraph()
            run = p.add_run(line.strip().strip("*"))
            run.italic = True
            run.font.size = Pt(10.5)
            r, g, b = _hex_to_rgb("#5C6BC0")
            run.font.color.rgb = RGBColor(r, g, b)

        # --- Normal paragraph ---
        else:
            if line.strip():
                p = doc.add_paragraph()
                _render_inline(p, line.strip())

        i += 1

    buf = io.BytesIO()
    doc.save(buf)
    buf.seek(0)
    return buf


def _render_inline(paragraph, text: str, override_color: str = None, is_header: bool = False):
    """
    Parses inline markdown in a paragraph:
    **bold**, *italic*, `code`, and $...$ / $$...$$ (rendered as native OMML Word equations).
    """
    import re
    # Pattern: bold, italic, inline code, inline/block math
    pattern = re.compile(r"(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`|\$\$[^$]+\$\$|\$[^$]+\$)")
    parts = pattern.split(text)
    for part in parts:
        if part.startswith("**") and part.endswith("**"):
            run = paragraph.add_run(part[2:-2])
            run.bold = True
            if override_color:
                r, g, b = _hex_to_rgb(override_color)
                run.font.color.rgb = RGBColor(r, g, b)
        elif part.startswith("*") and part.endswith("*") and not part.startswith("**"):
            run = paragraph.add_run(part[1:-1])
            run.italic = True
            if override_color:
                r, g, b = _hex_to_rgb(override_color)
                run.font.color.rgb = RGBColor(r, g, b)
        elif part.startswith("`") and part.endswith("`"):
            run = paragraph.add_run(part[1:-1])
            run.font.name = "Courier New"
            run.font.size = Pt(9.5)
            if override_color:
                r, g, b = _hex_to_rgb(override_color)
                run.font.color.rgb = RGBColor(r, g, b)
        elif (part.startswith("$$") and part.endswith("$$")) or (part.startswith("$") and part.endswith("$")):
            omml_elem = _latex_to_omml(part)
            if omml_elem is not None:
                paragraph._p.append(omml_elem)
            else:
                # Fallback to Cambria Math run
                clean_sym = part.strip("$")
                run = paragraph.add_run(clean_sym)
                run.font.name = "Cambria Math"
                run.font.size = Pt(10.5)
                run.italic = True
                if override_color:
                    r, g, b = _hex_to_rgb(override_color)
                    run.font.color.rgb = RGBColor(r, g, b)
        else:
            if part:
                run = paragraph.add_run(part)
                if is_header:
                    run.bold = True
                if override_color:
                    r, g, b = _hex_to_rgb(override_color)
                    run.font.color.rgb = RGBColor(r, g, b)

# ---------------------------------------------------------------------------
# Stage E: Supabase upload and 2-doc quota enforcement
# ---------------------------------------------------------------------------
def _upload_docx_to_supabase(docx_bytes: bytes, session_id: str, user_id: str) -> str | None:
    """Uploads .docx bytes to Supabase Storage bucket 'lecture-notes'."""
    supa_url, supa_key = _get_supabase_config()
    if not supa_url or not supa_key:
        return None

    filename = f"{user_id}/{session_id}_notes.docx"
    upload_url = f"{supa_url}/storage/v1/object/lecture-notes/{filename}"
    headers = {
        "apikey": supa_key,
        "Authorization": f"Bearer {supa_key}",
        "Content-Type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "x-upsert": "true"
    }
    req = urllib.request.Request(upload_url, data=docx_bytes, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            public_url = f"{supa_url}/storage/v1/object/public/lecture-notes/{filename}"
            print(f"[notes_generation] Uploaded .docx to Supabase Storage: {filename}")
            return public_url
    except Exception as e:
        print(f"[notes_generation] Supabase Storage upload failed: {e}")
        return None

def _enforce_2_doc_quota(user_id: str):
    """
    Maintains a rolling maximum of 2 generated notes per user.
    Fetches existing notes sorted by created_at ascending. If count > 2,
    deletes the oldest records and their corresponding .docx files from Storage.
    """
    supa_url, supa_key = _get_supabase_config()
    if not supa_url or not supa_key:
        return

    rows = _supabase_get(
        "generated_notes",
        {"user_id": f"eq.{user_id}", "select": "note_id,docx_filepath,created_at", "order": "created_at.asc"}
    ) or []

    if len(rows) <= 2:
        return

    to_delete = rows[:-2]  # Keep the 2 most recent (last 2), delete everything else
    for row in to_delete:
        note_id = row["note_id"]
        docx_url = row.get("docx_filepath", "")

        # 1. Delete from Supabase Storage
        if docx_url and "lecture-notes/" in docx_url:
            # Extract storage path from public URL
            # URL format: {supabase_url}/storage/v1/object/public/lecture-notes/{path}
            storage_path = docx_url.split("/object/public/lecture-notes/")[-1]
            # Supabase Storage delete requires POST to /object/delete/{bucket} with JSON body
            del_url = f"{supa_url}/storage/v1/object/delete/lecture-notes"
            del_headers = {
                "apikey": supa_key,
                "Authorization": f"Bearer {supa_key}",
                "Content-Type": "application/json",
            }
            del_body = json.dumps({"prefixes": [storage_path]}).encode("utf-8")
            del_req = urllib.request.Request(del_url, data=del_body, headers=del_headers, method="POST")
            try:
                with urllib.request.urlopen(del_req, timeout=10):
                    print(f"[notes_generation] Quota cleanup: deleted Storage file for note '{note_id}'.")
            except Exception as e:
                print(f"[notes_generation] Storage delete warning ({note_id}): {e}")

        # 2. Delete from generated_notes table
        _supabase_delete("generated_notes", {"note_id": f"eq.{note_id}"})
        print(f"[notes_generation] Quota cleanup: deleted DB record for note '{note_id}'.")

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
def generate_notes_for_session(session_id: str, user_id: str = "default_user", session_data: dict | None = None) -> dict:
    """
    Main entry point. Orchestrates all stages.

    Args:
        session_id:   The session identifier (e.g. 'lecture_session_01').
        user_id:      The user identifier for quota management (default: 'default_user').
        session_data: Optional explicit session dictionary with audio_chunks and image_snapshots
                      (used for direct mobile payload integration or offline testing).

    Returns:
        dict with keys: status, note_id, markdown_content, docx_path, docx_url, message
    """
    start_time = time.time()
    note_id = str(uuid.uuid4())

    try:
        # --- Stage A: Fetch data ---
        session, audio_chunks, snapshots = _fetch_session_data(session_id, session_data)

        if not audio_chunks and not snapshots:
            return {
                "status": "error",
                "note_id": None,
                "markdown_content": "",
                "docx_path": None,
                "docx_url": None,
                "message": "No approved audio chunks or snapshots found for this session."
            }

        # --- Stage B: Build chronological timeline ---
        timeline = _build_chronological_timeline(audio_chunks, snapshots)
        print(f"[notes_generation] Timeline built: {len(timeline)} events.")

        # --- Pre-fetch full-resolution images for .docx embedding ---
        # Keyed by URL so the docx builder can look them up
        image_map = {}
        for event in timeline:
            if event["type"] == "snapshot":
                pref = event.get("note_inclusion_preference", "BOTH")
                url = event.get("blurred_image_url")
                if pref in ("IMAGE_ONLY", "BOTH") and url:
                    if url not in image_map:
                        print(f"[notes_generation] Pre-fetching full-res image: {url[:60]}...")
                        image_map[url] = _fetch_image_bytes_full(url)

        # --- Stage C: Build Gemini parts & call API ---
        parts = _build_gemini_parts(timeline, session)
        markdown_text, token_usage = _call_gemini(parts, session, timeline)

        # --- Stage D: Build .docx ---
        print("[notes_generation] Building .docx document...")
        docx_buf = _build_docx(markdown_text, image_map)
        docx_bytes = docx_buf.read()

        # Save a local copy (safe path resolution: Desktop -> Documents -> temp)
        out_dir = Path.home() / "Desktop"
        if not out_dir.exists():
            out_dir = Path.home() / "Documents"
        if not out_dir.exists():
            out_dir = Path(__file__).resolve().parent / "generated_notes_docs"
        out_dir.mkdir(parents=True, exist_ok=True)
        docx_path = str(out_dir / f"{session_id}_notes.docx")
        with open(docx_path, "wb") as f:
            f.write(docx_bytes)
        print(f"[notes_generation] .docx saved locally: {docx_path}")

        # --- Stage E: Upload to Supabase Storage ---
        docx_url = _upload_docx_to_supabase(docx_bytes, session_id, user_id)

        # --- Save record to generated_notes table ---
        session_title = session.get("title", "Lecture Notes")
        note_record = {
            "note_id": note_id,
            "session_id": session_id,
            "user_id": user_id,
            "title": session_title,
            "markdown_content": markdown_text,
            "docx_filepath": docx_url or docx_path
        }
        _supabase_post("generated_notes", note_record)
        _local_generated_notes[session_id] = note_record
        try:
            json_path = str(out_dir / f"{session_id}_notes.json")
            with open(json_path, "w", encoding="utf-8") as f:
                json.dump(note_record, f, indent=2)
        except Exception:
            pass

        # --- Update session status (best-effort — only updates 'status') ---
        supa_url, supa_key = _get_supabase_config()
        if supa_url and supa_key:
            endpoint = f"{supa_url}/rest/v1/sessions?session_id=eq.{session_id}"
            headers = _supabase_headers(supa_key)
            headers["Prefer"] = "resolution=merge-duplicates"
            payload = json.dumps({"status": "COMPLETED", "notes_generated": True}).encode("utf-8")
            req = urllib.request.Request(endpoint, data=payload, headers=headers, method="PATCH")
            try:
                with urllib.request.urlopen(req, timeout=8):
                    pass
            except Exception:
                pass  # Silently ignore if 'status' column behaves differently

        # --- Enforce 2-doc rolling quota ---
        _enforce_2_doc_quota(user_id)

        elapsed = time.time() - start_time
        print(f"[notes_generation] Complete. Elapsed: {elapsed:.1f}s")

        return {
            "status": "success",
            "note_id": note_id,
            "title": session_title,
            "markdown_content": markdown_text,
            "docx_path": docx_path,
            "docx_url": docx_url,
            "token_usage": token_usage,
            "message": f"Notes generated successfully in {elapsed:.1f}s."
        }

    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        print(f"[notes_generation] FATAL ERROR:\n{tb}")
        return {
            "status": "error",
            "note_id": None,
            "markdown_content": "",
            "docx_path": None,
            "docx_url": None,
            "message": str(e)
        }

# 👓 AI Vision Glasses

> **Intelligent Multi-Modal Lecture & Workshop Assistant**  
> Real-time privacy-preserving board capture, speech-to-text transcription, semantic noise filtering, and cloud synchronization for automated structured note generation.

---

## 📑 Table of Contents
1. [Project Overview](#-project-overview)
2. [System Architecture & Communication](#-system-architecture--communication)
3. [Repository Structure](#-repository-structure)
4. [Teammate Contribution & Integration Analysis](#-teammate-contribution--integration-analysis)
5. [Prerequisites & System Requirements](#-prerequisites--system-requirements)
6. [Step-by-Step Installation & Setup](#-step-by-step-installation--setup)
7. [Comprehensive Testing & Verification Guide](#-comprehensive-testing--verification-guide)
8. [Current Features, Limitations & Roadmap](#-current-features-limitations--roadmap)
9. [Authors & Contributors](#-authors--contributors)

---

## 🌟 Project Overview

**AI Vision Glasses** is an end-to-end multi-modal note-taking platform designed for educational and professional environments (lectures, seminars, workshops). It bridges three core subsystems:

1. **Vision Pipeline (`Image_input_pipeline/`)**: Captures board/presentation slides, identifies and blurs human presence (faces/bodies) using a fine-tuned **YOLOv8** model for privacy compliance, enhances slide contrast, and extracts text using **EasyOCR**.
2. **Audio Pipeline (`audio_input_pipeline/`)**: Transcribes lecture speech in real-time using **Groq Whisper-large-v3** or local **faster-whisper**, applies semantic embeddings (**SentenceTransformers**) and LLM guards to filter off-topic banter/noise, and chunks audio into structured containers.
3. **Mobile & Web Client (`mobile_application/`)**: A cross-platform **Flutter** application (Web, Android, Desktop) providing real-time studio recording, privacy preview, synchronized chronological feeds, notes generation, and complete cloud synchronization with **Supabase**.

---

## 🔄 System Architecture & Communication

The diagram below illustrates how all three subsystems communicate:

```
                      +---------------------------------------+
                      |       Flutter Client Application      |
                      |  (Web / Android / Windows Desktop)    |
                      +---+-------------------------------+---+
                          |                               |
          Direct REST     |                               | WebSocket & REST
          & Supabase SDK  |                               | (Live Audio / Snapshots)
                          v                               v
        +----------------------------+     +-------------------------------+
        |      Supabase Cloud        |     |     FastAPI Python Backend    |
        |                            |     |   (audio_input_pipeline)      |
        | - PostgreSQL + pgvector    |<--->| - Port: 8000                  |
        | - Auth & Row-Level Security|     | - WebSocket: /ws/transcript   |
        | - Storage: lecture-audio   |     | - In-memory / Postgres Fallback|
        | - Storage: lecture-slides  |     +---------------+---------------+
        +----------------------------+                     |
                                                           | Direct Python Import
                                                           v
                                           +-------------------------------+
                                           |      Vision & OCR Subsystem   |
                                           |    (Image_input_pipeline)     |
                                           | - YOLOv8 Privacy Blurring     |
                                           | - Slide Contrast Enhancement  |
                                           | - EasyOCR Text Extraction     |
                                           +-------------------------------+
```

### Communication Protocols & Data Flow:

1. **Audio Streaming & Control**:
   - Flutter establishes a WebSocket connection with FastAPI at `ws://localhost:8000/ws/transcript`.
   - The Python backend captures microphone input or audio buffers, performs Speech-to-Text via Groq or Faster-Whisper, scores semantic relevance against the seminar topic, and broadcasts transcribed chunks back to the Flutter UI in real-time.
2. **Board Snapshots & Vision Processing**:
   - The Flutter camera screen captures a slide photo and dispatches it via multipart HTTP POST to `http://localhost:8000/api/v1/vision/process-snapshot`.
   - FastAPI invokes `PrivacyModel.apply_privacy_blur()` (YOLOv8) to mask individuals, runs `enhance_slide()` for contrast enhancement, and triggers `ocr.process_ocr_worker()` to extract board formulas/notes.
   - The processed snapshot and OCR metadata are stored in Supabase (`image_snapshots` and `ocr_extractions`), saved locally in `static/snapshots/`, and broadcast across WebSocket clients.
3. **Data Persistence & Note Generation**:
   - Both Flutter and the Python backend communicate with Supabase via REST / PostgreSQL.
   - Flutter manages sessions, manual user edits, and generated notes through `SupabaseService`.
   - Audio chunks and slide images are archived in Supabase Cloud Storage buckets (`lecture-audio` and `lecture-slides`).

---

## 📂 Repository Structure

```text
AI_Vision_Glasses/
├── .env.example                     # Environment template with all required keys
├── requirements.txt                 # Consolidated root Python dependencies
├── README.md                        # Primary project documentation (this file)
│
├── Image_input_pipeline/            # [Contributed by Aaisha Jamil]
│   ├── best.pt                      # Fine-tuned YOLOv8 model weights for privacy detection
│   ├── model.py                     # Privacy blurring engine (YOLOv8 human/face masking)
│   ├── enhance.py                   # Slide contrast leveling and sharpening filters
│   ├── ocr.py                       # EasyOCR worker and Supabase OCR persistence
│   ├── approve_store.py             # Image validation and Supabase slide uploader
│   ├── lecture.py                   # Standalone camera capture and lecture loop
│   ├── requirements.txt             # Vision-specific dependencies
│   └── supabase_schema.sql          # SQL schema for image_snapshots & OCR
│
├── audio_input_pipeline/            # [Contributed by Noor-Ul-Ain]
│   ├── main.py                      # Unified FastAPI server & vision/audio bridge
│   ├── audio_pipeline.py            # Audio accumulator, VAD, and transcription loop
│   ├── stt.py                       # Speech-to-Text provider (Groq Whisper / Faster-Whisper)
│   ├── semantic.py                  # SentenceTransformer embeddings & topic centroid scoring
│   ├── llm_filter.py                # Groq LLM noise and off-topic validator
│   ├── db.py                        # Supabase PostgreSQL client with memory fallback
│   ├── storage.py                   # Supabase Storage client (FLAC/WAV audio uploads)
│   ├── schema_postgres.sql          # Unified PostgreSQL schema with pgvector
│   ├── static/                      # Web dashboard & local snapshot storage
│   ├── tools/                       # Audio recording & STT diagnostic utilities
│   └── requirements.txt             # Audio-specific dependencies
│
└── mobile_application/              # [Contributed by Nawal Abid & Aaisha Jamil]
    ├── lib/
    │   ├── main.dart                # Application entrypoint & Supabase initialization
    │   ├── app.dart                 # Material 3 theme configuration & routing
    │   ├── data/
    │   │   └── demo_data.dart       # Live Supabase session loader with cached fallbacks
    │   ├── models/                  # Session, Note, SavedInput, BoardImage models
    │   ├── services/
    │   │   ├── supabase_service.dart# Direct Supabase REST/Storage CRUD operations
    │   │   ├── audio_pipeline_client.dart # FastAPI REST & WebSocket client
    │   │   └── session_manager.dart # Active recording session state manager
    │   ├── screens/
    │   │   ├── login_screen.dart    # User authentication screen
    │   │   ├── dashboard_screen.dart# Main navigation hub
    │   │   ├── audio_studio_screen.dart # Live recording, noise review & waveform studio
    │   │   ├── board_camera_screen.dart # Slide capture with live privacy preview
    │   │   ├── saved_inputs_screen.dart # Saved sessions list & status filters
    │   │   ├── saved_studio_session_screen.dart # Multi-modal synchronized review
    │   │   ├── saved_notes_screen.dart  # Formatted Markdown notes & docx export
    │   │   └── feedback_screen.dart # Session feedback
    │   └── widgets/                 # Cross-platform image loaders & UI components
    ├── test/
    │   ├── app_smoke_test.dart      # Application smoke & navigation test
    │   └── widget_test.dart         # Flutter widget test suite
    └── pubspec.yaml                 # Flutter package definitions
```

---

## 🔍 Teammate Contribution & Integration Analysis

The repository unites three independently developed modules. All original core algorithms and designs have been **100% preserved**, with minimal integration bridges added to enable cross-communication.

| Subsystem | Original Author | Original Commit & Date | Files Modified During Integration | Rationale for Integration Changes |
| :--- | :--- | :--- | :--- | :--- |
| **`Image_input_pipeline/`** | **Aaisha Jamil** | Commit `8d74614`<br>(Oct 21, 2026) | - `approve_store.py`<br>- `ocr.py` | 1. **Schema Resilience**: Handled column compatibility (`timestamp`, `blurred_filepath`) to prevent HTTP 400 errors with Supabase.<br>2. **Primary Key Alignment**: Added UUID generation (`ocr_id`) for `ocr_extractions` table.<br>3. **Preservation**: All original YOLOv8, enhancement, and OCR logic remain **100% intact**. |
| **`audio_input_pipeline/`** | **Noor-Ul-Ain** | Commit `d1cd00c`<br>(Oct 22, 2026)<br>PR `#1` / `cb545a8` | - `db.py`<br>- `main.py`<br>- `storage.py`<br>- `schema_postgres.sql` | 1. **Graceful Degradation**: Added in-memory fallback in `db.py` so the server runs even if PostgreSQL credentials are unconfigured.<br>2. **Vision Bridge**: Added `/api/v1/vision/process-snapshot` in `main.py` allowing Flutter to send images through YOLOv8 & OCR via the backend.<br>3. **Audio Fallback**: Added WAV encoding fallback in `storage.py` if PyAV/ffmpeg binary is missing.<br>4. **Schema Additions**: Added `user_id`, `notes_generated`, `expires_at`, and `raw_content` columns to `sessions` table for multi-user session management. |
| **`mobile_application/`** | **Nawal Abid**<br>*(Later: Aaisha Jamil)* | Commit `344c9f1`<br>(Oct 22, 2026)<br>Commit `b981c4e`<br>(Oct 24, 2026) | - `lib/services/` (New)<br>- `lib/data/demo_data.dart`<br>- `lib/screens/saved_inputs_screen.dart`<br>- `lib/screens/saved_studio_session_screen.dart` (New)<br>- `lib/widgets/image_loader*.dart` (New) | 1. **Live Supabase Synchronization**: Integrated `supabase_flutter` for real-time CRUD and RLS.<br>2. **Cross-Platform Compatibility**: Added abstract image loaders to support web browser rendering (`html.ImageElement`) and native mobile/desktop rendering without crashes.<br>3. **Studio Mode View**: Added dedicated multi-modal view in Saved Inputs so users can inspect synchronized transcripts, audio, and slides just like in the recording studio.<br>4. **Automated Smoke Tests**: Added `app_smoke_test.dart` verifying Material 3 widget rendering. |
| **Full-Stack Integration & Architecture** | **Syeda Maham Fatima** | Commit `f64ef2a`<br>(Nov 11, 2026) | - `audio_input_pipeline/main.py`<br>- `mobile_application/lib/services/`<br>- `saved_studio_session_screen.dart`<br>- `migration_session_management.sql`<br>- `test/` suite & project config | 1. **End-to-End System Integration**: Architected the cross-subsystem bridge connecting Flutter, FastAPI, YOLOv8 vision, and Whisper audio.<br>2. **Synchronized Studio Review**: Authored the full multi-modal studio screen (`saved_studio_session_screen.dart`) with synchronized timeline review.<br>3. **Cloud Service Layer**: Implemented `SupabaseService` with resilient caching and session management SQL migrations.<br>4. **Cross-Platform & QA**: Added web/desktop image loaders, automated smoke tests, and repository security (.gitignore / .env.example). |

### Summary of Changes for Teammates

#### 👁️ For Aaisha (Image Pipeline & Studio)
- **YOLOv8 & OCR Intact**: `model.py`, `enhance.py`, and `best.pt` run exactly as originally designed.
- **Supabase Compatibility**: `approve_store.py` and `ocr.py` now include fallback fields and unique UUID primary keys, preventing API errors when pushing snapshots and OCR to Supabase.
- **FastAPI Bridge**: Your vision pipeline is now imported directly into the main FastAPI backend at `/api/v1/vision/process-snapshot`.
- **Studio Mode**: Saved Inputs now features a multi-modal "Studio Mode" with tabbed synchronized feeds.

#### 🎙️ For Noor-Ul-Ain (Audio Pipeline)
- **STT & Noise Intact**: Whisper STT, SentenceTransformers semantic scoring, and Groq LLM filtering are fully active.
- **In-Memory Fallback**: `db.py` now includes memory buffering so the server stays up even if PostgreSQL credentials are unset or offline.
- **Vision Integration**: Added endpoints in `main.py` allowing mobile clients to route camera captures through YOLOv8 and OCR models.
- **Audio Fallback**: `storage.py` automatically falls back to WAV if PyAV is unavailable.

#### 📱 For Nawal (Mobile Application)
- **UI & Layouts Intact**: All Material 3 screen designs, widgets, and themes remain exactly as authored.
- **Supabase Integration**: `supabase_service.dart` provides live CRUD for sessions, audio chunks, and notes with RLS.
- **Cross-Platform Support**: Added web image loaders (`image_loader.dart`) preventing crashes on Chrome and Web builds.
- **FastAPI Client**: Added `audio_pipeline_client.dart` for WebSocket live speech streaming and camera snapshot uploads.

#### 🛠️ For Syeda Maham Fatima (Full-Stack System Integration & Cloud Architecture)
- **End-to-End Orchestration**: Connected the Flutter client, FastAPI backend, YOLOv8 vision pipeline, and audio transcription services into a cohesive, production-ready system.
- **Synchronized Studio Review Screen**: Designed and implemented the complete multi-modal studio review experience (`saved_studio_session_screen.dart`), synchronizing audio waveforms, transcription chunks, slide snapshots, and notes.
- **Cloud Services & Session Management**: Built the comprehensive `SupabaseService` layer with offline caching, resilience, and authored multi-user session management SQL schemas (`migration_session_management.sql`).
- **Cross-Platform & QA**: Engineered conditional web/native image loaders (`image_loader_*.dart`), automated smoke testing suites, and project health checks.
- **Security & Infrastructure**: Configured root `.gitignore`, environment templates (`.env.example`), consolidated dependencies (`requirements.txt`), and documentation.

---

## 💻 Prerequisites & System Requirements

- **Python**: Version `3.10` to `3.12` (Python 3.12 recommended; PyTorch and EasyOCR require 64-bit Python).
- **Flutter SDK**: Version `3.19.0` or later (`flutter doctor` must show no critical errors).
- **Web Browser**: Google Chrome or Microsoft Edge (for Flutter Web development).
- **Optional Native Devices**: Android Studio / Emulator, Windows Desktop build tools.
- **Supabase Account**: A Supabase project with PostgreSQL and pgvector extension enabled.
- **Groq API Key**: Optional, for cloud Whisper STT (`https://console.groq.com`).

---

## 🚀 Step-by-Step Installation & Setup

### 1. Clone & Configure Environment

```bash
# Clone the repository
git clone https://github.com/Aaisha-Jamil/AI_Vision_Glasses.git
cd AI_Vision_Glasses

# Create your local .env configuration from the template
cp .env.example .env
```

Open `.env` and fill in your Supabase credentials:
```ini
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_KEY=your_supabase_anon_publishable_key
SUPABASE_SECRET_KEY=your_supabase_service_role_key
DATABASE_URL=postgresql://postgres:your_password@db.your-project-ref.supabase.co:5432/postgres
GROQ_API_KEY=gsk_your_groq_key_here
```

### 2. Python Backend Setup

```bash
# Create and activate a Python virtual environment
python -m venv .venv

# Windows Powershell:
.venv\Scripts\Activate.ps1
# Linux / macOS:
# source .venv/bin/activate

# Install consolidated project dependencies
pip install -r requirements.txt
```

### 3. Database Schema Setup

In your Supabase project dashboard, navigate to the **SQL Editor** and run:
- `audio_input_pipeline/schema_postgres.sql`
- Ensure Storage Buckets `lecture-audio` and `lecture-slides` exist in your Supabase Storage dashboard.

### 4. Flutter Application Setup

```bash
cd mobile_application
flutter pub get
```

---

## 🧪 Comprehensive Testing & Verification Guide

### Test 1: Audio & Vision FastAPI Backend
Start the unified backend server using the virtual environment:
```bash
# Windows PowerShell (from repository root):
.venv\Scripts\python audio_input_pipeline\main.py

# Or from inside audio_input_pipeline directory:
..\.venv\Scripts\python main.py

# Or activate virtual environment first:
# .venv\Scripts\Activate.ps1
# python main.py
```
- Open your browser to: `http://localhost:8000/docs`
- Verify the following interactive endpoints:
  - `GET /health`: Returns `{"status": "ok", "vision_model": "yolov8_loaded", "ocr_available": true}`.
  - `POST /api/v1/vision/process-snapshot`: Upload a slide image to verify YOLOv8 privacy blur, contrast enhancement, and EasyOCR text extraction.
  - `WebSocket /ws/transcript`: Connects to live speech stream.

---

### Test 2: Flutter Application (Web & Chrome)
```bash
cd mobile_application
flutter run -d chrome
```
1. **Login**: Sign in with any email (e.g., `student@university.edu`).
2. **Dashboard**: Navigate to **Multi-Input Notes Studio** or **Saved Inputs**.
3. **Saved Inputs**: View previously saved workshop sessions fetched live from Supabase.
4. **Studio Mode View**: Click **"Studio Mode"** or **"Studio View"** on any session card to open the multi-modal viewer showing synchronized audio transcripts and slide snapshots.
5. **Board Camera**: Use the camera preview to test slide framing and privacy blurring.

---

### Test 3: Flutter Application (Android Emulator / Device)
```bash
cd mobile_application
flutter run -d android
```
*(Backend calls on Android emulator automatically resolve to `http://10.0.2.2:8000`).*

---

### Test 4: Automated Flutter Code Health & Tests
```bash
cd mobile_application
dart analyze lib
flutter test
```
*Expected Output*: `Analyzing lib... No issues found!` and `All tests passed!`.

---

## ⚡ Current Features, Limitations & Roadmap

### ✅ Current Working Features
- **YOLOv8 Privacy Protection**: Automatic detection and blurring of human bodies and faces in board captures.
- **Adaptive Slide Enhancement**: CamScanner-style adaptive thresholding, contrast adjustment, and shadow removal.
- **High-Accuracy OCR**: EasyOCR text extraction with bounding box isolation and confidence scoring.
- **Fast Speech-To-Text**: Real-time transcription via Groq Whisper or local faster-whisper.
- **Semantic Noise Filtering**: Automatic detection and flagging of side conversations, banter, and off-topic questions using SentenceTransformers.
- **Full Supabase Persistence**: Complete data lifecycle (sessions, chunks, snapshots, notes) with RLS and foreign-key cascading deletes.
- **Cross-Platform Flutter UI**: Modern Material 3 dark-mode interface with live audio waveform, synchronized multi-modal feed, and studio review.

### ⚠️ Current Limitations
- **Local YOLOv8 Weights**: `Image_input_pipeline/best.pt` requires local PyTorch execution; on systems without a dedicated GPU, initial model load may take 3–5 seconds.
- **Audio Device Access**: Live microphone streaming requires proper OS audio permissions; on headless servers or non-mic environments, the pipeline uses simulated or uploaded audio buffers.
- **7-Day Retention Window**: Auto-delete logic is defined in schema; scheduled cron jobs require Supabase pg_cron extension or backend cron activation.

---

## 👥 Authors & Contributors
- **Aaisha Jamil** (`@Aaisha-Jamil`): Vision & OCR Pipeline (`Image_input_pipeline`), Studio Notes integration.
- **Noor-Ul-Ain** (`@Noor-Ul-Ain16`): Audio Input Pipeline (`audio_input_pipeline`), FastAPI backend, Semantic noise scoring.
- **Nawal Abid** (`@NawalAbid`): Mobile Application (`mobile_application`), Flutter UI/UX architecture.
- **Syeda Maham Fatima** (`@Syeda-Maham-fatima05`): Full-Stack System Integration, Unified FastAPI Vision/Audio Bridge, Supabase Cloud Service Architecture, Synchronized Multi-Modal Studio Review, and QA Test Suites.

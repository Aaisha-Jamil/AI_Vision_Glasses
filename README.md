# 👓 AI Vision Glasses

> **Intelligent Multi-Modal Lecture & Workshop Assistant**  
> Real-time privacy-preserving board capture, speech-to-text transcription, semantic noise filtering, and cloud synchronization for automated structured note generation.

---

## 📑 Table of Contents
1. [Project Overview](#-project-overview)
2. [System Architecture & Communication](#-system-architecture--communication)
3. [Repository Structure](#-repository-structure)
4. [Teammate Contribution & Integration Analysis](#-teammate-contribution--integration-analysis)
5. [Hardware Setup & ESP32-CAM Smart Glasses](#-hardware-setup--esp32-cam-smart-glasses)
6. [Prerequisites & System Requirements](#-prerequisites--system-requirements)
7. [Step-by-Step Installation & Setup](#-step-by-step-installation--setup)
8. [Comprehensive Testing & Verification Guide](#-comprehensive-testing--verification-guide)
9. [Current Features, Limitations & Roadmap](#-current-features-limitations--roadmap)
10. [Authors & Contributors](#-authors--contributors)

---

## 🌟 Project Overview

**AI Vision Glasses** is an end-to-end multi-modal note-taking platform designed for educational and professional environments (lectures, seminars, workshops). It bridges four core subsystems:

1. **Smart Hardware Peripheral (`esp32_cam_firmware/`)**: An ESP32-CAM module mounted on smart glasses with an integrated push button for one-touch physical board slide capture, local PSRAM caching, and Wi-Fi streaming.
2. **Vision Pipeline (`Image_input_pipeline/`)**: Captures board/presentation slides, identifies and blurs human presence (faces/bodies) using a fine-tuned **YOLOv8** model for privacy compliance, enhances slide contrast, and extracts text using **EasyOCR**.
3. **Audio Pipeline (`audio_input_pipeline/`)**: Transcribes lecture speech in real-time using **Groq Whisper-large-v3** or local **faster-whisper**, applies semantic embeddings (**SentenceTransformers**) and LLM guards to filter off-topic banter/noise, and chunks audio into structured containers.
4. **Mobile & Web Client (`mobile_application/`)**: A cross-platform **Flutter** application (Web, Android, Desktop) providing real-time studio recording, privacy preview, synchronized chronological feeds, notes generation, and complete cloud synchronization with **Supabase**.

---

## 🔄 System Architecture & Communication

The diagram below illustrates how all four subsystems communicate:

```
  +-----------------------------------+
  |  ESP32-CAM Smart Glasses (HW)     |
  |  - Push Button Trigger (IO14)     |
  |  - OV2640 2MP Camera Sensor       |
  |  - PSRAM Buffer & Embedded Web UI |
  +-----------------+-----------------+
                    |
                    | Wi-Fi HTTP POST (/api/v1/glasses/capture)
                    v
  +-----------------------------------+        WebSocket & REST        +-----------------------------------+
  |      FastAPI Python Backend       |<------------------------------>|     Flutter Client Application    |
  |      (audio_input_pipeline)       |    (Live Transcripts/Photos)   |  (Web / Android / Windows Desktop)|
  | - Port: 8000                      |                                +-----------------+-----------------+
  | - WebSocket: /ws/transcript       |                                                  |
  | - In-memory / Postgres Fallback   |                                                  | Direct REST &
  +--------+------------------+-------+                                                  | Supabase SDK
           |                  |                                                          v
           | Direct Import    | Database & Storage Sync                +-----------------------------------+
           v                  +--------------------------------------->|          Supabase Cloud           |
  +---------------------------+                                        | - PostgreSQL + pgvector           |
  |   Vision & OCR Subsystem  |                                        | - Auth & Row-Level Security       |
  |   (Image_input_pipeline)  |                                        | - Storage: lecture-audio & slides |
  | - YOLOv8 Privacy Blurring |                                        +-----------------------------------+
  | - Contrast Enhancement    |
  | - EasyOCR Text Extraction |
  +---------------------------+
```

### Communication Protocols & Data Flow:

1. **Smart Glasses Board Capture (Hardware)**:
   - When the user presses the push button on pin **IO14**, the ESP32-CAM captures a high-resolution frame into PSRAM and dispatches an HTTP POST request to `http://<backend-ip>:8000/api/v1/glasses/capture`.
   - The backend runs YOLOv8 privacy blur (masking faces/bodies), slide contrast enhancement, and EasyOCR text extraction, saving the resulting snapshot to Supabase and broadcasting a `glasses_snapshot` event to all active Flutter clients.
2. **Audio Streaming & Noise Filtering**:
   - Flutter establishes a WebSocket connection with FastAPI at `ws://localhost:8000/ws/transcript`.
   - The Python backend captures audio input or buffers, performs Speech-to-Text via Groq or Faster-Whisper, scores semantic relevance against the seminar topic (SentenceTransformers), and streams clean transcription chunks to the Flutter UI in real-time.
3. **Mobile Board Camera Fallback**:
   - Users without the glasses can also take photos directly from their phone camera in the Flutter app via `POST /api/v1/vision/process-snapshot`.
4. **Data Persistence & Note Generation**:
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
├── esp32_cam_firmware/              # Smart glasses hardware client firmware (v2.0)
│   ├── esp32_cam_firmware.ino       # Arduino C++ firmware (Wi-Fi, PSRAM cache, HTTP server)
│   └── README.md                    # Hardware flashing, pinout, and web portal documentation
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

## 👓 Hardware Setup & ESP32-CAM Smart Glasses

The physical smart-glasses peripheral captures high-resolution board slides on-demand when the user presses the frame-mounted tactile button.

### 1. Bill of Materials (BOM) & Components
| Component | Specification | Purpose |
| :--- | :--- | :--- |
| **Microcontroller / Camera** | **AI-Thinker ESP32-CAM** (OV2640 2MP, 4MB PSRAM) | On-glasses image sensor, Wi-Fi radio, and local frame buffer |
| **USB Programmer Shield** | **ESP32-CAM-MB** (CH340 Micro-USB) | Power supply, serial flashing, and USB communication |
| **Trigger Switch** | Momentary Push Button (Normally Open, 6x6mm) | Mounted on glasses arm for single-click slide capture |
| **Power Source** | 5V Power Bank / Micro-USB Cable (or 3.7V LiPo + 5V boost) | Supplies stable power (minimum 1A recommended for Wi-Fi bursts) |
| **Eyewear Frame** | Standard glasses / 3D-printed clip-on mount | Houses the ESP32-CAM and trigger button at eye level |

---

### 2. Wiring & Pinout Diagram

The trigger switch connects directly to GPIO 14 (**IO14**) and **GND**. The internal pull-up resistor is enabled in firmware, so no external resistor is required.

```text
       +--------------------------------------------+
       |             ESP32-CAM Module               |
       |                                            |
       |  [OV2640 Lens]                             |
       |                                            |
       |         [IO14 / GPIO 14] -----------+      |
       |         [GND]            -----+     |      |
       +-------------------------------+-----+------+
                                       |     |
                                    +--+--+  |
                                    |     |  |
                                    | [o] |--+  <-- Push Button (Normally Open)
                                    |     |
                                    +-----+
```

* **IO14 (GPIO 14)**: Connected to Pin 1 of the Push Button (active LOW, triggered on press).
* **GND**: Connected to Pin 2 of the Push Button.
* **5V & GND**: Powered via the ESP32-CAM-MB daughterboard via standard Micro-USB cable.

---

### 3. Arduino IDE Setup & Firmware Flashing

1. Install the **ESP32 Board Package** in Arduino IDE (`Boards Manager` -> search for `esp32` by Espressif Systems).
2. Open `esp32_cam_firmware/esp32_cam_firmware.ino`.
3. Configure the **Tools** menu settings:
   - **Board**: `AI Thinker ESP32-CAM`
   - **CPU Frequency**: `240MHz (WiFi/BT)`
   - **Flash Frequency**: `80MHz`
   - **Flash Mode**: `QIO`
   - **Partition Scheme**: `Huge APP (3MB No OTA/1MB SPIFFS)` *(Crucial: required for high-resolution UXGA image buffers!)*
   - **Port**: Select the COM port of your connected ESP32-CAM-MB (e.g. `COM5`).
4. (Optional) Set your default Wi-Fi SSID and Password on lines 67-68:
   ```cpp
   const char* DEFAULT_SSID = "Your_WiFi_SSID";
   const char* DEFAULT_PASS = "Your_WiFi_Password";
   ```
5. Click **Upload**.
6. Once uploaded, open the **Serial Monitor** at **115200 baud** to view boot logs and IP assignment.

---

### 4. Smart Firmware Features & Networking

The v2.0 firmware includes resilient networking and on-board management capabilities:

- **Automatic Heartbeat Registration**: Upon Wi-Fi connection, the glasses ping the FastAPI backend (`/api/v1/glasses/heartbeat`), allowing the Flutter mobile app to immediately recognize the glasses' connection status.
- **Embedded Web Control Hub (Port 80)**:
  - Access `http://<glasses-ip>/` (e.g. `http://192.168.10.26/`) in any browser on your phone or PC.
  - View live previews of captured slides without needing backend services.
  - Direct full-res image URL: `http://<glasses-ip>/latest.jpg`.
- **Runtime IP Reconfiguration (Zero Re-flashing)**:
  - If your backend computer IP changes (e.g., `192.168.10.25`), open `http://<glasses-ip>/` in your phone browser, enter the new backend IP, and tap **Save**. It is permanently stored in ESP32 non-volatile flash (NVS).
- **Fallback Hotspot (AP Mode)**:
  - If the configured Wi-Fi is unavailable (e.g. in lecture halls or outdoors), the glasses launch a standalone Wi-Fi hotspot named `AI-Vision-Glasses` (Password: `12345678`) at `192.168.4.1`.
- **mDNS Support**:
  - Reachable via `http://ai-glasses.local/` on supported local network devices.

---

### 5. Live Operation & Multi-Modal Sync Flow

```text
   [User Clicks Button on Glasses]
                 │
                 ▼
   [ESP32 captures UXGA frame to PSRAM]
                 │
                 ▼ (HTTP POST binary JPEG)
   [FastAPI Backend: /api/v1/glasses/capture]
                 │
       ┌─────────┴─────────┐
       ▼                   ▼
   [YOLOv8 Face Blur]   [EasyOCR Extraction]
       │                   │
       └─────────┬─────────┘
                 │
                 ▼ (WebSocket Broadcast: glasses_snapshot)
   [Flutter App: Multi-Input Notes Studio]
   - Shows real-time slide inline with audio transcript
   - Synchronized to exact lecture timeline second
```

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

### Test 5: ESP32-CAM Smart Glasses Hardware Verification
1. **Live Camera Hub**: Open `http://<glasses-ip>/` in your phone or PC browser (or `http://ai-glasses.local/`). Verify the camera status is `ready` and click "📸 Capture Slide Now".
2. **Physical Button Trigger**: Press the push button on GPIO 14. Observe the flash/status LED blink on the glasses, indicating capture and successful upload.
3. **Backend Monitor**: Navigate to `http://localhost:8000/api/v1/glasses/capture` in your browser to view the latest blurred frame and extracted EasyOCR formulas.
4. **Flutter Studio Sync**: In the Flutter app, open **Multi-Input Notes Studio**. The hardware status chip will indicate **"AI Vision Glasses (ESP32-CAM) Connected"** and display the captured slide inline on the timeline.

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

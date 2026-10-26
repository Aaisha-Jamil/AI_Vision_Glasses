# Privacy-Preserving Smart Glasses & Lecture Synthesis Subsystem

## Overview
This subsystem provides the **Image Input, Visual Privacy Shielding, Slide Clarification, Review State Machine, OCR Extraction, and Cloud Persistence Layer** for the overarching lecture synthesis platform.

---

## Architecture & Decoupled Pipeline Stages

```
Raw Lecture Video (test_lec.mp4)
              │
              ▼
   [ Stage 1: model.py ] ──► YOLOv8 Person Segmentation (best.pt) + Frosted Cyan Blur
              │
              ▼
   [ Stage 2: enhance.py ] ──► CamScanner Illumination Leveling & Board Enhancement
              │
              ▼
   [ Stage 3: approve_store.py ] ──► 20s State Machine: [KEEP], [REPLACE], [DISCARD]
              │
              ▼
   [ Stage 4: ocr.py ] ──► Silhouette White-Out + EasyOCR Async Worker + Cloud Sync
              │
              ▼
    Supabase Storage & PostgreSQL (lecture-slides, image_snapshots, ocr_extractions)
```

### 1. Stage 1: Visual Privacy Intercept (`model.py`)
- Real-time YOLOv8 person segmentation (`best.pt`) executed strictly on unprocessed BGR frames.
- Tuned confidence threshold: `0.15`.
- Pixel-precise polygon contour extraction with **zero dilation** to prevent blue blur from leaking onto the board.
- Composited frosted cyan-blue shield (`B=220, G=110, R=40`) at `0.88` opacity with `65x65` Gaussian blur for facial anonymization.

### 2. Stage 2: Slide Clarification (`enhance.py`)
- CamScanner illumination leveling and dry-erase marker sharpening without cropping (100% field of view preserved).
- **Whiteboard Pre-Fill**: Masked presenter region is pre-filled with neutral whiteboard color (`[245, 245, 245]`) before running morphological leveling, eliminating halos and smearing.
- The privacy-shielded human from Stage 1 is pasted back pristine into the enhanced frame.

### 3. Stage 3: Review State Machine (`approve_store.py`)
- **[✓ KEEP]**: Approves slide quality, uploads image bytes directly to Supabase Storage (`lecture-slides`), writes snapshot metadata, and unlocks Phase 2.
- **[🔄 REPLACE]**: Sets status `REPLACED`. The subsequent capture inherits the exact sequence timestamp to preserve audio synchronization.
- **[🗑️ DISCARD]**: Drops and cancels capture immediately. No database record is written and no timestamp is inherited.
- **Auto-Approval**: Slides auto-approve after 20 seconds of inactivity or when a subsequent slide is captured.

### 4. Stage 4: OCR Extraction Module (`ocr.py`)
- **Silhouette White-Out**: Expands presenter mask by 6 pixels and whites out the region (`[255, 255, 255]`) to prevent clothing folds or hair contours from generating false-positive characters.
- CLAHE + bilateral filtering pre-processing.
- Asynchronous background execution using `EasyOCR` on a daemon thread without blocking video playback.
- Word confidence scoring and automatic fallback handling.
- Persists extracted text to `public.ocr_extractions` and updates `note_inclusion_preference` in `public.image_snapshots`.

---

## Project Structure

```
Image_input_pipeline/
├── main.py                   # Platform entrypoint
├── lecture.py                # Desktop GUI (OpenCV + Tkinter) & Review Panel
├── model.py                  # Stage 1: YOLO Person Segmentation & Privacy Blur
├── enhance.py                # Stage 2: Whiteboard Clarification & Color Leveling
├── approve_store.py          # Stage 3: Review Manager & Supabase Cloud REST Sync
├── ocr.py                    # Stage 4: EasyOCR Extraction & Note Attachment
├── supabase_schema.sql       # PostgreSQL DDL & Row Level Security (RLS) Policies
├── requirements.txt          # Python dependencies
├── .env.example              # Environment variables template
├── .gitignore                # Git ignore rules for secrets and heavy binaries
└── README.md                 # System documentation
```

---

## Setup & Installation

### 1. Prerequisites
- Python 3.9+
- Pip package manager

### 2. Install Dependencies
```bash
pip install -r requirements.txt
```

### 3. Configure Supabase Cloud Database
1. In your Supabase Project dashboard, open the **SQL Editor**.
2. Run the full script provided in `supabase_schema.sql`. This sets up:
   - `public.sessions`
   - `public.image_snapshots`
   - `public.ocr_extractions`
   - Row Level Security (RLS) policies
   - Public storage bucket `lecture-slides`
3. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```
4. Fill in your project URL and public anon key in `.env`:
   ```env
   SUPABASE_URL=https://your-project-ref.supabase.co
   SUPABASE_KEY=your-supabase-anon-key
   ```

### 4. Model Weights
Ensure the trained YOLO person segmentation weights file `best.pt` is placed in this directory.

---

## Running the Application

Launch the desktop lecture review interface:
```bash
python main.py
```
*(or run directly via `python lecture.py`)*

### Keyboard Shortcuts
- **Enter** / **KP_Enter**: Capture slide frame (`SNAP SLIDE`)
- **Space**: Play / Pause video playback
- **K** / **A**: Keep slide (`[✓ KEEP]`)
- **R**: Replace blurry capture (`[🔄 REPLACE]`)
- **D** / **Delete**: Discard snapshot (`[🗑️ DISCARD]`)
- **Esc**: Exit application

import os
import cv2
import numpy as np
import threading
import json
import urllib.request

# Lazy-loaded EasyOCR reader instance to avoid heavy startup overhead
_easyocr_reader = None

def get_easyocr_reader():
    global _easyocr_reader
    if _easyocr_reader is None:
        try:
            import easyocr
            print("[ocr.py]: Initializing EasyOCR reader (PyTorch model)...")
            _easyocr_reader = easyocr.Reader(['en'], gpu=False, verbose=False)
            print("[ocr.py SUCCESS]: EasyOCR reader initialized.")
        except Exception as e:
            print(f"[ocr.py Error]: Failed to initialize EasyOCR ({e}).")
            _easyocr_reader = None
    return _easyocr_reader

def get_supabase_config():
    """Reads Supabase URL and Key from environment variables."""
    url = os.getenv("SUPABASE_URL", "").strip()
    key = os.getenv("SUPABASE_KEY", "").strip()
    if "/rest" in url:
        url = url.split("/rest")[0]
    return url.rstrip('/'), key

def save_ocr_to_supabase(snapshot_id, session_id, extracted_text, confidence_score, note_inclusion_preference):
    """
    Step 5: Supabase Cloud Persistence
    - Inserts extracted text into public.ocr_extractions.
    - Patches public.image_snapshots with the chosen note_inclusion_preference.
    """
    url, key = get_supabase_config()
    if not url or not key or "your-supabase" in url:
        print("[Supabase Warning]: Supabase credentials not configured. OCR result saved locally only.")
        return False

    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "return=minimal"
    }

    # 1. Insert into ocr_extractions
    ocr_endpoint = f"{url}/rest/v1/ocr_extractions"
    ocr_payload = {
        "snapshot_id": snapshot_id,
        "session_id": session_id,
        "extracted_text": extracted_text,
        "confidence_score": float(confidence_score)
    }
    
    try:
        req = urllib.request.Request(ocr_endpoint, data=json.dumps(ocr_payload).encode('utf-8'), headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=6) as response:
            print(f"[Supabase SUCCESS]: OCR extraction for snapshot '{snapshot_id}' pushed to cloud database!")
    except Exception as e:
        print(f"[Database Error]: Failed to push OCR record ({e}).")

    # 2. Patch image_snapshots note_inclusion_preference
    snap_endpoint = f"{url}/rest/v1/image_snapshots?snapshot_id=eq.{snapshot_id}"
    snap_payload = {
        "note_inclusion_preference": note_inclusion_preference
    }
    try:
        patch_headers = headers.copy()
        patch_headers["Prefer"] = "resolution=merge-duplicates"
        req = urllib.request.Request(snap_endpoint, data=json.dumps(snap_payload).encode('utf-8'), headers=patch_headers, method="PATCH")
        with urllib.request.urlopen(req, timeout=6) as response:
            print(f"[Supabase SUCCESS]: Updated snapshot '{snapshot_id}' preference to '{note_inclusion_preference}'.")
            return True
    except Exception as e:
        print(f"[Database Error]: Failed to update snapshot preference ({e}).")
        return False

def process_ocr_worker(snapshot_id, session_id, enhanced_frame, human_mask, note_inclusion_preference="BOTH"):
    """
    Asynchronous Background OCR Worker Thread:
    Executes steps 1 through 5 without blocking the UI.
    """
    print(f"\n[ocr.py Worker]: Starting OCR processing for snapshot '{snapshot_id}' (Preference: {note_inclusion_preference})...")
    
    h, w = enhanced_frame.shape[:2]

    # Step 1: Person Silhouette Masking (Zero False Positives)
    # Dilate human_mask by 6 pixels and fill region with pure white [255, 255, 255][cite: 2, 3]
    if human_mask is not None and np.any(human_mask > 0):
        kernel = np.ones((6, 6), np.uint8)
        dilated_mask = cv2.dilate(human_mask, kernel, iterations=1)
        board_canvas = enhanced_frame.copy()
        board_canvas[dilated_mask > 0] = [255, 255, 255]
    else:
        board_canvas = enhanced_frame

    # Step 2: Contrast & Binarization Pre-Processing[cite: 2, 3]
    gray = cv2.cvtColor(board_canvas, cv2.COLOR_BGR2GRAY)
    denoised = cv2.bilateralFilter(gray, d=7, sigmaColor=35, sigmaSpace=35)
    
    clahe = cv2.createCLAHE(clipLimit=1.5, tileGridSize=(8, 8))
    clahe_img = clahe.apply(denoised)

    # Step 3: Engine Dispatch (EasyOCR)[cite: 2, 3]
    reader = get_easyocr_reader()
    extracted_text_lines = []
    confidences = []

    if reader is not None:
        try:
            results = reader.readtext(clahe_img)
            for bbox, text, conf in results:
                cleaned = text.strip()
                if len(cleaned) > 1 or cleaned.isalnum():
                    extracted_text_lines.append(cleaned)
                    confidences.append(float(conf))
        except Exception as e:
            print(f"[ocr.py Error]: EasyOCR execution exception ({e}).")

    # Step 4: Confidence Scoring & Gibberish Filtering[cite: 2, 3]
    if extracted_text_lines:
        final_text = "\n".join(extracted_text_lines)
        avg_confidence = sum(confidences) / len(confidences) if confidences else 0.0
    else:
        final_text = "[No legible text detected on slide]"
        avg_confidence = 0.0

    print(f"[ocr.py SUCCESS]: Extracted {len(extracted_text_lines)} text blocks. Avg Confidence: {avg_confidence:.2f}")
    print(f"--- Extracted Text Preview ---\n{final_text[:300]}\n------------------------------")

    # Step 5: Supabase Cloud Persistence[cite: 2, 3]
    save_ocr_to_supabase(snapshot_id, session_id, final_text, avg_confidence, note_inclusion_preference)
    return final_text, avg_confidence

def run_ocr_async(snapshot_id, session_id, enhanced_frame, human_mask, note_inclusion_preference="BOTH"):
    """Spawns the OCR worker in a background daemon thread for non-blocking UI execution[cite: 2, 3]."""
    worker_thread = threading.Thread(
        target=process_ocr_worker,
        args=(snapshot_id, session_id, enhanced_frame, human_mask, note_inclusion_preference),
        daemon=True
    )
    worker_thread.start()
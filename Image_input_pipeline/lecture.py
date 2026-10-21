import os
import sys
import glob
import time
import threading
import subprocess
import tkinter as tk
from tkinter import ttk, messagebox, filedialog
import cv2
import numpy as np
from PIL import Image, ImageTk

# Import core pipeline modules
from model import apply_privacy_blur
from enhance import enhance_slide
from approve_store import ReviewManager, get_all_snapshots, is_supabase_configured, ensure_session_exists

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))

class LectureApp:
    def __init__(self, root, video_path=None):
        self.root = root
        self.video_path = video_path or self.find_default_video()
        self.root.title(f"Lecture Mode - {os.path.basename(self.video_path) if self.video_path else 'No Video'}")

        try:
            self.root.state('zoomed')
        except Exception:
            self.root.geometry("1280x780")

        self.root.minsize(1050, 680)
        self.root.configure(bg="#12121A")

        self.review_mgr = ReviewManager(timeout_seconds=20.0)
        self._last_processed_snapshot = None

        # Initialize session in Supabase cloud database
        video_title = os.path.basename(self.video_path) if self.video_path else "Lecture Session"
        threading.Thread(target=ensure_session_exists, args=("lecture_session_01", f"Lecture: {video_title}"), daemon=True).start()

        self.cap = None
        self.fps = 25.0
        self.total_frames = 1
        self.duration_secs = 0.0
        self.frame_delay_ms = 33
        self.is_playing = True
        self.current_raw_frame = None
        self.current_frame_idx = 0
        self.is_processing_snapshot = False

        self.enhancement_mode = tk.StringVar(value="magic_color")
        self.privacy_target = tk.StringVar(value="full_body")

        self._build_ui()
        self._bind_keys()

        if self.video_path and os.path.exists(self.video_path):
            self.load_video(self.video_path)

        self.update_video_frame()
        self.update_review_status_loop()

    def find_default_video(self):
        search_dirs = [ROOT_DIR, os.getcwd()]
        for sdir in search_dirs:
            for ext in ("*.mp4", "*.avi", "*.mkv", "*.mov"):
                matches = glob.glob(os.path.join(sdir, ext))
                if matches:
                    return os.path.abspath(matches[0])
        return "test_lec.mp4"

    def load_video(self, video_path):
        if self.cap is not None:
            self.cap.release()

        self.video_path = video_path
        self.cap = cv2.VideoCapture(self.video_path)

        if not self.cap.isOpened():
            messagebox.showerror("Error Loading Video", f"Could not open video file:\n{self.video_path}")
            return False

        self.fps = self.cap.get(cv2.CAP_PROP_FPS) or 25.0
        self.total_frames = int(self.cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
        self.duration_secs = self.total_frames / self.fps
        self.frame_delay_ms = max(10, int(1000 / self.fps))
        self.is_playing = True
        self.title_lbl.configure(text=f"🎥 Lecture: {os.path.basename(self.video_path)}")
        self.root.title(f"Lecture Mode - {os.path.basename(self.video_path)}")
        return True

    def change_video_dialog(self):
        file_selected = filedialog.askopenfilename(
            title="Select Lecture Video File",
            filetypes=[("Video Files", "*.mp4 *.avi *.mkv *.mov"), ("All Files", "*.*")]
        )
        if file_selected:
            self.load_video(file_selected)

    def _build_ui(self):
        top_bar = tk.Frame(self.root, bg="#1E1E2C", height=50)
        top_bar.pack(side=tk.TOP, fill=tk.X)

        self.title_lbl = tk.Label(
            top_bar,
            text=f"🎥 Lecture: {os.path.basename(self.video_path) if self.video_path else 'No Video Loaded'}",
            font=("Segoe UI", 11, "bold"),
            bg="#1E1E2C",
            fg="#00E5FF"
        )
        self.title_lbl.pack(side=tk.LEFT, padx=16, pady=10)

        change_vid_btn = tk.Button(
            top_bar, text="📂 Change Video", font=("Segoe UI", 9, "bold"),
            bg="#32324A", fg="#FFFFFF", activebackground="#454565", activeforeground="#FFFFFF",
            relief=tk.FLAT, padx=10, pady=2, command=self.change_video_dialog
        )
        change_vid_btn.pack(side=tk.LEFT, padx=10)

        db_badge = "☁️ Supabase Cloud (Live)" if is_supabase_configured() else "☁️ Cloud Offline"
        db_fg = "#80E27E" if is_supabase_configured() else "#FFB74D"
        db_lbl = tk.Label(
            top_bar, text=db_badge, font=("Segoe UI", 9, "bold"),
            bg="#2A2A3E", fg=db_fg, padx=10, pady=4
        )
        db_lbl.pack(side=tk.RIGHT, padx=16)

        content_frame = tk.Frame(self.root, bg="#12121A")
        content_frame.pack(side=tk.TOP, fill=tk.BOTH, expand=True, padx=10, pady=8)
        content_frame.columnconfigure(0, weight=1)
        content_frame.columnconfigure(1, weight=0)
        content_frame.rowconfigure(0, weight=1)

        left_col = tk.Frame(content_frame, bg="#1A1A26", bd=1, relief=tk.SOLID)
        left_col.grid(row=0, column=0, sticky="nsew", padx=(0, 8))

        feed_header = tk.Frame(left_col, bg="#242436")
        feed_header.pack(fill=tk.X, padx=2, pady=2)
        tk.Label(feed_header, text="LECTURE STREAM FEED", font=("Segoe UI", 10, "bold"), bg="#242436", fg="#FFFFFF").pack(side=tk.LEFT, padx=10, pady=6)
        self.time_lbl = tk.Label(feed_header, text="00:00.0 / 00:00.0", font=("Segoe UI", 9), bg="#242436", fg="#A0A0C0")
        self.time_lbl.pack(side=tk.RIGHT, padx=10)

        self.video_canvas = tk.Label(left_col, bg="#08080E")
        self.video_canvas.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)

        vid_btn_bar = tk.Frame(left_col, bg="#1A1A26")
        vid_btn_bar.pack(fill=tk.X, padx=8, pady=(0, 8))

        self.play_pause_btn = tk.Button(
            vid_btn_bar, text="⏸ Pause (Space)", font=("Segoe UI", 9, "bold"),
            bg="#323246", fg="#FFFFFF", relief=tk.FLAT, padx=12, command=self.toggle_play_pause
        )
        self.play_pause_btn.pack(side=tk.LEFT, padx=(0, 6))

        restart_btn = tk.Button(
            vid_btn_bar, text="⏮ Restart", font=("Segoe UI", 9),
            bg="#323246", fg="#FFFFFF", relief=tk.FLAT, padx=12, command=self.restart_video
        )
        restart_btn.pack(side=tk.LEFT)

        right_col = tk.Frame(content_frame, bg="#12121A", width=380)
        right_col.grid(row=0, column=1, sticky="nsew")
        right_col.grid_propagate(False)

        mobile_shell = tk.Frame(right_col, bg="#2A2A3C", bd=3, relief=tk.RAISED, padx=10, pady=10)
        mobile_shell.pack(fill=tk.BOTH, expand=True)

        notch_frame = tk.Frame(mobile_shell, bg="#151520", height=22)
        notch_frame.pack(fill=tk.X, pady=(0, 6))
        tk.Label(notch_frame, text="━━━━━  📱 SLIDE REVIEW CONSOLE  ━━━━━", font=("Segoe UI", 8, "bold"), bg="#151520", fg="#808095").pack(pady=2)

        self.mobile_screen = tk.Frame(mobile_shell, bg="#0D0D15", bd=1, relief=tk.SOLID)
        self.mobile_screen.pack(fill=tk.BOTH, expand=True)

        app_bar = tk.Frame(self.mobile_screen, bg="#1A1A2A")
        app_bar.pack(fill=tk.X)
        tk.Label(app_bar, text="Captured Slide Review", font=("Segoe UI", 10, "bold"), bg="#1A1A2A", fg="#00E5FF").pack(side=tk.LEFT, padx=10, pady=6)
        self.mobile_time_badge = tk.Label(app_bar, text="00.0s", font=("Segoe UI", 8, "bold"), bg="#28283E", fg="#A0A0B0", padx=6, pady=2)
        self.mobile_time_badge.pack(side=tk.RIGHT, padx=10)

        mode_frame = tk.Frame(self.mobile_screen, bg="#141420", pady=3)
        mode_frame.pack(fill=tk.X, padx=8, pady=(4, 2))
        tk.Label(mode_frame, text="Mode:", font=("Segoe UI", 8, "bold"), bg="#141420", fg="#A0A0C0").pack(side=tk.LEFT, padx=(4, 6))
        for text, val in [("🎨 Magic Color", "magic_color"), ("📄 Clean B&W", "clean_bw"), ("🎬 Low-Res", "lowres_smooth")]:
            rb = tk.Radiobutton(
                mode_frame, text=text, variable=self.enhancement_mode, value=val,
                bg="#141420", fg="#E0E0E0", selectcolor="#28283E", activebackground="#141420",
                activeforeground="#00E5FF", font=("Segoe UI", 8), indicatoron=0, padx=6, pady=2
            )
            rb.pack(side=tk.LEFT, padx=2)

        privacy_frame = tk.Frame(self.mobile_screen, bg="#141420", pady=3)
        privacy_frame.pack(fill=tk.X, padx=8, pady=(0, 4))
        tk.Label(privacy_frame, text="Blur:", font=("Segoe UI", 8, "bold"), bg="#141420", fg="#A0A0C0").pack(side=tk.LEFT, padx=(4, 6))
        for text, val in [("👤 Face", "face_only"), ("🧍 Full Body", "full_body"), ("🚫 Off", "off")]:
            rb = tk.Radiobutton(
                privacy_frame, text=text, variable=self.privacy_target, value=val,
                bg="#141420", fg="#E0E0E0", selectcolor="#28283E", activebackground="#141420",
                activeforeground="#69F0AE", font=("Segoe UI", 8), indicatoron=0, padx=5, pady=2
            )
            rb.pack(side=tk.LEFT, padx=2)

        self.preview_canvas = tk.Label(
            self.mobile_screen,
            text="📱 Ready to Capture\n\nPress [ENTER] or click SNAP SLIDE!",
            font=("Segoe UI", 9),
            bg="#0D0D15",
            fg="#707085",
            justify=tk.CENTER
        )
        self.preview_canvas.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)

        self.review_status_lbl = tk.Label(
            self.mobile_screen, text="Status: Waiting for Snapshot",
            font=("Segoe UI", 9, "bold"), bg="#141420", fg="#FFD700", pady=4
        )
        self.review_status_lbl.pack(fill=tk.X, padx=8, pady=(0, 4))

        # Phase 1 Action Buttons: KEEP, REPLACE, and DISCARD
        mobile_action_bar = tk.Frame(self.mobile_screen, bg="#141420", pady=4)
        mobile_action_bar.pack(fill=tk.X, padx=8, pady=(0, 4))

        self.keep_btn = tk.Button(
            mobile_action_bar, text="✓ KEEP", font=("Segoe UI", 9, "bold"),
            bg="#00C853", fg="#FFFFFF", activebackground="#00E676", activeforeground="#FFFFFF",
            relief=tk.FLAT, padx=8, pady=6, command=self.keep_snapshot, state=tk.DISABLED
        )
        self.keep_btn.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(1, 1))

        self.replace_btn = tk.Button(
            mobile_action_bar, text="🔄 REPLACE", font=("Segoe UI", 9, "bold"),
            bg="#FF6D00", fg="#FFFFFF", activebackground="#FF9100", activeforeground="#FFFFFF",
            relief=tk.FLAT, padx=8, pady=6, command=self.replace_snapshot, state=tk.DISABLED
        )
        self.replace_btn.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(1, 1))

        self.discard_btn = tk.Button(
            mobile_action_bar, text="🗑 DISCARD", font=("Segoe UI", 9, "bold"),
            bg="#D32F2F", fg="#FFFFFF", activebackground="#F44336", activeforeground="#FFFFFF",
            relief=tk.FLAT, padx=8, pady=6, command=self.discard_snapshot, state=tk.DISABLED
        )
        self.discard_btn.pack(side=tk.RIGHT, fill=tk.X, expand=True, padx=(1, 1))

        # Phase 2: Note Inclusion Preference Panel (Unlocked after KEEP)
        phase2_frame = tk.Frame(self.mobile_screen, bg="#141420", pady=4)
        phase2_frame.pack(fill=tk.X, padx=8, pady=(0, 6))
        
        tk.Label(phase2_frame, text="Phase 2: Note Inclusion Preference", font=("Segoe UI", 8, "bold"), bg="#141420", fg="#00E5FF").pack(anchor=tk.W, padx=6, pady=2)
        
        p2_btn_bar = tk.Frame(phase2_frame, bg="#141420")
        p2_btn_bar.pack(fill=tk.X, padx=4, pady=2)

        self.attach_as_is_btn = tk.Button(
            p2_btn_bar, text="Attach As Is", font=("Segoe UI", 8, "bold"),
            bg="#2A2A3E", fg="#E0E0E0", relief=tk.FLAT, padx=4, pady=4,
            command=lambda: self.set_note_preference("IMAGE_ONLY"), state=tk.DISABLED
        )
        self.attach_as_is_btn.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)

        self.extract_ocr_btn = tk.Button(
            p2_btn_bar, text="Extract OCR", font=("Segoe UI", 8, "bold"),
            bg="#2A2A3E", fg="#E0E0E0", relief=tk.FLAT, padx=4, pady=4,
            command=lambda: self.set_note_preference("OCR_TEXT_ONLY"), state=tk.DISABLED
        )
        self.extract_ocr_btn.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)

        self.include_both_btn = tk.Button(
            p2_btn_bar, text="Include Both", font=("Segoe UI", 8, "bold"),
            bg="#2A2A3E", fg="#E0E0E0", relief=tk.FLAT, padx=4, pady=4,
            command=lambda: self.set_note_preference("BOTH"), state=tk.DISABLED
        )
        self.include_both_btn.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)

        bottom_bar = tk.Frame(self.root, bg="#1E1E2C", height=65)
        bottom_bar.pack(side=tk.BOTTOM, fill=tk.X)

        snap_btn = tk.Button(
            bottom_bar, text="📸 SNAP SLIDE  [ Press ENTER ]", font=("Segoe UI", 11, "bold"),
            bg="#00ADB5", fg="#FFFFFF", activebackground="#00D2DD", activeforeground="#FFFFFF",
            relief=tk.FLAT, padx=20, pady=8, command=self.take_snapshot
        )
        snap_btn.pack(side=tk.LEFT, padx=16, pady=10)

        db_btn = tk.Button(
            bottom_bar, text="📋 View Database Records", font=("Segoe UI", 9, "bold"),
            bg="#36364A", fg="#FFFFFF", relief=tk.FLAT, padx=12, pady=6, command=self.view_db_records
        )
        db_btn.pack(side=tk.RIGHT, padx=16, pady=10)

        self.status_bar_lbl = tk.Label(
            bottom_bar,
            text="Ready. Press ENTER to snap slide.",
            font=("Segoe UI", 9), bg="#1E1E2C", fg="#80E27E"
        )
        self.status_bar_lbl.pack(side=tk.LEFT, padx=10, pady=10)

    def _bind_keys(self):
        self.root.bind("<Return>", lambda e: self.take_snapshot())
        self.root.bind("<KP_Enter>", lambda e: self.take_snapshot())
        self.root.bind("<a>", lambda e: self.keep_snapshot())
        self.root.bind("<A>", lambda e: self.keep_snapshot())
        self.root.bind("<k>", lambda e: self.keep_snapshot())
        self.root.bind("<K>", lambda e: self.keep_snapshot())
        self.root.bind("<r>", lambda e: self.replace_snapshot())
        self.root.bind("<R>", lambda e: self.replace_snapshot())
        self.root.bind("<d>", lambda e: self.discard_snapshot())
        self.root.bind("<D>", lambda e: self.discard_snapshot())
        self.root.bind("<Delete>", lambda e: self.discard_snapshot())
        self.root.bind("<space>", lambda e: self.toggle_play_pause())
        self.root.bind("<Escape>", lambda e: self.on_close())
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def toggle_play_pause(self):
        self.is_playing = not self.is_playing
        self.play_pause_btn.configure(text="▶ Resume (Space)" if not self.is_playing else "⏸ Pause (Space)")

    def restart_video(self):
        if self.cap is not None and self.cap.isOpened():
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
            self.is_playing = True
            self.play_pause_btn.configure(text="⏸ Pause (Space)")

    def update_video_frame(self):
        if self.is_playing and self.cap is not None and self.cap.isOpened():
            ret, frame = self.cap.read()
            if not ret:
                self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                ret, frame = self.cap.read()

            if ret:
                self.current_raw_frame = frame
                self.current_frame_idx = int(self.cap.get(cv2.CAP_PROP_POS_FRAMES))

                current_sec = self.current_frame_idx / self.fps
                self.time_lbl.configure(text=f"{current_sec:.1f}s / {self.duration_secs:.1f}s  (Frame {self.current_frame_idx}/{self.total_frames})")

                canvas_w = max(400, self.video_canvas.winfo_width())
                canvas_h = max(260, self.video_canvas.winfo_height())
                h, w = frame.shape[:2]
                scale = min(canvas_w / w, canvas_h / h)
                nw, nh = max(1, int(w * scale)), max(1, int(h * scale))

                resized = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_AREA)
                rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
                img = Image.fromarray(rgb)
                imgtk = ImageTk.PhotoImage(image=img)
                self.video_canvas.imgtk = imgtk
                self.video_canvas.configure(image=imgtk)

        self.root.after(self.frame_delay_ms, self.update_video_frame)

    def take_snapshot(self):
        if self.current_raw_frame is None or self.is_processing_snapshot:
            return

        self.is_processing_snapshot = True
        raw_frame = self.current_raw_frame.copy()
        current_video_timestamp = self.current_frame_idx / self.fps
        selected_mode = self.enhancement_mode.get()
        selected_privacy = self.privacy_target.get()

        self.status_bar_lbl.configure(text="⏳ Running pipeline...", fg="#00E5FF")
        self.root.update_idletasks()

        def _bg_process():
            privacy_frame, person_count, human_mask = apply_privacy_blur(
                raw_frame,
                timestamp=current_video_timestamp,
                target_mode=selected_privacy
            )

            enhanced_frame = enhance_slide(
                privacy_frame,
                timestamp=current_video_timestamp,
                mode=selected_mode,
                human_mask=human_mask
            )

            pending_snap = self.review_mgr.process_new_capture(
                enhanced_frame,
                captured_timestamp=current_video_timestamp,
                session_id="lecture_session_01"
            )

            self._last_processed_snapshot = {
                "snapshot_id": pending_snap["snapshot_id"],
                "session_id": pending_snap["session_id"],
                "frame": enhanced_frame,
                "human_mask": human_mask
            }

            self.root.after(0, lambda: self._on_snapshot_processed(pending_snap, person_count, selected_mode, selected_privacy))

        threading.Thread(target=_bg_process, daemon=True).start()

    def _on_snapshot_processed(self, pending_snap, person_count, selected_mode, selected_privacy):
        self.is_processing_snapshot = False

        processed_frame = pending_snap["frame"]
        h, w = processed_frame.shape[:2]
        target_w = 340
        scale = target_w / w
        target_h = int(h * scale)
        preview_resized = cv2.resize(processed_frame, (target_w, target_h), interpolation=cv2.INTER_AREA)
        rgb_prev = cv2.cvtColor(preview_resized, cv2.COLOR_BGR2RGB)
        img_prev = Image.fromarray(rgb_prev)
        imgtk_prev = ImageTk.PhotoImage(image=img_prev)

        self.preview_canvas.imgtk = imgtk_prev
        self.preview_canvas.configure(image=imgtk_prev, text="")

        snap_id = pending_snap["snapshot_id"]
        seq_time = pending_snap["sequence_timestamp"]
        is_repl = pending_snap.get("is_replacement", False)

        self.mobile_time_badge.configure(text=f"{seq_time:.1f}s")
        self.keep_btn.configure(state=tk.NORMAL)
        self.replace_btn.configure(state=tk.NORMAL)
        self.discard_btn.configure(state=tk.NORMAL)
        
        self.attach_as_is_btn.configure(state=tk.DISABLED)
        self.extract_ocr_btn.configure(state=tk.DISABLED)
        self.include_both_btn.configure(state=tk.DISABLED)

        repl_msg = " [Replaces Blurry Slide]" if is_repl else ""
        self.status_bar_lbl.configure(text=f"✓ Processed: {snap_id}{repl_msg}.", fg="#69F0AE")

    def keep_snapshot(self):
        if self.review_mgr.pending_snapshot:
            snap_id = self.review_mgr.pending_snapshot["snapshot_id"]
            self.review_mgr.approve_pending(auto_triggered=False)
            self.keep_btn.configure(state=tk.DISABLED)
            self.replace_btn.configure(state=tk.DISABLED)
            self.discard_btn.configure(state=tk.DISABLED)
            
            self.attach_as_is_btn.configure(state=tk.NORMAL)
            self.extract_ocr_btn.configure(state=tk.NORMAL)
            self.include_both_btn.configure(state=tk.NORMAL)

            self.review_status_lbl.configure(text=f"✓ KEPT. Select Note Preference ➔", fg="#00E676")
            self.status_bar_lbl.configure(text=f"✓ Snapshot '{snap_id}' kept. Choose Note Inclusion Preference (Phase 2).", fg="#69F0AE")

    def replace_snapshot(self):
        if self.review_mgr.pending_snapshot:
            snap_id = self.review_mgr.pending_snapshot["snapshot_id"]
            self.review_mgr.reject_pending()
            self.keep_btn.configure(state=tk.DISABLED)
            self.replace_btn.configure(state=tk.DISABLED)
            self.discard_btn.configure(state=tk.DISABLED)
            self.attach_as_is_btn.configure(state=tk.DISABLED)
            self.extract_ocr_btn.configure(state=tk.DISABLED)
            self.include_both_btn.configure(state=tk.DISABLED)
            self.review_status_lbl.configure(text=f"🔄 REPLACE REQUESTED ({snap_id})", fg="#FF9100")
            self.status_bar_lbl.configure(text=f"Replace requested! Snap next frame to inherit timestamp {self.review_mgr.inherited_timestamp:.2f}s.", fg="#FFAB40")

    def discard_snapshot(self):
        if self.review_mgr.pending_snapshot:
            snap_id = self.review_mgr.pending_snapshot["snapshot_id"]
            self.review_mgr.discard_pending()
            
            self.keep_btn.configure(state=tk.DISABLED)
            self.replace_btn.configure(state=tk.DISABLED)
            self.discard_btn.configure(state=tk.DISABLED)
            self.attach_as_is_btn.configure(state=tk.DISABLED)
            self.extract_ocr_btn.configure(state=tk.DISABLED)
            self.include_both_btn.configure(state=tk.DISABLED)

            self.preview_canvas.configure(image='', text="📱 Ready to Capture\n\nSnapshot Discarded.")
            self.review_status_lbl.configure(text=f"🗑 DISCARDED ({snap_id})", fg="#FF5252")
            self.status_bar_lbl.configure(text=f"🗑 Snapshot '{snap_id}' discarded. No DB record written[cite: 1, 2].", fg="#FF8A80")

    def set_note_preference(self, preference):
        if self._last_processed_snapshot:
            snap_data = self._last_processed_snapshot
            snapshot_id = snap_data["snapshot_id"]
            session_id = snap_data.get("session_id", "lecture_session_01")
            enhanced_frame = snap_data.get("frame")
            human_mask = snap_data.get("human_mask")

            self.attach_as_is_btn.configure(state=tk.DISABLED)
            self.extract_ocr_btn.configure(state=tk.DISABLED)
            self.include_both_btn.configure(state=tk.DISABLED)

            if preference in ("OCR_TEXT_ONLY", "BOTH"):
                self.status_bar_lbl.configure(text=f"⏳ Running ocr.py background worker ({preference})...", fg="#00E5FF")
                from ocr import run_ocr_async
                run_ocr_async(snapshot_id, session_id, enhanced_frame, human_mask, note_inclusion_preference=preference)
                self.review_status_lbl.configure(text=f"✓ OCR Queued ({preference})", fg="#69F0AE")
            else:
                from approve_store import update_snapshot_preference_in_supabase
                update_snapshot_preference_in_supabase(snapshot_id, preference)
                self.review_status_lbl.configure(text=f"✓ Preference Set: {preference}", fg="#00E676")
                self.status_bar_lbl.configure(text=f"✓ Snapshot '{snapshot_id}' preference saved as '{preference}'.", fg="#69F0AE")

    def update_review_status_loop(self):
        if self.review_mgr.pending_snapshot is not None:
            rem = self.review_mgr.get_remaining_timeout_seconds()
            if rem > 0:
                self.review_status_lbl.configure(text=f"⏳ Pending Review: Auto-saving in {rem:.1f}s", fg="#FFD700")
            else:
                self.review_status_lbl.configure(text="✓ AUTO-PUSHED TO DB (20s Timeout)", fg="#00E676")
                self.keep_btn.configure(state=tk.DISABLED)
                self.replace_btn.configure(state=tk.DISABLED)
                self.discard_btn.configure(state=tk.DISABLED)
                self.attach_as_is_btn.configure(state=tk.NORMAL)
                self.extract_ocr_btn.configure(state=tk.NORMAL)
                self.include_both_btn.configure(state=tk.NORMAL)
        self.root.after(200, self.update_review_status_loop)

    def view_db_records(self):
        rows = get_all_snapshots()
        top = tk.Toplevel(self.root)
        top.title("Database Records (image_snapshots)")
        top.geometry("740x420")
        top.configure(bg="#1E1E2C")

        db_type = "Supabase Cloud PostgreSQL" if is_supabase_configured() else "Cloud Offline"
        tk.Label(top, text=f"Current Records in Database ({db_type}):", font=("Segoe UI", 11, "bold"), bg="#1E1E2C", fg="#FFFFFF").pack(padx=12, pady=8)

        cols = ("snapshot_id", "seq_time", "status", "is_replacement", "file_url")
        tree = ttk.Treeview(top, columns=cols, show="headings", height=12)
        tree.heading("snapshot_id", text="Snapshot ID")
        tree.heading("seq_time", text="Seq Timestamp")
        tree.heading("status", text="Status")
        tree.heading("is_replacement", text="Is Replacement")
        tree.heading("file_url", text="Output Image File / URL")

        tree.column("snapshot_id", width=140)
        tree.column("seq_time", width=100)
        tree.column("status", width=95)
        tree.column("is_replacement", width=100)
        tree.column("file_url", width=250)

        for r in rows:
            is_repl = bool(r[5])
            tree.insert("", tk.END, values=(r[0], f"{r[1]:.2f}s", r[4], is_repl, os.path.basename(r[3])))

        tree.pack(fill=tk.BOTH, expand=True, padx=12, pady=(0, 12))

    def on_close(self):
        if self.cap is not None and self.cap.isOpened():
            self.cap.release()
        self.root.destroy()

def run_lecture_mode(video_path=None):
    root = tk.Tk()
    app = LectureApp(root, video_path=video_path)
    root.mainloop()

if __name__ == "__main__":
    run_lecture_mode()
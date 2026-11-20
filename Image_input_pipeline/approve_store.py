import os
import cv2
import json
import time
import threading
import urllib.request
import urllib.parse

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------
# Environment & Supabase Configuration
# ---------------------------------------------------------

def load_env_file():
    for env_path in [
        os.path.join(ROOT_DIR, ".env"),
        os.path.join(os.getcwd(), ".env")
    ]:
        if os.path.exists(env_path):
            try:
                with open(env_path, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith("#") and "=" in line:
                            k, v = line.split("=", 1)
                            k = k.strip()
                            v = v.strip().strip("'\"")
                            if k not in os.environ:
                                os.environ[k] = v
            except Exception:
                pass

load_env_file()

def get_supabase_config():
    url = os.getenv("SUPABASE_URL", "").strip()
    # This runs on the backend server, so it uses the secret (service-role) key: the
    # public/anon key will be limited to the signed-in user's own rows by RLS.
    key = (os.getenv("SUPABASE_SECRET_KEY", "") or os.getenv("SUPABASE_KEY", "")).strip()
    if "/rest" in url:
        url = url.split("/rest")[0]
    return url.rstrip('/'), key

def is_supabase_configured():
    url, key = get_supabase_config()
    invalid_patterns = ["your-supabase", "PASTE_YOUR", "your-anon-key", "<", "YOUR_"]
    url_valid = bool(url) and not any(p in url for p in invalid_patterns)
    key_valid = bool(key) and not any(p in key for p in invalid_patterns)
    return url_valid and key_valid

def ensure_session_exists(session_id="lecture_session_01", title="Lecture Session"):
    """
    Registers the session record in public.sessions table to satisfy foreign key constraints.
    """
    url, key = get_supabase_config()
    if not is_supabase_configured():
        return False

    endpoint = f"{url}/rest/v1/sessions"
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        # ignore, not merge: an existing session must keep its title/status/owner
        # (merge reset them to "Lecture Session"/ACTIVE on every snapshot)
        "Prefer": "resolution=ignore-duplicates"
    }
    payload = {
        "session_id": session_id,
        "title": title,
        "status": "ACTIVE"
    }
    try:
        req = urllib.request.Request(endpoint, data=json.dumps(payload).encode('utf-8'), headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=5) as response:
            print(f"[Supabase SUCCESS]: Session '{session_id}' registered/verified in cloud database.")
            return True
    except Exception as e:
        print(f"[Supabase Warning]: Unable to ensure session '{session_id}' ({e}).")
        return False

# ---------------------------------------------------------
# Cloud Persistence (Supabase Only - In-Memory Byte Upload)
# ---------------------------------------------------------

def upload_image_bytes_to_supabase(frame, snapshot_id, bucket_name="lecture-slides"):
    url, key = get_supabase_config()
    if not is_supabase_configured() or frame is None:
        return None, None

    success, encoded_img = cv2.imencode('.jpg', frame)
    if not success:
        return None, None
    
    image_bytes = encoded_img.tobytes()
    filename = f"{snapshot_id}.jpg"
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "image/jpeg",
        "x-upsert": "true"
    }

    try:
        for sp in [f"public/{filename}", filename]:
            upload_url = f"{url}/storage/v1/object/{bucket_name}/{sp}"
            req = urllib.request.Request(upload_url, data=image_bytes, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=8) as response:
                    public_url = f"{url}/storage/v1/object/public/{bucket_name}/{sp}"
                    storage_path = f"{bucket_name}/{sp}"
                    print(f"[Supabase Storage SUCCESS]: Uploaded image directly to bucket '{storage_path}'!")
                    return public_url, storage_path
            except Exception:
                continue
        return None, None
    except Exception as e:
        print(f"[Supabase Storage Error]: Exception during byte upload ({e}).")
        return None, None

def save_snapshot_to_supabase(snapshot_data):
    url, key = get_supabase_config()
    if not is_supabase_configured():
        print("[Supabase Error]: Supabase credentials not configured in .env.")
        return False

    session_id = snapshot_data.get("session_id", "lecture_session_01")
    ensure_session_exists(session_id)

    endpoint = f"{url}/rest/v1/image_snapshots"

    frame = snapshot_data.get("frame")
    snapshot_id = snapshot_data["snapshot_id"]

    public_storage_url, storage_path = upload_image_bytes_to_supabase(frame, snapshot_id)
    image_url_to_save = public_storage_url if public_storage_url else ""

    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates"
    }

    ts = float(snapshot_data.get("captured_timestamp") or snapshot_data.get("sequence_timestamp") or time.time())
    payload = {
        "snapshot_id": snapshot_id,
        "session_id": snapshot_data.get("session_id", "session_demo_01"),
        "timestamp": ts,
        "sequence_timestamp": float(snapshot_data.get("sequence_timestamp", ts)),
        "captured_timestamp": float(snapshot_data.get("captured_timestamp", ts)),
        "blurred_image_url": image_url_to_save,
        "blurred_filepath": image_url_to_save,
        "storage_path": storage_path or f"lecture-slides/public/{snapshot_id}.jpg",
        "status": snapshot_data.get("status", "APPROVED"),
        "note_inclusion_preference": snapshot_data.get("note_inclusion_preference", "IMAGE_ONLY"),
        "is_replacement": bool(snapshot_data.get("is_replacement", False))
    }

    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(endpoint, data=data, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=6) as response:
            print(f"[Supabase SUCCESS]: Snapshot '{snapshot_id}' successfully pushed to Cloud Database!")
            return True
    except urllib.error.HTTPError as he:
        if he.code == 400:
            # Fallback directly to core SRS schema fields that Supabase expects
            try:
                srs_payload = {
                    "snapshot_id": snapshot_id,
                    "session_id": snapshot_data.get("session_id", "session_demo_01"),
                    "timestamp": ts,
                    "blurred_filepath": image_url_to_save,
                    "note_inclusion_preference": snapshot_data.get("note_inclusion_preference", "IMAGE_ONLY")
                }
                retry_data = json.dumps(srs_payload).encode('utf-8')
                retry_req = urllib.request.Request(endpoint, data=retry_data, headers=headers, method="POST")
                with urllib.request.urlopen(retry_req, timeout=6) as response:
                    print(f"[Supabase SUCCESS]: Snapshot '{snapshot_id}' pushed to Cloud Database (SRS schema)!")
                    return True
            except Exception:
                pass
        err_msg = ""
        try:
            err_msg = he.read().decode('utf-8')
        except Exception:
            pass
        print(f"[Database Error]: Push to cloud failed (HTTP {he.code}: {he.reason} - {err_msg}).")
        return False
    except Exception as e:
        print(f"[Database Error]: Push to cloud failed ({e}).")
        return False


def update_snapshot_preference_in_supabase(snapshot_id, preference):
    url, key = get_supabase_config()
    if not is_supabase_configured():
        return False
    
    endpoint = f"{url}/rest/v1/image_snapshots?snapshot_id=eq.{snapshot_id}"
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates"
    }
    payload = {"note_inclusion_preference": preference}
    
    try:
        req = urllib.request.Request(endpoint, data=json.dumps(payload).encode('utf-8'), headers=headers, method="PATCH")
        with urllib.request.urlopen(req, timeout=6) as response:
            print(f"[Supabase SUCCESS]: Snapshot '{snapshot_id}' preference updated to '{preference}'.")
            return True
    except Exception as e:
        print(f"[Database Error]: Failed to update preference ({e}).")
        return False

def save_snapshot_to_db(snapshot_data):
    if not save_snapshot_to_supabase(snapshot_data):
        print(f"[Database Warning]: Push to database was not successful for snapshot '{snapshot_data['snapshot_id']}'.")

def get_all_snapshots():
    if is_supabase_configured():
        url, key = get_supabase_config()
        endpoint = f"{url}/rest/v1/image_snapshots?select=*&order=sequence_timestamp.asc"
        headers = {"apikey": key, "Authorization": f"Bearer {key}"}
        req = urllib.request.Request(endpoint, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                data = json.loads(response.read().decode('utf-8'))
                return [(item['snapshot_id'], item['sequence_timestamp'], item['captured_timestamp'], item['blurred_image_url'], item['status'], item['is_replacement']) for item in data]
        except Exception as e:
            print(f"[Database Error]: Unable to fetch records from cloud database ({e}).")
    return []

# ---------------------------------------------------------
# Review Manager State Machine
# ---------------------------------------------------------

class ReviewManager:
    def __init__(self, timeout_seconds=20.0, on_status_change=None):
        self.timeout_seconds = timeout_seconds
        self.pending_snapshot = None
        self.pending_timer = None
        self.pending_start_time = None
        self.inherited_timestamp = None
        self.on_status_change = on_status_change
        self._lock = threading.Lock()

    def process_new_capture(self, processed_frame, captured_timestamp, session_id="lecture_session_01"):
        with self._lock:
            if self.pending_snapshot is not None:
                self._approve_internal(auto_triggered=True, trigger_reason="Next Picture Triggered")

            if self.inherited_timestamp is not None:
                sequence_timestamp = self.inherited_timestamp
                is_replacement = True
                self.inherited_timestamp = None
            else:
                sequence_timestamp = captured_timestamp
                is_replacement = False

            snapshot_id = f"snap_{int(sequence_timestamp * 1000)}"

            self.pending_snapshot = {
                "snapshot_id": snapshot_id,
                "session_id": session_id,
                "sequence_timestamp": sequence_timestamp,
                "captured_timestamp": captured_timestamp,
                "status": "PENDING_REVIEW",
                "is_replacement": is_replacement,
                "note_inclusion_preference": "IMAGE_ONLY",
                "frame": processed_frame
            }
            self.pending_start_time = time.time()

            if self.pending_timer is not None:
                self.pending_timer.cancel()
                self.pending_timer = None

            self.pending_timer = threading.Timer(self.timeout_seconds, self._on_timeout_auto_approve)
            self.pending_timer.daemon = True
            self.pending_timer.start()

            if self.on_status_change:
                self.on_status_change("NEW_SNAPSHOT", self.pending_snapshot)

            return self.pending_snapshot

    def get_remaining_timeout_seconds(self):
        if self.pending_snapshot is None or self.pending_start_time is None:
            return 0.0
        elapsed = time.time() - self.pending_start_time
        return max(0.0, self.timeout_seconds - elapsed)

    def approve_pending(self, auto_triggered=False, trigger_reason=None):
        with self._lock:
            return self._approve_internal(auto_triggered, trigger_reason)

    def _approve_internal(self, auto_triggered=False, trigger_reason=None):
        if self.pending_snapshot is None:
            return None

        if self.pending_timer is not None:
            self.pending_timer.cancel()
            self.pending_timer = None

        approved = self.pending_snapshot
        approved["status"] = "APPROVED"
        save_snapshot_to_db(approved)

        self.pending_snapshot = None
        self.pending_start_time = None

        if self.on_status_change:
            self.on_status_change("APPROVED", approved)
        return approved

    def reject_pending(self):
        with self._lock:
            if self.pending_snapshot is None:
                return None

            if self.pending_timer is not None:
                self.pending_timer.cancel()
                self.pending_timer = None

            self.inherited_timestamp = self.pending_snapshot["sequence_timestamp"]
            rejected = self.pending_snapshot
            rejected["status"] = "REPLACED"
            save_snapshot_to_db(rejected)

            self.pending_snapshot = None
            self.pending_start_time = None

            if self.on_status_change:
                self.on_status_change("REPLACED", rejected)
            return rejected

    def discard_pending(self):
        with self._lock:
            if self.pending_snapshot is None:
                return None

            if self.pending_timer is not None:
                self.pending_timer.cancel()
                self.pending_timer = None

            discarded = self.pending_snapshot
            print(f"\n[approve_store.py DISCARD]: Snapshot '{discarded['snapshot_id']}' discarded and dropped[cite: 1, 2]. No DB record written.")

            self.pending_snapshot = None
            self.pending_start_time = None

            if self.on_status_change:
                self.on_status_change("DISCARDED", discarded)
            return discarded

    def _on_timeout_auto_approve(self):
        self.approve_pending(auto_triggered=True, trigger_reason="20-Second Timeout Expired")
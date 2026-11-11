-- ============================================================================
-- AI Vision Glasses - MIGRATION: Add Session Management Columns
-- ============================================================================
-- Run this in Supabase Dashboard -> SQL Editor -> New Query -> Paste -> Run
--
-- This adds the new columns needed for:
--   1. User-scoped sessions (user_id)
--   2. Notes generation tracking (notes_generated)
--   3. 7-day auto-deletion (expires_at)
--   4. Session metadata (input_type, raw_content, audio_duration)
--   5. Notes satisfaction tracking (user_id, title, is_satisfactory on generated_notes)
-- ============================================================================

-- ── Step 1: Add new columns to the sessions table ──────────────────────────
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS user_id TEXT;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS notes_generated BOOLEAN DEFAULT FALSE;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS input_type TEXT DEFAULT 'Workshop Session';
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS raw_content TEXT;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS audio_duration TEXT;

-- ── Step 2: Add new columns to the generated_notes table ───────────────────
ALTER TABLE generated_notes ADD COLUMN IF NOT EXISTS user_id TEXT;
ALTER TABLE generated_notes ADD COLUMN IF NOT EXISTS title TEXT;
ALTER TABLE generated_notes ADD COLUMN IF NOT EXISTS is_satisfactory BOOLEAN;

-- ── Step 3: Enable RLS on image_snapshots (was missing) ────────────────────
ALTER TABLE image_snapshots ENABLE ROW LEVEL SECURITY;

-- ── Step 4: Create RLS policies for Flutter app REST API access ────────────
-- These allow the anon key to read/write (since we use the publishable key).
-- In production, restrict these to authenticated users only.

-- Sessions policies
CREATE POLICY "Allow anon read sessions"  ON sessions FOR SELECT USING (true);
CREATE POLICY "Allow anon insert sessions" ON sessions FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow anon update sessions" ON sessions FOR UPDATE USING (true);
CREATE POLICY "Allow anon delete sessions" ON sessions FOR DELETE USING (true);

-- Audio chunks policies
CREATE POLICY "Allow anon read chunks"  ON audio_chunks FOR SELECT USING (true);
CREATE POLICY "Allow anon insert chunks" ON audio_chunks FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow anon update chunks" ON audio_chunks FOR UPDATE USING (true);
CREATE POLICY "Allow anon delete chunks" ON audio_chunks FOR DELETE USING (true);

-- Image snapshots policies
CREATE POLICY "Allow anon read snapshots"  ON image_snapshots FOR SELECT USING (true);
CREATE POLICY "Allow anon insert snapshots" ON image_snapshots FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow anon update snapshots" ON image_snapshots FOR UPDATE USING (true);
CREATE POLICY "Allow anon delete snapshots" ON image_snapshots FOR DELETE USING (true);

-- Generated notes policies
CREATE POLICY "Allow anon read notes"  ON generated_notes FOR SELECT USING (true);
CREATE POLICY "Allow anon insert notes" ON generated_notes FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow anon update notes" ON generated_notes FOR UPDATE USING (true);
CREATE POLICY "Allow anon delete notes" ON generated_notes FOR DELETE USING (true);

-- OCR extractions policies
CREATE POLICY "Allow anon read ocr"  ON ocr_extractions FOR SELECT USING (true);
CREATE POLICY "Allow anon insert ocr" ON ocr_extractions FOR INSERT WITH CHECK (true);

-- Audio containers policies
CREATE POLICY "Allow anon read containers"  ON audio_containers FOR SELECT USING (true);
CREATE POLICY "Allow anon insert containers" ON audio_containers FOR INSERT WITH CHECK (true);

-- ── Step 5: Safeguard Generated Notes from Cascading Input Deletions ────────
-- Allow session_id to be NULL and set ON DELETE SET NULL so notes remain safe.
ALTER TABLE generated_notes ALTER COLUMN session_id DROP NOT NULL;
ALTER TABLE generated_notes DROP CONSTRAINT IF EXISTS generated_notes_session_id_fkey;
ALTER TABLE generated_notes ADD CONSTRAINT generated_notes_session_id_fkey
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE SET NULL;

-- ── Step 6: 7-Day Auto-Deletion Function for Completed Sessions ──────────────
-- Only purges raw inputs for sessions where notes have already been generated
-- and the 7-day retention window (expires_at) has passed.
CREATE OR REPLACE FUNCTION purge_expired_session_inputs()
RETURNS integer AS $$
DECLARE
    purged_count integer := 0;
    r RECORD;
BEGIN
    FOR r IN
        SELECT session_id FROM sessions
        WHERE notes_generated = TRUE
          AND expires_at IS NOT NULL
          AND expires_at < NOW()
    LOOP
        -- Delete raw inputs for this expired session
        DELETE FROM audio_chunks WHERE session_id = r.session_id;
        DELETE FROM audio_containers WHERE session_id = r.session_id;
        DELETE FROM image_snapshots WHERE session_id = r.session_id;
        -- Update session to clear raw content and expiry
        UPDATE sessions
        SET raw_content = NULL,
            expires_at = NULL
        WHERE session_id = r.session_id;
        purged_count := purged_count + 1;
    END LOOP;
    RETURN purged_count;
END;
$$ LANGUAGE plpgsql;

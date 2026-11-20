-- Per-user Row Level Security for the Flutter app's direct Supabase access.
--
-- Before: every table had "USING (true)" policies for anon + authenticated, so anyone
-- with the public (publishable) key - it is in the app and on GitHub - could read,
-- change or delete every user's sessions, transcripts, snapshots and notes.
--
-- After:
--   - anon (public key, not signed in): no access to any table.
--   - authenticated (the app sends the user's access token): only rows of sessions
--     whose sessions.user_id is the user's Supabase id (auth.uid()).
--   - The FastAPI backend connects with DATABASE_URL (postgres role) or the secret
--     key, which RLS does not restrict - backend behaviour is unchanged.
--   - Storage: nobody but the backend can upload/overwrite files any more; a user may
--     delete only their own notes/slide files. lecture-notes and lecture-slides stay
--     PUBLIC buckets for now, so the existing download links keep working.
--
-- Rollback: rls_rollback_open_policies.sql. Safe to run twice.
-- Supabase dashboard -> SQL Editor -> paste -> Run.

BEGIN;

-- 1. remove the open policies -----------------------------------------------------
DROP POLICY IF EXISTS "Allow anon delete audio_chunks" ON public.audio_chunks;
DROP POLICY IF EXISTS "Allow anon insert audio_chunks" ON public.audio_chunks;
DROP POLICY IF EXISTS "Allow anon select audio_chunks" ON public.audio_chunks;
DROP POLICY IF EXISTS "Allow anon update audio_chunks" ON public.audio_chunks;
DROP POLICY IF EXISTS "Allow anon all audio_containers" ON public.audio_containers;
DROP POLICY IF EXISTS "Allow anon all generated_notes" ON public.generated_notes;
DROP POLICY IF EXISTS "Allow anon delete snapshots" ON public.image_snapshots;
DROP POLICY IF EXISTS "Allow anon insert snapshots" ON public.image_snapshots;
DROP POLICY IF EXISTS "Allow anon read snapshots" ON public.image_snapshots;
DROP POLICY IF EXISTS "Allow anon update snapshots" ON public.image_snapshots;
DROP POLICY IF EXISTS "Allow anon delete ocr" ON public.ocr_extractions;
DROP POLICY IF EXISTS "Allow anon insert ocr" ON public.ocr_extractions;
DROP POLICY IF EXISTS "Allow anon read ocr" ON public.ocr_extractions;
DROP POLICY IF EXISTS "Allow anon update ocr" ON public.ocr_extractions;
DROP POLICY IF EXISTS "Allow anon delete sessions" ON public.sessions;
DROP POLICY IF EXISTS "Allow anon insert sessions" ON public.sessions;
DROP POLICY IF EXISTS "Allow anon read sessions" ON public.sessions;
DROP POLICY IF EXISTS "Allow anon update sessions" ON public.sessions;
DROP POLICY IF EXISTS "Allow public lecture-notes" ON storage.objects;
DROP POLICY IF EXISTS "Allow public read from lecture-slides" ON storage.objects;
DROP POLICY IF EXISTS "Allow public update in lecture-slides" ON storage.objects;
DROP POLICY IF EXISTS "Allow public upload to lecture-slides" ON storage.objects;

-- 2. "does the signed-in user own this session?" -------------------------------------
-- SECURITY DEFINER: reads sessions directly (no nested RLS check per row).
-- user_id is TEXT, auth.uid() is UUID -> compare as text. (select auth.uid()) is
-- evaluated once per query instead of once per row.
CREATE OR REPLACE FUNCTION public.owns_session(sid text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.sessions
    WHERE session_id = sid AND user_id = (SELECT auth.uid())::text
  );
$$;
REVOKE ALL ON FUNCTION public.owns_session(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owns_session(text) TO authenticated;

-- 3. tables: signed-in users, own rows only ------------------------------------------
DROP POLICY IF EXISTS "own sessions" ON public.sessions;
CREATE POLICY "own sessions" ON public.sessions FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())::text)
  WITH CHECK (user_id = (SELECT auth.uid())::text);  -- can't create/hand a session to someone else

DROP POLICY IF EXISTS "own audio_chunks" ON public.audio_chunks;
CREATE POLICY "own audio_chunks" ON public.audio_chunks FOR ALL TO authenticated
  USING (public.owns_session(session_id))
  WITH CHECK (public.owns_session(session_id));

DROP POLICY IF EXISTS "own audio_containers" ON public.audio_containers;
CREATE POLICY "own audio_containers" ON public.audio_containers FOR ALL TO authenticated
  USING (public.owns_session(session_id))
  WITH CHECK (public.owns_session(session_id));

DROP POLICY IF EXISTS "own image_snapshots" ON public.image_snapshots;
CREATE POLICY "own image_snapshots" ON public.image_snapshots FOR ALL TO authenticated
  USING (public.owns_session(session_id))
  WITH CHECK (public.owns_session(session_id));

-- OCR rows hang off a snapshot (FK snapshot_id); ownership goes through it
DROP POLICY IF EXISTS "own ocr_extractions" ON public.ocr_extractions;
CREATE POLICY "own ocr_extractions" ON public.ocr_extractions FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.image_snapshots s
                 WHERE s.snapshot_id = ocr_extractions.snapshot_id
                   AND public.owns_session(s.session_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM public.image_snapshots s
                      WHERE s.snapshot_id = ocr_extractions.snapshot_id
                        AND public.owns_session(s.session_id)));

-- notes keep their owner after the session's inputs are purged (session_id may be NULL)
DROP POLICY IF EXISTS "own generated_notes" ON public.generated_notes;
CREATE POLICY "own generated_notes" ON public.generated_notes FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())::text)
  WITH CHECK (user_id = (SELECT auth.uid())::text
              AND (session_id IS NULL OR public.owns_session(session_id)));

-- 4. storage: uploads by the backend only; users may list/delete their own files -----
-- notes files are stored as lecture-notes/<user_id>/<session_id>_notes.docx
DROP POLICY IF EXISTS "own lecture-notes files" ON storage.objects;
CREATE POLICY "own lecture-notes files" ON storage.objects FOR ALL TO authenticated
  USING (bucket_id = 'lecture-notes'
         AND (storage.foldername(name))[1] = (SELECT auth.uid())::text)
  WITH CHECK (false);  -- no uploads/overwrites from the app

-- slide files are lecture-slides/public/<snapshot_id>.jpg (or <snapshot_id>.jpg)
DROP POLICY IF EXISTS "own lecture-slides files" ON storage.objects;
CREATE POLICY "own lecture-slides files" ON storage.objects FOR ALL TO authenticated
  USING (bucket_id = 'lecture-slides'
         AND EXISTS (SELECT 1 FROM public.image_snapshots s
                     WHERE public.owns_session(s.session_id)
                       AND storage.objects.name IN ('public/' || s.snapshot_id || '.jpg',
                                                    s.snapshot_id || '.jpg')))
  WITH CHECK (false);

COMMIT;

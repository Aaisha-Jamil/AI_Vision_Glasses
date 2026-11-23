-- ROLLBACK for rls_user_policies.sql: puts back the open policies exactly as they were
-- on 2026-11-19 (dumped from pg_policies), and removes the per-user policies.
-- Run in Supabase -> SQL Editor only if the per-user policies break the app.

BEGIN;

-- remove the per-user policies
DROP POLICY IF EXISTS "own sessions" ON public.sessions;
DROP POLICY IF EXISTS "own audio_chunks" ON public.audio_chunks;
DROP POLICY IF EXISTS "own audio_containers" ON public.audio_containers;
DROP POLICY IF EXISTS "own image_snapshots" ON public.image_snapshots;
DROP POLICY IF EXISTS "own ocr_extractions" ON public.ocr_extractions;
DROP POLICY IF EXISTS "own generated_notes" ON public.generated_notes;
DROP POLICY IF EXISTS "own lecture-notes files" ON storage.objects;
DROP POLICY IF EXISTS "own lecture-slides files" ON storage.objects;
DROP FUNCTION IF EXISTS public.owns_session(text);

-- the previous open policies (anyone with the public key could read/write everything)
CREATE POLICY "Allow anon delete audio_chunks" ON public.audio_chunks AS PERMISSIVE FOR DELETE TO anon, authenticated
  USING (true);
CREATE POLICY "Allow anon insert audio_chunks" ON public.audio_chunks AS PERMISSIVE FOR INSERT TO anon, authenticated
  WITH CHECK (true);
CREATE POLICY "Allow anon select audio_chunks" ON public.audio_chunks AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);
CREATE POLICY "Allow anon update audio_chunks" ON public.audio_chunks AS PERMISSIVE FOR UPDATE TO anon, authenticated
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Allow anon all audio_containers" ON public.audio_containers AS PERMISSIVE FOR ALL TO anon, authenticated
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Allow anon all generated_notes" ON public.generated_notes AS PERMISSIVE FOR ALL TO anon, authenticated
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Allow anon delete snapshots" ON public.image_snapshots AS PERMISSIVE FOR DELETE TO anon, authenticated
  USING (true);
CREATE POLICY "Allow anon insert snapshots" ON public.image_snapshots AS PERMISSIVE FOR INSERT TO anon, authenticated
  WITH CHECK (true);
CREATE POLICY "Allow anon read snapshots" ON public.image_snapshots AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);
CREATE POLICY "Allow anon update snapshots" ON public.image_snapshots AS PERMISSIVE FOR UPDATE TO anon, authenticated
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Allow anon delete ocr" ON public.ocr_extractions AS PERMISSIVE FOR DELETE TO anon, authenticated
  USING (true);
CREATE POLICY "Allow anon insert ocr" ON public.ocr_extractions AS PERMISSIVE FOR INSERT TO anon, authenticated
  WITH CHECK (true);
CREATE POLICY "Allow anon read ocr" ON public.ocr_extractions AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);
CREATE POLICY "Allow anon update ocr" ON public.ocr_extractions AS PERMISSIVE FOR UPDATE TO anon, authenticated
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Allow anon delete sessions" ON public.sessions AS PERMISSIVE FOR DELETE TO anon, authenticated
  USING (true);
CREATE POLICY "Allow anon insert sessions" ON public.sessions AS PERMISSIVE FOR INSERT TO anon, authenticated
  WITH CHECK (true);
CREATE POLICY "Allow anon read sessions" ON public.sessions AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);
CREATE POLICY "Allow anon update sessions" ON public.sessions AS PERMISSIVE FOR UPDATE TO anon, authenticated
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Allow public lecture-notes" ON storage.objects AS PERMISSIVE FOR ALL TO anon, authenticated
  USING ((bucket_id = 'lecture-notes'::text))
  WITH CHECK ((bucket_id = 'lecture-notes'::text));
CREATE POLICY "Allow public read from lecture-slides" ON storage.objects AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING ((bucket_id = 'lecture-slides'::text));
CREATE POLICY "Allow public update in lecture-slides" ON storage.objects AS PERMISSIVE FOR UPDATE TO anon, authenticated
  USING ((bucket_id = 'lecture-slides'::text));
CREATE POLICY "Allow public upload to lecture-slides" ON storage.objects AS PERMISSIVE FOR INSERT TO anon, authenticated
  WITH CHECK ((bucket_id = 'lecture-slides'::text));

COMMIT;

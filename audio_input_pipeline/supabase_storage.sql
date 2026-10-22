-- Supabase Storage bucket for lecture audio (see storage.py).
-- Supabase dashboard -> SQL Editor -> paste this file -> Run. Supabase only: the
-- storage schema does not exist on plain Postgres.
--
-- Private bucket (public = false) and no policies on storage.objects: only the
-- backend's secret key can read or write. Files are <session_id>/chunk_00012.flac,
-- ~100-250 KB each, so a 10 MB per-file limit is plenty.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lecture-audio', 'lecture-audio', false, 10485760, ARRAY['audio/flac'])
ON CONFLICT (id) DO NOTHING;

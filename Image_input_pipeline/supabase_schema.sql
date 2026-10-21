-- ==============================================================================
-- Supabase Schema: Privacy-Preserving Lecture Synthesis Subsystem
-- Run directly in Supabase Dashboard -> SQL Editor
-- ==============================================================================

-- 1. Sessions Table
CREATE TABLE IF NOT EXISTS public.sessions (
    session_id VARCHAR(100) PRIMARY KEY,
    title VARCHAR(255) NOT NULL DEFAULT 'Lecture Session',
    start_time TIMESTAMPTZ DEFAULT NOW(),
    end_time TIMESTAMPTZ,
    status VARCHAR(50) DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PROCESSING', 'COMPLETED'))
);

-- 2. Image Snapshots Table
CREATE TABLE IF NOT EXISTS public.image_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_id VARCHAR(100) UNIQUE NOT NULL,
    session_id VARCHAR(100) NOT NULL REFERENCES public.sessions(session_id) ON DELETE CASCADE,
    sequence_timestamp DOUBLE PRECISION NOT NULL,
    captured_timestamp DOUBLE PRECISION NOT NULL,
    blurred_image_url TEXT NOT NULL,
    storage_path TEXT NOT NULL,
    status VARCHAR(50) DEFAULT 'APPROVED' CHECK (status IN ('PENDING_REVIEW', 'APPROVED', 'REPLACED', 'DISCARDED')),
    note_inclusion_preference VARCHAR(50) DEFAULT 'IMAGE_ONLY' CHECK (note_inclusion_preference IN ('IMAGE_ONLY', 'OCR_TEXT_ONLY', 'BOTH')),
    is_replacement BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. OCR Extractions Table
CREATE TABLE IF NOT EXISTS public.ocr_extractions (
    ocr_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_id VARCHAR(100) NOT NULL REFERENCES public.image_snapshots(snapshot_id) ON DELETE CASCADE,
    session_id VARCHAR(100) NOT NULL REFERENCES public.sessions(session_id) ON DELETE CASCADE,
    extracted_text TEXT NOT NULL,
    confidence_score DOUBLE PRECISION DEFAULT 0.0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Enable Row Level Security (RLS) & Policies
ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.image_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ocr_extractions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow anon read sessions" ON public.sessions FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Allow anon insert sessions" ON public.sessions FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY "Allow anon update sessions" ON public.sessions FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Allow anon read snapshots" ON public.image_snapshots FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Allow anon insert snapshots" ON public.image_snapshots FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY "Allow anon update snapshots" ON public.image_snapshots FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Allow anon read ocr" ON public.ocr_extractions FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Allow anon insert ocr" ON public.ocr_extractions FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY "Allow anon update ocr" ON public.ocr_extractions FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- 5. Public Storage Bucket for Lecture Slides
INSERT INTO storage.buckets (id, name, public)
VALUES ('lecture-slides', 'lecture-slides', true)
ON CONFLICT (id) DO UPDATE SET public = true;

CREATE POLICY "Allow public upload to lecture-slides" ON storage.objects FOR INSERT TO anon, authenticated WITH CHECK (bucket_id = 'lecture-slides');
CREATE POLICY "Allow public read from lecture-slides" ON storage.objects FOR SELECT TO anon, authenticated USING (bucket_id = 'lecture-slides');
CREATE POLICY "Allow public update in lecture-slides" ON storage.objects FOR UPDATE TO anon, authenticated USING (bucket_id = 'lecture-slides');
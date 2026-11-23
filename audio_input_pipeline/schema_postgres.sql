-- AI Vision Notes - database schema: PostgreSQL + pgvector on Supabase.
-- SRS section 7.2 tables + audio-pipeline additions + containers.
--
-- This file is the single source of truth: the app does not create tables itself, and on
-- startup db.init_db() parses this file and checks every table/column exists. Change a
-- column here first, then run the change (ALTER TABLE) on Supabase.
--   Supabase dashboard -> SQL Editor -> paste this file -> Run.
-- Plain Postgres also works (pgvector needed, e.g. Docker image pgvector/pgvector:pg18):
--   psql -d ai_vision_notes -f schema_postgres.sql
--
-- Supabase notes:
--   - pgvector goes into the "extensions" schema (Supabase convention). Types and index
--     operators are left unqualified (vector, vector_cosine_ops): Supabase's search_path
--     includes "extensions", so this also works if vector was already enabled in public.
--   - RLS is enabled on every table with no policies: the anon/authenticated API keys
--     can't read or write anything. The FastAPI backend connects with the postgres
--     connection string (table owner), which RLS does not restrict. If the Flutter app
--     ever reads Supabase directly, add policies for that.
--
-- Types: embeddings are vector(384) (MiniLM); chunk/snapshot times are epoch seconds
-- (DOUBLE PRECISION, server clock, so audio and images align); session times TIMESTAMPTZ.
-- IDs are TEXT (the app generates uuid4 strings and uses session_id as a folder name).

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    user_id TEXT,                          -- owner of the session (email or uid)
    title TEXT NOT NULL,
    start_time TIMESTAMPTZ DEFAULT now(),
    end_time TIMESTAMPTZ,
    status TEXT CHECK (status IN ('ACTIVE', 'PROCESSING', 'COMPLETED')) DEFAULT 'ACTIVE',
    -- session management additions
    notes_generated BOOLEAN DEFAULT FALSE, -- whether notes have been generated for this session
    expires_at TIMESTAMPTZ,                -- 7-day auto-delete window (NULL = no expiry set yet)
    input_type TEXT DEFAULT 'Workshop Session', -- 'Workshop Session', 'Audio', 'Image', etc.
    raw_content TEXT,                      -- serialized session content for notes generation
    audio_duration TEXT,                   -- human-readable duration string (e.g. '05:32')
    -- audio-pipeline additions
    seminar_topic TEXT,
    topic_centroid_vector vector(384),
    flush_count INTEGER DEFAULT 0,
    topic_match DOUBLE PRECISION,       -- last flush: batch centroid vs topic vector
    topic_guard BOOLEAN DEFAULT FALSE   -- topic guard fired (session looked off-topic)
);

-- 10-minute parent units that group chunks (timeline/heatmap, topic drift, RAG).
-- Built when the session stops, after noise scoring.
CREATE TABLE IF NOT EXISTS audio_containers (
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    container_index INTEGER NOT NULL,
    start_timestamp DOUBLE PRECISION NOT NULL,  -- first chunk start (epoch s)
    end_timestamp DOUBLE PRECISION NOT NULL,    -- last chunk end (epoch s)
    chunk_count INTEGER NOT NULL,
    noise_count INTEGER NOT NULL,
    mixed_count INTEGER NOT NULL,
    centroid_embedding vector(384),             -- mean of the clean chunk embeddings
    topic_similarity DOUBLE PRECISION,          -- centroid vs session topic vector
    PRIMARY KEY (session_id, container_index)
);

CREATE TABLE IF NOT EXISTS audio_chunks (
    chunk_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    start_timestamp DOUBLE PRECISION NOT NULL,
    end_timestamp DOUBLE PRECISION NOT NULL,
    audio_filepath TEXT NOT NULL,
    transcript_text TEXT,
    similarity_score DOUBLE PRECISION,
    is_flagged_noise BOOLEAN DEFAULT FALSE,
    user_override_status TEXT CHECK (user_override_status IN ('PENDING', 'KEEP', 'DISMISS'))
        DEFAULT 'PENDING',
    -- audio-pipeline additions
    embedding vector(384),
    chunk_index INTEGER,
    stt_provider TEXT,
    is_mixed BOOLEAN DEFAULT FALSE,
    noise_reason TEXT,
    off_topic_text TEXT,  -- MIXED: off-topic sentence(s), one per line, cut from the notes
    edited_text TEXT,     -- user's corrected text (NULL = not edited); transcript_text stays original
    -- container additions. Chunks are inserted live, containers only on stop, so this
    -- is a plain column (no FK to audio_containers).
    container_index INTEGER
);
CREATE INDEX IF NOT EXISTS idx_chunks_session ON audio_chunks (session_id, start_timestamp);

-- Similarity search for RAG (cosine distance, <=> operator). Noise scoring does not
-- need these: it compares one lecture's chunks against one topic vector in numpy.
CREATE INDEX IF NOT EXISTS idx_chunks_embedding
    ON audio_chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_containers_embedding
    ON audio_containers USING hnsw (centroid_embedding vector_cosine_ops);

CREATE TABLE IF NOT EXISTS image_snapshots (
    snapshot_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    timestamp DOUBLE PRECISION NOT NULL,
    raw_filepath TEXT,
    blurred_filepath TEXT NOT NULL,
    note_inclusion_preference TEXT CHECK (note_inclusion_preference IN ('IMAGE_ONLY',
        'OCR_TEXT_ONLY', 'BOTH')) DEFAULT 'BOTH'
);

CREATE TABLE IF NOT EXISTS ocr_extractions (
    ocr_id TEXT PRIMARY KEY,
    snapshot_id TEXT NOT NULL REFERENCES image_snapshots(snapshot_id) ON DELETE CASCADE,
    extracted_text TEXT NOT NULL,
    confidence_score DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS generated_notes (
    note_id TEXT PRIMARY KEY,
    session_id TEXT REFERENCES sessions(session_id) ON DELETE SET NULL,
    user_id TEXT,                           -- owner who generated the note
    title TEXT,                             -- note title
    markdown_content TEXT NOT NULL,
    docx_filepath TEXT,
    is_satisfactory BOOLEAN,               -- user's satisfaction feedback
    created_at TIMESTAMPTZ DEFAULT now()
);

-- App feedback (feedback/ routes). Written only by the backend, owner taken from the token.
-- session_id / note_id have no foreign keys on purpose: feedback must survive the 7-day
-- input purge and the 2-notes quota, and the app may refer to a session only it has.
CREATE TABLE IF NOT EXISTS feedback (
    feedback_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,                 -- Supabase Auth user id (from the access token)
    session_id TEXT,
    note_id TEXT,
    rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    category TEXT NOT NULL,
    comments TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_feedback_user ON feedback (user_id, created_at DESC);

-- Supabase: block the public API keys (see the notes at the top).
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE audio_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE audio_containers ENABLE ROW LEVEL SECURITY;
ALTER TABLE image_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE ocr_extractions ENABLE ROW LEVEL SECURITY;
ALTER TABLE generated_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE feedback ENABLE ROW LEVEL SECURITY;

"""
Persistence: PostgreSQL + pgvector on Supabase (DATABASE_URL in .env, required).

The app does not create tables: the DB owner runs schema_postgres.sql once (Supabase SQL
Editor). On startup init_db() checks that every table and column in that file exists,
so the file is the single source of truth for the schema.

Schema = SRS section 7.2 DDL (all tables, so teammates' modules can use the same DB)
plus the audio-pipeline additions:
    sessions.seminar_topic, sessions.topic_centroid_vector, sessions.flush_count
    sessions.topic_match, sessions.topic_guard: last flush's batch-centroid-vs-topic
        similarity, and whether the topic guard fired in any flush (semantic.py)
    audio_chunks.embedding, audio_chunks.chunk_index, audio_chunks.stt_provider
    audio_chunks.is_mixed, audio_chunks.noise_reason (MIXED from llm or sentence split)
    audio_chunks.off_topic_text: the off-topic sentence(s) of a MIXED chunk, one per
        line, cut from the clean transcript unless the user KEEPs the chunk (sentence
        split only; llm mode gives no sentences, so its MIXED chunks stay whole)
    audio_chunks.edited_text: the user's corrected text (proposal 2.5 "Edit"); NULL =
        not edited. transcript_text always keeps the original STT output.
    audio_containers + audio_chunks.container_index: 10-minute parent units that group
        chunks (timeline/heatmap, topic drift, RAG). Embeddings and noise flags stay
        per chunk: MiniLM reads only 256 tokens, a 10-min container is ~1900.

user_override_status keeps the SRS values ('PENDING', 'KEEP', 'DISMISS'):
    PENDING  not scored yet (live), or flagged NOISE/MIXED and waiting for review
    KEEP     not flagged (set by the flush), or the user kept / edited it
    DISMISS  the user dismissed it
    (KEEP + is_flagged_noise = the user overruled a flag: useful for evaluation)
The API also accepts 'KEPT' / 'DELETED' and maps them (see OVERRIDE_ALIASES).
Vectors are pgvector vector(384); to_vec()/from_vec() convert to/from float32 numpy.
Rows are dicts (row["col"], dict(row)).
"""

import os
import re
import threading
from contextlib import contextmanager
from pathlib import Path

import numpy as np

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
SCHEMA_FILE = Path(__file__).with_name("schema_postgres.sql")

OVERRIDE_ALIASES = {
    "PENDING": "PENDING",
    "KEEP": "KEEP", "KEPT": "KEEP",
    "DISMISS": "DISMISS", "DELETE": "DISMISS", "DELETED": "DISMISS",
}

# A chunk belongs in the notes unless it's flagged noise, or the user dismissed it.
# (Blueprint: WHERE (is_noise = FALSE AND user_override != 'DELETED') OR user_override = 'KEPT')
CLEAN_FILTER = ("((is_flagged_noise = FALSE AND user_override_status != 'DISMISS') "
                "OR user_override_status = 'KEEP')")
# The Red-Box review list: whole-chunk noise and MIXED chunks.
REVIEW_FILTER = "(is_flagged_noise = TRUE OR is_mixed = TRUE)"

CHUNK_COLUMNS = ("chunk_id, session_id, chunk_index, start_timestamp, end_timestamp, "
                 "audio_filepath, transcript_text, stt_provider, similarity_score, "
                 "is_flagged_noise, user_override_status, is_mixed, noise_reason, "
                 "off_topic_text, edited_text, container_index")


def off_topic_sentences(row) -> list[str]:
    return row["off_topic_text"].split("\n") if row["off_topic_text"] else []


def clean_text(row) -> str:
    """A CLEAN_FILTER row's text as it goes into the notes: the user's edit if there is
    one, else a MIXED chunk the user has not KEPT loses its off-topic sentence(s);
    any other chunk stays whole."""
    if row["edited_text"]:
        return row["edited_text"]
    text = row["transcript_text"] or ""
    if row["user_override_status"] == "KEEP":
        return text
    for sentence in off_topic_sentences(row):
        text = text.replace(sentence, " ")
    return " ".join(text.split())


_pool = None
_pool_lock = threading.Lock()


def _get_pool():
    """Connection pool, opened on first use. Pooled because Supabase is a remote server:
    a new TLS connection per query would add ~100+ ms each time."""
    global _pool
    with _pool_lock:
        if _pool is None:
            if not DATABASE_URL:
                raise RuntimeError("DATABASE_URL is not set - add the Supabase connection "
                                   "string to .env (see .env.example)")
            from pgvector.psycopg import register_vector
            from psycopg.rows import dict_row
            from psycopg_pool import ConnectionPool

            # prepare_threshold=None: no server-side prepared statements, so the Supabase
            # transaction pooler (port 6543) works as well as the session pooler (5432).
            # autocommit: one round trip per query instead of BEGIN + query + COMMIT
            # (~65 vs ~200 ms to Mumbai); multi-statement writes use conn.transaction().
            _pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=5, open=True,
                                   configure=register_vector,  # vector <-> numpy
                                   kwargs={"row_factory": dict_row, "prepare_threshold": None,
                                           "autocommit": True})
    return _pool


@contextmanager
def connect():
    """A pooled connection per operation (safe from asyncio.to_thread workers)."""
    with _get_pool().connection() as conn:
        yield conn


def close():
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


def _expected_columns() -> dict[str, set[str]]:
    """Table -> columns, parsed from schema_postgres.sql (column lines: 4-space indent,
    lowercase name, then a type; constraints are UPPERCASE, CHECK continuations quoted)."""
    sql = re.sub(r"--[^\n]*", "", SCHEMA_FILE.read_text(encoding="utf-8"))
    return {table: set(re.findall(r"^ {4}([a-z_]+) +[A-Za-z]", body, re.M))
            for table, body in re.findall(r"CREATE TABLE IF NOT EXISTS (\w+) \((.*?)\n\);",
                                          sql, re.S)}


def init_db():
    """Fail fast with a clear message if the DB is missing a table or column."""
    with connect() as conn:
        rows = conn.execute("SELECT table_name, column_name FROM information_schema.columns "
                            "WHERE table_schema = 'public'").fetchall()
    have: dict[str, set[str]] = {}
    for r in rows:
        have.setdefault(r["table_name"], set()).add(r["column_name"])
    missing = [f"{t}.{c}" for t, cols in _expected_columns().items()
               for c in sorted(cols - have.get(t, set()))]
    if missing:
        raise RuntimeError(f"Database is missing {len(missing)} column(s): "
                           f"{', '.join(missing)} - run schema_postgres.sql on it")


def to_vec(vec: np.ndarray) -> np.ndarray:
    """Value for a vector(384) column."""
    return np.asarray(vec, dtype=np.float32)


def from_vec(value) -> np.ndarray:
    """vector column value -> float32 numpy array (pgvector returns a numpy array or,
    from pgvector-python 0.4, a pgvector.Vector)."""
    if hasattr(value, "to_numpy"):
        value = value.to_numpy()
    return np.asarray(value, dtype=np.float32)


# ------------------------------------------------------------------ sessions

def create_session(session_id: str, title: str, seminar_topic: str, seed_vector: np.ndarray):
    with connect() as conn:
        conn.execute(
            "INSERT INTO sessions (session_id, title, seminar_topic, topic_centroid_vector) "
            "VALUES (%s, %s, %s, %s)",
            (session_id, title, seminar_topic, to_vec(seed_vector)),
        )


def get_session(session_id: str) -> dict | None:
    with connect() as conn:
        return conn.execute("SELECT * FROM sessions WHERE session_id = %s",
                            (session_id,)).fetchone()


def update_topic(session_id: str, vector: np.ndarray, topic_match: float | None = None,
                 topic_guard: bool = False):
    """After a flush: new topic vector, flush count, and the topic-guard record
    (topic_guard stays TRUE once any flush fired it)."""
    with connect() as conn:
        conn.execute(
            "UPDATE sessions SET topic_centroid_vector = %s, flush_count = flush_count + 1, "
            "topic_match = %s, topic_guard = (topic_guard OR %s) WHERE session_id = %s",
            (to_vec(vector), topic_match, bool(topic_guard), session_id),
        )


def end_session(session_id: str):
    with connect() as conn:
        conn.execute(
            "UPDATE sessions SET end_time = now(), status = 'COMPLETED' WHERE session_id = %s",
            (session_id,),
        )


# -------------------------------------------------------------- audio_chunks

def insert_chunk(session_id: str, rec: dict):
    """Called right after transcription (SRS 5.2 incremental logging).
    Similarity/noise fields are filled in later by the flush."""
    with connect() as conn:
        conn.execute(
            "INSERT INTO audio_chunks (chunk_id, session_id, chunk_index, start_timestamp, "
            "end_timestamp, audio_filepath, transcript_text, stt_provider, container_index) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            (rec["chunk_id"], session_id, rec["index"], rec["timestamp"],
             rec["timestamp"] + rec["end_offset"] - rec["start_offset"],
             rec["audio_filepath"], rec["transcript"], rec["provider"],
             rec["container_index"]),
        )


def set_audio_path(chunk_id: str, path: str):
    """After a Supabase Storage upload: supabase://<bucket>/<session_id>/<chunk>.flac"""
    with connect() as conn:
        conn.execute("UPDATE audio_chunks SET audio_filepath = %s WHERE chunk_id = %s",
                     (path, chunk_id))


def save_scores(rows: list[tuple[str, np.ndarray, float, bool, bool, str | None, list[str]]]):
    """rows: (chunk_id, embedding, similarity, is_noise, is_mixed, noise_reason, off_topic)
    Unflagged chunks become KEEP; flagged ones stay PENDING for review. A decision the
    user already made (not PENDING) is never overwritten."""
    with connect() as conn, conn.transaction():  # a flush is saved whole or not at all
        conn.cursor().executemany(
            "UPDATE audio_chunks SET embedding = %s, similarity_score = %s, "
            "is_flagged_noise = %s, is_mixed = %s, noise_reason = %s, off_topic_text = %s, "
            "user_override_status = CASE WHEN user_override_status = 'PENDING' AND NOT %s "
            "THEN 'KEEP' ELSE user_override_status END "
            "WHERE chunk_id = %s",
            [(to_vec(e), float(s), bool(n), bool(m), r, "\n".join(o) or None,
              bool(n or m), cid)
             for cid, e, s, n, m, r, o in rows],
        )


# ----------------------------------------------------------- audio_containers

def scored_chunks(session_id: str) -> list[dict]:
    """Chunks that went through a flush, with what a container summary needs."""
    with connect() as conn:
        return conn.execute(
            "SELECT container_index, start_timestamp, end_timestamp, embedding, "
            "is_flagged_noise, is_mixed FROM audio_chunks "
            "WHERE session_id = %s AND embedding IS NOT NULL AND container_index IS NOT NULL "
            "ORDER BY start_timestamp",
            (session_id,),
        ).fetchall()


def save_containers(session_id: str, rows: list[dict]):
    """Replace the session's containers (a rebuild after a re-score gives the same keys)."""
    with connect() as conn, conn.transaction():  # never leave the session with no containers
        conn.execute("DELETE FROM audio_containers WHERE session_id = %s", (session_id,))
        conn.cursor().executemany(
            "INSERT INTO audio_containers (session_id, container_index, start_timestamp, "
            "end_timestamp, chunk_count, noise_count, mixed_count, centroid_embedding, "
            "topic_similarity) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            [(session_id, r["container_index"], r["start_timestamp"], r["end_timestamp"],
              r["chunk_count"], r["noise_count"], r["mixed_count"],
              None if r["centroid"] is None else to_vec(r["centroid"]),
              r["topic_similarity"]) for r in rows],
        )


def list_containers(session_id: str) -> list[dict]:
    with connect() as conn:
        return conn.execute(
            "SELECT container_index, start_timestamp, end_timestamp, chunk_count, "
            "noise_count, mixed_count, topic_similarity FROM audio_containers "
            "WHERE session_id = %s ORDER BY container_index",
            (session_id,),
        ).fetchall()


def _update_returning(sql: str, params: tuple) -> dict | None:
    """UPDATE ... RETURNING the chunk: one statement, one round trip."""
    with connect() as conn:
        return conn.execute(f"{sql} RETURNING {CHUNK_COLUMNS}", params).fetchone()


def set_override(chunk_id: str, status: str) -> dict | None:
    return _update_returning(
        "UPDATE audio_chunks SET user_override_status = %s WHERE chunk_id = %s",
        (status, chunk_id))


def set_edited_text(chunk_id: str, text: str | None) -> dict | None:
    """Save the user's corrected text and KEEP the chunk (an edit means "use my
    version in the notes"). text=None undoes the edit: original transcript and the
    flush's default again (flagged -> PENDING for review, unflagged -> KEEP)."""
    if text is None:
        return _update_returning(
            "UPDATE audio_chunks SET edited_text = NULL, user_override_status = CASE "
            "WHEN is_flagged_noise OR is_mixed THEN 'PENDING' ELSE 'KEEP' END "
            "WHERE chunk_id = %s", (chunk_id,))
    return _update_returning("UPDATE audio_chunks SET edited_text = %s, "
                             "user_override_status = 'KEEP' WHERE chunk_id = %s",
                             (text, chunk_id))


def list_chunks(session_id: str, clean_only: bool = False,
                review_only: bool = False) -> list[dict]:
    where = "session_id = %s"
    if clean_only:
        where += f" AND {CLEAN_FILTER}"
    if review_only:
        where += f" AND {REVIEW_FILTER}"
    with connect() as conn:
        return conn.execute(
            f"SELECT {CHUNK_COLUMNS} FROM audio_chunks WHERE {where} ORDER BY start_timestamp",
            (session_id,),
        ).fetchall()

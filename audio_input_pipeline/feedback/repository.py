from abc import ABC, abstractmethod
from fastapi import HTTPException, status
from .schemas import FeedbackCreate, FeedbackRecord

def _not_configured() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail={
            "code": "integration_not_configured",
            "message": (
                "Feedback storage is not configured. "
                "Map this repository to the existing "
                "Supabase feedback table."
            ),
        },
    )

class FeedbackRepository(ABC):
    @abstractmethod
    async def create(self, user_id: str, payload: FeedbackCreate) -> FeedbackRecord:
        raise NotImplementedError

    @abstractmethod
    async def list_for_user(self, user_id: str, limit: int = 50) -> list[FeedbackRecord]:
        raise NotImplementedError

class SupabaseFeedbackRepositoryNotConfigured(FeedbackRepository):
    async def create(self, user_id: str, payload: FeedbackCreate) -> FeedbackRecord:
        raise _not_configured()

    async def list_for_user(self, user_id: str, limit: int = 50) -> list[FeedbackRecord]:
        raise _not_configured()


_COLUMNS = "feedback_id, user_id, session_id, note_id, rating, category, comments, created_at"


def _record(row) -> FeedbackRecord:
    return FeedbackRecord(id=row["feedback_id"], user_id=row["user_id"],
                          session_id=row["session_id"], note_id=row["note_id"],
                          rating=row["rating"], category=row["category"],
                          comments=row["comments"], created_at=row["created_at"])


class PostgresFeedbackRepository(FeedbackRepository):
    """The `feedback` table (schema_postgres.sql) through db.py's Supabase Postgres pool."""

    @staticmethod
    def _db():
        import db  # audio_input_pipeline/db.py
        if db.is_memory_mode():
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail={"code": "database_unavailable",
                        "message": "Feedback can't be saved right now: the database is not connected."},
            )
        return db

    async def create(self, user_id: str, payload: FeedbackCreate) -> FeedbackRecord:
        import asyncio
        import uuid
        db = self._db()

        def insert():
            with db.connect() as conn:
                return conn.execute(
                    f"INSERT INTO feedback ({_COLUMNS}) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, now()) RETURNING " + _COLUMNS,
                    (str(uuid.uuid4()), user_id, payload.session_id, payload.note_id,
                     payload.rating, payload.category.strip(),
                     (payload.comments or "").strip() or None),
                ).fetchone()

        return _record(await asyncio.to_thread(insert))

    async def list_for_user(self, user_id: str, limit: int = 50) -> list[FeedbackRecord]:
        import asyncio
        db = self._db()

        def select():
            with db.connect() as conn:
                return conn.execute(
                    f"SELECT {_COLUMNS} FROM feedback WHERE user_id = %s "
                    "ORDER BY created_at DESC LIMIT %s", (user_id, limit)).fetchall()

        return [_record(r) for r in await asyncio.to_thread(select)]
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
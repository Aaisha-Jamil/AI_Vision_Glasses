from fastapi import APIRouter, Depends, Query
from authentication.dependencies import get_current_user
from authentication.schemas import AuthenticatedUser
from .dependencies import get_feedback_repository
from .repository import FeedbackRepository
from .schemas import FeedbackCreate, FeedbackListResponse, FeedbackRecord

router = APIRouter(prefix="/api/v1/feedback", tags=["Feedback"])

@router.post("", response_model=FeedbackRecord, status_code=201)
async def submit_feedback(
    payload: FeedbackCreate,
    user: AuthenticatedUser = Depends(get_current_user),
    repository: FeedbackRepository = Depends(get_feedback_repository),
):
    return await repository.create(user.id, payload)

@router.get("", response_model=FeedbackListResponse)
async def get_my_feedback(
    limit: int = Query(default=50, ge=1, le=100),
    user: AuthenticatedUser = Depends(get_current_user),
    repository: FeedbackRepository = Depends(get_feedback_repository),
):
    items = await repository.list_for_user(user.id, limit=limit)
    return FeedbackListResponse(items=items)
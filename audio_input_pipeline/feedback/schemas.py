# Defines request and response models for feedback APIs.
# These models validate feedback data before it reaches the database layer.

from datetime import datetime
from pydantic import BaseModel, Field


class FeedbackCreate(BaseModel):
    session_id: str | None = Field(
        default=None,
        max_length=160
    )

    note_id: str | None = Field(
        default=None,
        max_length=160
    )

    rating: int = Field(
        ge=1,
        le=5
    )

    category: str = Field(
        min_length=2,
        max_length=40
    )

    comments: str | None = Field(
        default=None,
        max_length=4000
    )


class FeedbackRecord(BaseModel):
    id: str
    user_id: str

    session_id: str | None = None
    note_id: str | None = None

    rating: int
    category: str
    comments: str | None = None

    created_at: datetime


class FeedbackListResponse(BaseModel):
    items: list[FeedbackRecord]
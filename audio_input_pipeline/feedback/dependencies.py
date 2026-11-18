# Provides the feedback repository to API endpoints.
# The Supabase team can inject its actual repository without changing the routes.

from .repository import (
    FeedbackRepository,
    SupabaseFeedbackRepositoryNotConfigured,
)


_feedback_repository: FeedbackRepository = (
    SupabaseFeedbackRepositoryNotConfigured()
)


def set_feedback_repository(
    repository: FeedbackRepository
) -> None:
    """
    Configure the actual feedback repository.

    This will be called when the Supabase integration is completed.
    """

    global _feedback_repository

    _feedback_repository = repository


def get_feedback_repository() -> FeedbackRepository:
    return _feedback_repository
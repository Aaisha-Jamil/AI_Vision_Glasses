"""Supabase-ready authentication provider contract and safe unconfigured implementation."""

from abc import ABC, abstractmethod
from fastapi import HTTPException, status
from .schemas import AuthenticatedUser


def integration_unavailable() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail={
            "code": "integration_not_configured",
            "message": "Authentication provider is not configured. Connect the existing Supabase Auth project.",
        },
    )


class AuthProvider(ABC):
    @abstractmethod
    async def register(self, email: str, password: str, full_name: str) -> dict:
        """Register through the real identity provider and return access_token + user."""
        raise NotImplementedError

    @abstractmethod
    async def login(self, email: str, password: str) -> dict:
        """Verify credentials through the real identity provider."""
        raise NotImplementedError

    @abstractmethod
    async def verify_access_token(self, access_token: str) -> AuthenticatedUser:
        """Cryptographically verify token and return its trusted user identity."""
        raise NotImplementedError

    @abstractmethod
    async def logout(self, access_token: str) -> None:
        """Revoke/terminate the provider session when supported."""
        raise NotImplementedError


class SupabaseAuthProviderNotConfigured(AuthProvider):
    """Default adapter: fails closed until the team connects Supabase Auth."""

    async def register(self, email: str, password: str, full_name: str) -> dict:
        raise integration_unavailable()

    async def login(self, email: str, password: str) -> dict:
        raise integration_unavailable()

    async def verify_access_token(self, access_token: str) -> AuthenticatedUser:
        raise integration_unavailable()

    async def logout(self, access_token: str) -> None:
        raise integration_unavailable()

"""Dependency injection and role-based authorization for protected API routes."""

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from .providers import AuthProvider, SupabaseAuthProviderNotConfigured
from .schemas import AuthenticatedUser

_bearer = HTTPBearer(auto_error=False)
_auth_provider: AuthProvider = SupabaseAuthProviderNotConfigured()


def set_auth_provider(provider: AuthProvider) -> None:
    """Call during app startup after implementing/configuring the Supabase adapter."""
    global _auth_provider
    _auth_provider = provider


def get_auth_provider() -> AuthProvider:
    return _auth_provider


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    provider: AuthProvider = Depends(get_auth_provider),
) -> AuthenticatedUser:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Bearer access token is required.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    try:
        return await provider.verify_access_token(credentials.credentials)
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired access token.",
            headers={"WWW-Authenticate": "Bearer"},
        )


def require_roles(*allowed_roles: str):
    """Use as Depends(require_roles('admin')) on admin-only endpoints."""
    async def role_guard(user: AuthenticatedUser = Depends(get_current_user)) -> AuthenticatedUser:
        if user.role not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You do not have permission to perform this action.",
            )
        return user
    return role_guard
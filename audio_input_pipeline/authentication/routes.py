"""Authentication endpoints; identity operations are delegated to the configured provider."""

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from .dependencies import get_auth_provider, get_current_user
from .providers import AuthProvider
from .schemas import (
    AuthResponse,
    AuthenticatedUser,
    LoginRequest,
    MessageResponse,
    RegisterRequest,
)

router = APIRouter(prefix="/api/v1/auth", tags=["Authentication"])
_bearer = HTTPBearer(auto_error=False)


def _auth_response(result: dict) -> AuthResponse:
    token = result.get("access_token")
    user = result.get("user")
    if not token or not isinstance(user, dict):
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Identity provider returned an invalid authentication response.",
        )
    return AuthResponse(
        access_token=token,
        user=AuthenticatedUser(
            id=str(user["id"]),
            email=user["email"],
            role=user.get("role") or "user",
            full_name=user.get("full_name"),
        ),
    )


@router.post("/register", response_model=AuthResponse, status_code=status.HTTP_201_CREATED)
async def register(
    payload: RegisterRequest,
    provider: AuthProvider = Depends(get_auth_provider),
):
    result = await provider.register(
        payload.email.strip().lower(),
        payload.password,
        payload.full_name.strip(),
    )
    return _auth_response(result)


@router.post("/login", response_model=AuthResponse)
async def login(
    payload: LoginRequest,
    provider: AuthProvider = Depends(get_auth_provider),
):
    result = await provider.login(payload.email.strip().lower(), payload.password)
    return _auth_response(result)


@router.get("/me", response_model=AuthenticatedUser)
async def get_me(user: AuthenticatedUser = Depends(get_current_user)):
    return user


@router.post("/logout", response_model=MessageResponse)
async def logout(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    provider: AuthProvider = Depends(get_auth_provider),
    user: AuthenticatedUser = Depends(get_current_user),
):
    if credentials is None:
        raise HTTPException(status_code=401, detail="Bearer access token is required.")
    await provider.logout(credentials.credentials)
    return MessageResponse(message="Logged out successfully.")
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


def _auth_error(status_code: int, code: str, message: str) -> HTTPException:
    # same {code, message} shape as integration_unavailable(); the app shows detail.message
    return HTTPException(status_code=status_code, detail={"code": code, "message": message})


class SupabaseAuthProvider(AuthProvider):
    """Supabase Auth (GoTrue) over its REST API, called with the publishable/anon key.
    Supabase stores users and passwords; this server never sees a password hash."""

    def __init__(self, supabase_url: str, anon_key: str, timeout: float = 15.0):
        self.base = supabase_url.rstrip("/") + "/auth/v1"
        self.anon_key = anon_key
        self.timeout = timeout

    def _headers(self, access_token: str | None = None) -> dict:
        return {"apikey": self.anon_key, "Content-Type": "application/json",
                "Authorization": f"Bearer {access_token or self.anon_key}"}

    async def _request(self, method: str, path: str, *, token: str | None = None,
                       json: dict | None = None):
        import httpx
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                return await client.request(method, self.base + path, json=json,
                                            headers=self._headers(token))
        except httpx.HTTPError as e:
            raise _auth_error(503, "auth_unreachable",
                              f"Could not reach the authentication server ({type(e).__name__}).")

    @staticmethod
    def _error_code(resp) -> tuple[str, str]:
        try:
            body = resp.json()
        except ValueError:
            body = {}
        code = body.get("error_code") or body.get("error") or "auth_error"
        msg = body.get("msg") or body.get("error_description") or body.get("message") or resp.text
        return str(code), str(msg)

    @staticmethod
    def _user_dict(user: dict) -> dict:
        meta = user.get("user_metadata") or {}
        return {
            "id": user["id"],
            "email": user.get("email") or "",
            # app role from app_metadata (set by admins only); Supabase's own "role"
            # field is the Postgres role ("authenticated"), not an app role
            "role": (user.get("app_metadata") or {}).get("role") or "user",
            "full_name": meta.get("full_name"),
        }

    async def register(self, email: str, password: str, full_name: str) -> dict:
        resp = await self._request("POST", "/signup", json={
            "email": email, "password": password, "data": {"full_name": full_name}})
        if resp.status_code >= 400:
            code, msg = self._error_code(resp)
            if code in ("user_already_exists", "email_exists"):
                raise _auth_error(409, code, "An account with this email already exists.")
            if code == "weak_password":
                raise _auth_error(422, code, msg)
            if resp.status_code == 429:
                raise _auth_error(429, code, "Too many sign-up attempts. Please try again later.")
            raise _auth_error(400, code, msg)
        body = resp.json()
        if not body.get("access_token"):
            # "Confirm email" is on in Supabase: the account exists but has no session yet
            raise _auth_error(403, "email_confirmation_required",
                              "Account created. Please confirm your email, then log in.")
        return {"access_token": body["access_token"], "user": self._user_dict(body["user"])}

    async def login(self, email: str, password: str) -> dict:
        resp = await self._request("POST", "/token?grant_type=password",
                                   json={"email": email, "password": password})
        if resp.status_code >= 400:
            code, msg = self._error_code(resp)
            if code == "email_not_confirmed":
                raise _auth_error(403, code, "Please confirm your email before logging in.")
            if resp.status_code == 429:
                raise _auth_error(429, code, "Too many login attempts. Please try again later.")
            raise _auth_error(401, "invalid_credentials", "Incorrect email or password.")
        body = resp.json()
        return {"access_token": body["access_token"], "user": self._user_dict(body["user"])}

    async def verify_access_token(self, access_token: str) -> AuthenticatedUser:
        # Supabase checks the signature, expiry and whether the session was logged out
        resp = await self._request("GET", "/user", token=access_token)
        if resp.status_code >= 400:
            raise _auth_error(401, "invalid_token", "Invalid or expired access token.")
        return AuthenticatedUser(**self._user_dict(resp.json()))

    async def logout(self, access_token: str) -> None:
        await self._request("POST", "/logout", token=access_token)

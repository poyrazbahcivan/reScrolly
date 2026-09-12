"""
Identity for heisoj.

Three ways a request can identify itself, checked in this order:

1. A session token issued by this service (/auth/register, /auth/login).
   HS256 JWT signed with SECRET_KEY. This is the path that works tonight
   with zero external setup.
2. An Auth0 access token, if AUTH0_DOMAIN and AUTH0_AUDIENCE are set.
   Verified against Auth0's JWKS. Lets the app offer "Continue with Auth0".
3. A device id (X-Device-Id header). Guest mode. Plans and profile are
   tied to the device until the user creates an account.

Passwords are hashed with PBKDF2-SHA256 (stdlib, no extra dependency).
"""
import base64
import hashlib
import hmac
import os
import secrets
from datetime import datetime, timedelta, timezone
from typing import Optional

import jwt
from fastapi import Header, HTTPException

SECRET_KEY = os.getenv("SECRET_KEY", "dev-only-change-me-" + "x" * 32)
SESSION_DAYS = int(os.getenv("SESSION_DAYS", "30"))
AUTH0_DOMAIN = os.getenv("AUTH0_DOMAIN")
AUTH0_AUDIENCE = os.getenv("AUTH0_AUDIENCE")

_jwks_client = None


def auth0_enabled() -> bool:
    return bool(AUTH0_DOMAIN and AUTH0_AUDIENCE)


def _jwks():
    global _jwks_client
    if _jwks_client is None:
        _jwks_client = jwt.PyJWKClient(f"https://{AUTH0_DOMAIN}/.well-known/jwks.json")
    return _jwks_client


# ---- passwords -------------------------------------------------------------

def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200_000)
    return base64.b64encode(salt).decode() + "$" + base64.b64encode(dk).decode()


def verify_password(password: str, stored: str) -> bool:
    try:
        salt_b64, dk_b64 = stored.split("$", 1)
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(dk_b64)
        dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200_000)
        return hmac.compare_digest(dk, expected)
    except Exception:  # noqa: BLE001
        return False


# ---- session tokens --------------------------------------------------------

def issue_token(user_id: str, email: str) -> str:
    now = datetime.now(timezone.utc)
    return jwt.encode(
        {"sub": user_id, "email": email, "iat": now, "exp": now + timedelta(days=SESSION_DAYS), "iss": "heisoj"},
        SECRET_KEY, algorithm="HS256",
    )


def _verify_local(token: str) -> Optional[str]:
    try:
        claims = jwt.decode(token, SECRET_KEY, algorithms=["HS256"], issuer="heisoj")
        return claims["sub"]
    except Exception:  # noqa: BLE001
        return None


def _verify_auth0(token: str) -> Optional[str]:
    if not auth0_enabled():
        return None
    try:
        key = _jwks().get_signing_key_from_jwt(token).key
        claims = jwt.decode(token, key, algorithms=["RS256"], audience=AUTH0_AUDIENCE, issuer=f"https://{AUTH0_DOMAIN}/")
        return "auth0|" + claims["sub"]
    except Exception:  # noqa: BLE001
        return None


async def current_user(
    authorization: Optional[str] = Header(default=None),
    x_device_id: Optional[str] = Header(default=None),
) -> str:
    """Stable user id: account id, Auth0 subject, or device id."""
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization.split(" ", 1)[1].strip()
        uid = _verify_local(token) or _verify_auth0(token)
        if uid:
            return uid
        raise HTTPException(status_code=401, detail="Invalid or expired token")
    if x_device_id:
        return "device|" + x_device_id
    return "guest"


async def require_account(user: str = None, authorization: Optional[str] = Header(default=None)) -> str:
    """Like current_user but refuses guests."""
    uid = await current_user(authorization=authorization, x_device_id=None)
    if uid == "guest":
        raise HTTPException(status_code=401, detail="Sign in required")
    return uid

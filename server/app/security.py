import hashlib
import hmac
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException, Request, status
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .db import get_session
from .models import User, UserStatus

ALGO = "HS256"


def _encode(user_id: str, typ: str, ttl: timedelta) -> str:
    s = get_settings()
    now = datetime.now(timezone.utc)
    payload = {"sub": user_id, "typ": typ, "iat": now, "exp": now + ttl}
    return jwt.encode(payload, s.jwt_secret, algorithm=ALGO)


def issue_tokens(user_id: str) -> dict:
    s = get_settings()
    return {
        "access_token": _encode(user_id, "access", timedelta(minutes=s.access_ttl_minutes)),
        "refresh_token": _encode(user_id, "refresh", timedelta(days=s.refresh_ttl_days)),
    }


def decode_token(token: str, typ: str = "access") -> str:
    try:
        payload = jwt.decode(token, get_settings().jwt_secret, algorithms=[ALGO])
    except jwt.PyJWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid_token")
    if payload.get("typ") != typ:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid_token_type")
    return payload["sub"]


def phone_hmac(phone: str) -> str:
    key = get_settings().phone_hmac_secret.encode()
    return hmac.new(key, phone.encode(), hashlib.sha256).hexdigest()


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


async def load_user(token: str, session: AsyncSession) -> User:
    user_id = decode_token(token)
    user = await session.get(User, user_id)
    if user is None or user.status == UserStatus.DELETED:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user_not_found")
    return user


async def current_user(request: Request, session: AsyncSession = Depends(get_session)) -> User:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing_token")
    return await load_user(auth.removeprefix("Bearer ").strip(), session)


async def active_user(user: User = Depends(current_user)) -> User:
    if user.status != UserStatus.ACTIVE:
        raise HTTPException(status.HTTP_403_FORBIDDEN, f"onboarding_required:{user.status}")
    return user

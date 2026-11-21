import json
import re
import secrets
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..db import get_session
from ..models import AuthIdentity, User, UserStatus
from ..redis_client import get_redis
from ..schemas import (
    AppleLoginIn,
    DevLoginIn,
    KakaoLoginIn,
    PhoneRequestIn,
    PhoneVerifyIn,
    RefreshIn,
    TokenOut,
)
from ..security import current_user, decode_token, issue_tokens, phone_hmac, sha256_hex
from ..services import social
from ..services.sms import get_sender

router = APIRouter(prefix="/auth", tags=["auth"])

OTP_TTL_S = 180
OTP_COOLDOWN_S = 60
OTP_DAILY_LIMIT = 5
OTP_MAX_ATTEMPTS = 5


async def _login(session: AsyncSession, provider: str, uid: str) -> tuple[User, bool, AuthIdentity]:
    q = select(AuthIdentity).where(
        AuthIdentity.provider == provider, AuthIdentity.provider_uid == uid
    )
    ident = (await session.execute(q)).scalar_one_or_none()
    if ident is not None:
        user = await session.get(User, ident.user_id)
        if user is not None and user.status != UserStatus.DELETED:
            return user, False, ident
    user = User()
    session.add(user)
    await session.flush()
    ident = AuthIdentity(user_id=user.id, provider=provider, provider_uid=uid)
    session.add(ident)
    await session.flush()
    return user, True, ident


def _token_out(user: User, is_new: bool) -> TokenOut:
    return TokenOut(**issue_tokens(user.id), status=user.status, is_new=is_new)


@router.post("/kakao", response_model=TokenOut)
async def login_kakao(body: KakaoLoginIn, session: AsyncSession = Depends(get_session)):
    uid = await social.verify_kakao(body.access_token)
    user, is_new, _ = await _login(session, "kakao", uid)
    await session.commit()
    return _token_out(user, is_new)


@router.post("/apple", response_model=TokenOut)
async def login_apple(body: AppleLoginIn, session: AsyncSession = Depends(get_session)):
    uid = social.verify_apple(body.identity_token, body.raw_nonce)
    user, is_new, ident = await _login(session, "apple", uid)
    if body.authorization_code and not ident.apple_refresh_token:
        ident.apple_refresh_token = await social.apple_exchange_code(body.authorization_code)
    await session.commit()
    return _token_out(user, is_new)


@router.post("/dev", response_model=TokenOut)
async def login_dev(body: DevLoginIn, session: AsyncSession = Depends(get_session)):
    """시뮬레이터·테스트용. ALLOW_DEV_LOGIN=false 이면 비활성."""
    s = get_settings()
    if not s.allow_dev_login or s.env == "prod":
        raise HTTPException(status.HTTP_404_NOT_FOUND)
    user, is_new, _ = await _login(session, "dev", body.name)
    await session.commit()
    return _token_out(user, is_new)


@router.post("/refresh", response_model=TokenOut)
async def refresh(body: RefreshIn, session: AsyncSession = Depends(get_session)):
    user_id = decode_token(body.refresh_token, typ="refresh")
    user = await session.get(User, user_id)
    if user is None or user.status == UserStatus.DELETED:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user_not_found")
    return _token_out(user, False)


def normalize_phone(raw: str) -> str:
    digits = re.sub(r"\D", "", raw)
    if digits.startswith("82"):
        digits = "0" + digits[2:]
    if not re.fullmatch(r"01[016789]\d{7,8}", digits):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "invalid_phone")
    return digits


@router.post("/phone/request")
async def phone_request(body: PhoneRequestIn, user: User = Depends(current_user)):
    s = get_settings()
    phone = normalize_phone(body.phone)
    h = phone_hmac(phone)
    r = get_redis()

    if not await r.set(f"otp_cool:{h}", "1", ex=OTP_COOLDOWN_S, nx=True):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "otp_cooldown")
    day_key = f"otp_daily:{h}:{datetime.now(timezone.utc):%Y%m%d}"
    count = await r.incr(day_key)
    await r.expire(day_key, 86400)
    if count > OTP_DAILY_LIMIT:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "otp_daily_limit")

    is_demo = s.demo_phone is not None and phone == normalize_phone(s.demo_phone)
    code = s.demo_code if is_demo else f"{secrets.randbelow(10**6):06d}"
    await r.set(
        f"otp:{user.id}",
        json.dumps({"h": h, "code": sha256_hex(code), "attempts": 0}),
        ex=OTP_TTL_S,
    )
    if not is_demo:
        try:
            await get_sender().send(phone, f"[Ripple] 인증번호 {code} (3분 안에 입력해 주세요)")
        except Exception:
            # 못 보냈으면 대기시간·하루 횟수를 돌려줘서 바로 다시 시도할 수 있게
            await r.delete(f"otp:{user.id}", f"otp_cool:{h}")
            await r.decr(day_key)
            raise HTTPException(status.HTTP_502_BAD_GATEWAY, "sms_send_failed")
    return {"ok": True, "expires_in": OTP_TTL_S}


@router.post("/phone/verify")
async def phone_verify(
    body: PhoneVerifyIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    r = get_redis()
    raw = await r.get(f"otp:{user.id}")
    if raw is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "otp_expired")
    data = json.loads(raw)
    h = phone_hmac(normalize_phone(body.phone))
    if data["h"] != h:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "otp_phone_mismatch")
    if data["code"] != sha256_hex(body.code.strip()):
        data["attempts"] += 1
        if data["attempts"] >= OTP_MAX_ATTEMPTS:
            await r.delete(f"otp:{user.id}")
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "otp_too_many_attempts")
        ttl = await r.ttl(f"otp:{user.id}")
        await r.set(f"otp:{user.id}", json.dumps(data), ex=max(ttl, 1))
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "otp_wrong_code")

    # 1번호 1계정
    other = (
        await session.execute(select(User).where(User.phone_hmac == h, User.id != user.id))
    ).scalar_one_or_none()
    if other is not None and other.status != UserStatus.DELETED:
        raise HTTPException(status.HTTP_409_CONFLICT, "phone_already_used")
    if other is not None:
        other.phone_hmac = None

    await r.delete(f"otp:{user.id}")
    user = await session.merge(user)
    user.phone_hmac = h
    if user.status == UserStatus.PENDING_PHONE:
        user.status = UserStatus.PENDING_PROFILE
    await session.commit()
    return {"ok": True, "status": user.status}

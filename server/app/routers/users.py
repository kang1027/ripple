import io
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from PIL import Image, ImageOps
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..db import get_session
from ..models import AuthIdentity, Message, PushDevice, RoomMember, User, UserStatus
from ..redis_client import get_redis
from ..schemas import ProfilePatchIn, UserOut, valid_avatar
from ..security import current_user
from ..services import notify, social
from ..services.chat import forget_replies_to
from ..services.text_filter import nickname_ok

router = APIRouter(prefix="/me", tags=["me"])

MAX_UPLOAD = 8 * 1024 * 1024


def to_out(user: User) -> UserOut:
    return UserOut(id=user.id, nickname=user.nickname, avatar_url=user.avatar_url, status=user.status, avatar=user.avatar)


def _maybe_activate(user: User) -> None:
    if user.status == UserStatus.PENDING_PROFILE and user.nickname:
        user.status = UserStatus.ACTIVE


@router.get("", response_model=UserOut)
async def me(user: User = Depends(current_user)):
    return to_out(user)


@router.patch("", response_model=UserOut)
async def patch_me(
    body: ProfilePatchIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    if user.status == UserStatus.PENDING_PHONE:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "phone_required")
    if body.nickname is None and body.avatar is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "nothing_to_update")
    if body.avatar is not None:
        if not valid_avatar(body.avatar):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "invalid_avatar")
        user.avatar = dict(body.avatar)
    if body.nickname is not None:
        nick = body.nickname.strip()
        if not (2 <= len(nick) <= 12):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "nickname_length")
        if not nickname_ok(nick):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "nickname_banned")
        taken = (
            await session.execute(select(User.id).where(User.nickname == nick, User.id != user.id))
        ).first()
        if taken:
            raise HTTPException(status.HTTP_409_CONFLICT, "nickname_taken")
        user.nickname = nick
        _maybe_activate(user)
    await session.commit()
    return to_out(user)


@router.post("/avatar", response_model=UserOut)
async def upload_avatar(
    file: UploadFile = File(...),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    if user.status == UserStatus.PENDING_PHONE:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "phone_required")
    data = await file.read(MAX_UPLOAD + 1)
    if len(data) > MAX_UPLOAD:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "file_too_large")
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img)  # 회전만 반영하고
        img = img.convert("RGB")
        img.thumbnail((512, 512))
    except Exception:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "invalid_image")

    s = get_settings()
    folder = Path(s.media_dir) / "avatars"
    folder.mkdir(parents=True, exist_ok=True)
    name = f"{uuid.uuid4().hex}.jpg"
    # 새로 저장하면서 EXIF(GPS 포함)는 버림
    img.save(folder / name, "JPEG", quality=85)
    user.avatar_url = f"{s.public_base_url}/media/avatars/{name}"
    await session.commit()
    return to_out(user)


@router.delete("")
async def delete_me(user: User = Depends(current_user), session: AsyncSession = Depends(get_session)):
    idents = (
        await session.execute(select(AuthIdentity).where(AuthIdentity.user_id == user.id))
    ).scalars()
    for ident in idents:
        if ident.provider == "apple" and ident.apple_refresh_token:
            await social.apple_revoke(ident.apple_refresh_token)
    await session.execute(delete(AuthIdentity).where(AuthIdentity.user_id == user.id))
    await session.execute(delete(PushDevice).where(PushDevice.user_id == user.id))
    await forget_replies_to(session, Message.user_id == user.id)
    now = datetime.now(timezone.utc)
    await session.execute(
        update(RoomMember)
        .where(RoomMember.user_id == user.id, RoomMember.left_at.is_(None))
        .values(left_at=now)
    )
    user.status = UserStatus.DELETED
    user.deleted_at = now
    user.nickname = None
    user.avatar_url = None
    user.avatar = None
    user.phone_hmac = None
    await session.commit()

    r = get_redis()
    await r.zrem("presence", user.id)
    await r.zrem("presence:ts", user.id)
    await notify.forget_position(user.id)
    return {"ok": True}

from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..models import PushDevice, User
from ..schemas import PushDeviceIn
from ..security import current_user

router = APIRouter(prefix="/push", tags=["push"])


@router.post("/devices")
async def register_device(
    body: PushDeviceIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    token = body.token.lower()
    device = (await session.execute(select(PushDevice).where(PushDevice.token == token))).scalar_one_or_none()
    if device is None:
        session.add(PushDevice(user_id=user.id, token=token, env=body.env))
    else:
        # 같은 기기에서 다른 계정으로 로그인하면 새 계정으로 옮긴다
        device.user_id = user.id
        device.env = body.env
        device.updated_at = datetime.now(timezone.utc)
    await session.commit()
    return {"ok": True}


@router.delete("/devices/{token}")
async def unregister_device(
    token: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    await session.execute(
        delete(PushDevice).where(PushDevice.token == token.lower(), PushDevice.user_id == user.id)
    )
    await session.commit()
    return {"ok": True}

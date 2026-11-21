from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..models import Block, Message, Report, User
from ..schemas import BlockIn, MemberBrief, ReportIn
from ..security import active_user

router = APIRouter(tags=["safety"])


@router.post("/reports")
async def report(body: ReportIn, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    if await session.get(Message, body.message_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "message_not_found")
    session.add(Report(reporter_id=user.id, message_id=body.message_id, reason=body.reason))
    await session.commit()
    return {"ok": True}


@router.post("/blocks")
async def block(body: BlockIn, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    if body.user_id == user.id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "cannot_block_self")
    exists = (
        await session.execute(
            select(Block.id).where(Block.user_id == user.id, Block.blocked_user_id == body.user_id)
        )
    ).first()
    if not exists:
        session.add(Block(user_id=user.id, blocked_user_id=body.user_id))
        await session.commit()
    return {"ok": True}


@router.get("/blocks", response_model=list[MemberBrief])
async def list_blocks(user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    rows = (
        await session.execute(
            select(User).join(Block, Block.blocked_user_id == User.id).where(Block.user_id == user.id)
        )
    ).scalars()
    return [MemberBrief(id=u.id, nickname=u.nickname, avatar_url=u.avatar_url) for u in rows]


@router.delete("/blocks/{user_id}")
async def unblock(user_id: str, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    await session.execute(delete(Block).where(Block.user_id == user.id, Block.blocked_user_id == user_id))
    await session.commit()
    return {"ok": True}

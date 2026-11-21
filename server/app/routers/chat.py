from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..redis_client import get_redis
from ..models import Message, Room, RoomMember, Topic, TopicMember, User
from ..schemas import ChatsOut, MessageOut, RoomOut, TopicOut, TopicPatchIn
from ..security import active_user
from ..services.chat import (
    active_membership,
    blocked_ids,
    ever_member,
    is_topic_member,
    publish,
    push_demo_job,
    room_channel,
    room_out,
    serialize,
    topic_out,
)

router = APIRouter(tags=["chat"])


async def _room_for_reader(session: AsyncSession, room_id: str, user: User, *, active: bool = True) -> Room:
    """active=True면 지금 참여 중인 사람만. 범위를 벗어나 빠진 사람은 다시 들어오기 전까지 대화를 못 본다."""
    room = await session.get(Room, room_id)
    if room is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "room_not_found")
    if active:
        if await active_membership(session, room_id, user.id) is None:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "not_in_room")
    elif not await ever_member(session, room_id, user.id):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not_a_member")
    return room


async def _messages(
    session: AsyncSession, user: User, *, room_id: str, topic_id: str | None, before: int | None, limit: int
) -> list[MessageOut]:
    q = select(Message).where(Message.room_id == room_id)
    q = q.where(Message.topic_id == topic_id) if topic_id else q.where(Message.topic_id.is_(None))
    if before:
        q = q.where(Message.id < before)
    hidden = await blocked_ids(session, user.id)
    if hidden:
        q = q.where((Message.user_id.is_(None)) | (Message.user_id.not_in(hidden)))
    rows = (await session.execute(q.order_by(Message.id.desc()).limit(limit))).scalars().all()
    return await serialize(session, list(reversed(rows)), hidden)


@router.get("/rooms/{room_id}", response_model=RoomOut)
async def get_room(room_id: str, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    room = await _room_for_reader(session, room_id, user, active=False)
    return await room_out(session, room, user.id)


@router.post("/rooms/{room_id}/leave")
async def leave_room(room_id: str, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    member = await active_membership(session, room_id, user.id)
    if member is None:
        return {"ok": True}
    member.left_at = datetime.now(timezone.utc)
    await session.commit()
    await get_redis().delete(f"kicked:{user.id}:{room_id}")
    room = await session.get(Room, room_id)
    out = await room_out(session, room, user.id)
    await publish(room_channel(room_id), {"type": "members", "member_count": out.member_count, "avatars": out.avatars})
    return {"ok": True}


@router.get("/rooms/{room_id}/messages", response_model=list[MessageOut])
async def room_messages(
    room_id: str,
    before: int | None = None,
    limit: int = Query(default=30, le=100),
    user: User = Depends(active_user),
    session: AsyncSession = Depends(get_session),
):
    await _room_for_reader(session, room_id, user)
    return await _messages(session, user, room_id=room_id, topic_id=None, before=before, limit=limit)


@router.get("/rooms/{room_id}/topics", response_model=list[TopicOut])
async def room_topics(room_id: str, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    await _room_for_reader(session, room_id, user)
    topics = (
        await session.execute(
            select(Topic).where(Topic.room_id == room_id).order_by(Topic.last_message_at.desc())
        )
    ).scalars().all()
    return [await topic_out(session, t, user.id) for t in topics]


async def _topic_for(session: AsyncSession, topic_id: str) -> Topic:
    topic = await session.get(Topic, topic_id)
    if topic is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "topic_not_found")
    return topic


@router.get("/topics/{topic_id}", response_model=TopicOut)
async def get_topic(topic_id: str, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    """토픽 멤버이거나, 지금 그 동네방에 있는 사람(카드에서 참여하기 전)만."""
    topic = await _topic_for(session, topic_id)
    if not await is_topic_member(session, topic_id, user.id):
        await _room_for_reader(session, topic.room_id, user)
    return await topic_out(session, topic, user.id)


async def _my_membership(session: AsyncSession, topic_id: str, user: User) -> TopicMember:
    member = (
        await session.execute(
            select(TopicMember).where(TopicMember.topic_id == topic_id, TopicMember.user_id == user.id)
        )
    ).scalar_one_or_none()
    if member is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not_a_member")
    return member


@router.patch("/topics/{topic_id}", response_model=TopicOut)
async def patch_topic(
    topic_id: str, body: TopicPatchIn, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)
):
    """나 기준 토픽 설정. 지금은 알림 끄기만."""
    topic = await _topic_for(session, topic_id)
    member = await _my_membership(session, topic_id, user)
    member.muted = body.muted
    await session.commit()
    return await topic_out(session, topic, user.id)


@router.post("/topics/{topic_id}/leave")
async def leave_topic(topic_id: str, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    await _topic_for(session, topic_id)
    member = (
        await session.execute(
            select(TopicMember).where(TopicMember.topic_id == topic_id, TopicMember.user_id == user.id)
        )
    ).scalar_one_or_none()
    if member is not None:
        await session.delete(member)
        await session.commit()
    return {"ok": True}


@router.post("/topics/{topic_id}/join", response_model=TopicOut)
async def join_topic(topic_id: str, user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    topic = await _topic_for(session, topic_id)
    if await active_membership(session, topic.room_id, user.id) is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not_in_room")
    if not await is_topic_member(session, topic_id, user.id):
        session.add(TopicMember(topic_id=topic_id, user_id=user.id))
        await session.commit()
        await push_demo_job({"kind": "topic_join", "topic_id": topic_id, "user_id": user.id})
    return await topic_out(session, topic, user.id)


@router.get("/topics/{topic_id}/messages", response_model=list[MessageOut])
async def topic_messages(
    topic_id: str,
    before: int | None = None,
    limit: int = Query(default=30, le=100),
    user: User = Depends(active_user),
    session: AsyncSession = Depends(get_session),
):
    topic = await _topic_for(session, topic_id)
    if not await is_topic_member(session, topic_id, user.id):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not_a_member")
    return await _messages(session, user, room_id=topic.room_id, topic_id=topic_id, before=before, limit=limit)


# 메시지 보관 기간과 같게: 하루 지난 토픽은 목록에서 뺌
CHAT_LIST_WINDOW = timedelta(days=7)


@router.get("/me/chats", response_model=ChatsOut)
async def my_chats(user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    member = (
        await session.execute(
            select(RoomMember)
            .join(Room, Room.id == RoomMember.room_id)
            .where(RoomMember.user_id == user.id, RoomMember.left_at.is_(None), Room.closed_at.is_(None))
            .order_by(RoomMember.joined_at.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    room = await room_out(session, await session.get(Room, member.room_id), user.id) if member else None

    since = datetime.now(timezone.utc) - CHAT_LIST_WINDOW
    topics = (
        await session.execute(
            select(Topic)
            .join(TopicMember, TopicMember.topic_id == Topic.id)
            .where(TopicMember.user_id == user.id, Topic.last_message_at >= since)
            .order_by(Topic.last_message_at.desc())
            .limit(50)
        )
    ).scalars().all()
    return ChatsOut(room=room, topics=[await topic_out(session, t, user.id) for t in topics])

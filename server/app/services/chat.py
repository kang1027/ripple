import json
from datetime import datetime, timezone

from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..models import Block, Message, MessageType, Room, RoomMember, Topic, TopicMember, User
from ..redis_client import get_redis
from ..schemas import MemberBrief, MessageOut, ReplyRef, RoomOut, TopicOut
from .categories import category_cover_url, category_image_url
from .text_filter import clean_message

TOPIC_JOBS = "topic_jobs"


def room_channel(room_id: str) -> str:
    return f"ch:room:{room_id}"


def topic_channel(topic_id: str) -> str:
    return f"ch:topic:{topic_id}"


async def publish(channel: str, event: dict) -> None:
    await get_redis().publish(channel, json.dumps(event, default=str, ensure_ascii=False))


async def blocked_ids(session: AsyncSession, user_id: str) -> set[str]:
    rows = await session.execute(
        select(Block.user_id, Block.blocked_user_id).where(
            or_(Block.user_id == user_id, Block.blocked_user_id == user_id)
        )
    )
    out: set[str] = set()
    for a, b in rows:
        out.add(b if a == user_id else a)
    return out


async def active_membership(session: AsyncSession, room_id: str, user_id: str) -> RoomMember | None:
    q = select(RoomMember).where(
        RoomMember.room_id == room_id,
        RoomMember.user_id == user_id,
        RoomMember.left_at.is_(None),
    )
    return (await session.execute(q)).scalar_one_or_none()


async def ever_member(session: AsyncSession, room_id: str, user_id: str) -> bool:
    q = select(RoomMember.id).where(RoomMember.room_id == room_id, RoomMember.user_id == user_id)
    return (await session.execute(q)).first() is not None


async def is_topic_member(session: AsyncSession, topic_id: str, user_id: str) -> bool:
    q = select(TopicMember.id).where(TopicMember.topic_id == topic_id, TopicMember.user_id == user_id)
    return (await session.execute(q)).first() is not None


async def room_out(session: AsyncSession, room: Room, user_id: str) -> RoomOut:
    members = (
        await session.execute(
            select(User)
            .join(RoomMember, RoomMember.user_id == User.id)
            .where(RoomMember.room_id == room.id, RoomMember.left_at.is_(None))
            .order_by(RoomMember.joined_at)
        )
    ).scalars().all()
    is_active = any(m.id == user_id for m in members)
    return RoomOut(
        id=room.id,
        area_name=room.area_name,
        member_count=len(members),
        avatars=[m.avatar_url for m in members[:5]],
        is_member=is_active,
        read_only=not is_active,
    )


async def topic_out(session: AsyncSession, topic: Topic, user_id: str | None = None) -> TopicOut:
    count = (
        await session.execute(
            select(func.count()).select_from(TopicMember).where(TopicMember.topic_id == topic.id)
        )
    ).scalar_one()
    member = None
    if user_id:
        member = (
            await session.execute(
                select(TopicMember).where(TopicMember.topic_id == topic.id, TopicMember.user_id == user_id)
            )
        ).scalar_one_or_none()
    room = await session.get(Room, topic.room_id)
    return TopicOut(
        id=topic.id,
        room_id=topic.room_id,
        title=topic.title,
        summary=topic.summary,
        category=topic.category,
        image_url=topic.image_url or category_image_url(topic.category),
        cover_url=category_cover_url(topic.category),
        member_count=count,
        last_message_at=topic.last_message_at,
        is_member=member is not None,
        place_name=room.area_name if room else None,
        created_at=topic.created_at,
        muted=bool(member and member.muted),
    )


async def serialize(
    session: AsyncSession, messages: list[Message], hidden: set[str] | None = None
) -> list[MessageOut]:
    """hidden: 보는 사람이 차단했거나 차단당한 사용자. 그 사람 말에 단 답장 미리보기는 숨긴다."""
    ids = {m.user_id for m in messages if m.user_id}
    users = {}
    if ids:
        rows = (await session.execute(select(User).where(User.id.in_(ids)))).scalars()
        users = {u.id: u for u in rows}
    out = []
    for m in messages:
        u = users.get(m.user_id) if m.user_id else None
        sender = MemberBrief(id=u.id, nickname=u.nickname, avatar_url=u.avatar_url, avatar=u.avatar) if u else None
        reply = ReplyRef(**m.reply_snapshot) if m.reply_snapshot else None
        if reply and hidden and reply.sender_id in hidden:
            reply = None
        out.append(
            MessageOut(
                id=m.id,
                room_id=m.room_id,
                topic_id=m.topic_id,
                type=m.type,
                body=m.body,
                meta=m.meta,
                sender=sender,
                created_at=m.created_at,
                reply=reply,
            )
        )
    return out


async def reply_snapshot(session: AsyncSession, reply_to: int | None, room_id: str, topic_id: str | None) -> dict | None:
    """같은 방·같은 토픽(동네방이면 topic_id 없음)의 메시지에만 답장할 수 있다. 아니면 None."""
    if not reply_to:
        return None
    target = await session.get(Message, reply_to)
    if target is None or target.room_id != room_id or target.topic_id != topic_id:
        return None
    sender = await session.get(User, target.user_id) if target.user_id else None
    return {
        "id": target.id,
        "sender_id": target.user_id,
        "nickname": sender.nickname if sender else None,
        "body": target.body[:80],
    }


async def post_message(
    session: AsyncSession,
    *,
    room_id: str,
    user: User | None,
    body: str,
    topic_id: str | None = None,
    type: str = MessageType.TEXT,
    meta: dict | None = None,
    client_id: str | None = None,
    reply_to: int | None = None,
) -> MessageOut:
    text = clean_message(body) if type == MessageType.TEXT else body
    snapshot = await reply_snapshot(session, reply_to, room_id, topic_id)
    msg = Message(
        room_id=room_id,
        topic_id=topic_id,
        user_id=user.id if user else None,
        type=type,
        body=text,
        meta=meta,
        reply_to_id=snapshot["id"] if snapshot else None,
        reply_snapshot=snapshot,
    )
    session.add(msg)
    if topic_id:
        topic = await session.get(Topic, topic_id)
        if topic:
            topic.last_message_at = datetime.now(timezone.utc)
    await session.commit()
    await session.refresh(msg)
    out = (await serialize(session, [msg]))[0]
    out.client_id = client_id
    channel = topic_channel(topic_id) if topic_id else room_channel(room_id)
    await publish(channel, {"type": "message", "message": out.model_dump(mode="json")})

    from . import notify  # notify가 chat을 가져다 써서 여기서 import

    notify.spawn(notify.on_message(out.model_dump(mode="json")))

    if type == MessageType.TEXT and topic_id is None and user is not None:
        await get_redis().rpush(
            TOPIC_JOBS,
            json.dumps({"room_id": room_id, "message_id": msg.id, "user_id": user.id, "body": text}),
        )
    return out


async def forget_replies_to(session: AsyncSession, where) -> None:
    """원본이 지워지거나(보관 기간) 작성자가 탈퇴하면 그 원본을 가리키던 답장 미리보기도 지운다.
    where: 원본 메시지를 고르는 조건."""
    originals = select(Message.id).where(where)
    await session.execute(
        update(Message).where(Message.reply_to_id.in_(originals)).values(reply_to_id=None, reply_snapshot=None)
    )

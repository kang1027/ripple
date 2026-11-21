"""앱푸시를 언제 누구에게 보낼지 정한다.

- 토픽 매칭: 토픽이 확정되면 처음 멤버에게
- 토픽방·동네방 메시지: 멤버에게 메시지마다 바로 (쿨다운 없음)
- 토픽 카드(새 토픽·리마인드): 방 멤버에게
- 근처 사람: 레이더를 안 보고 있는 사용자(앱을 내렸거나 다른 화면) 반경 안에 새 사람이 들어오면.
  (나, 상대) 짝마다 기억하고 같은 짝은 nearby_pair_cooldown_s에 한 번. 반경 안으로 들어오면 '들어옴',
  room_leave_m 밖으로 나가야 '나감'으로 봐서 GPS가 경계에서 흔들려도 알림이 반복되지 않는다.

그 채팅방 웹소켓에 붙어 있는 사람(지금 그 화면을 보고 있는 사람)에게는 보내지 않는다.
요청·워커를 막지 않게 spawn()으로 백그라운드에서 돈다.
"""

import asyncio
import logging
import time
from collections.abc import Coroutine

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..db import sessionmaker
from ..models import MessageType, PushDevice, Room, RoomMember, Topic, TopicMember, User, UserStatus
from ..redis_client import get_redis
from . import apns, geo
from .chat import blocked_ids, room_channel, topic_channel

log = logging.getLogger("ripple.notify")

PUSHPOS = "pushpos"
PUSHPOS_TS = "pushpos:ts"
ONLINE_TTL_S = 40  # 앱이 15초마다 ping을 보내고, 앱을 내리면 소켓을 바로 닫는다

_tasks: set[asyncio.Task] = set()


def spawn(coro: Coroutine) -> None:
    async def guard() -> None:
        try:
            await coro
        except Exception:
            log.exception("push task failed")

    task = asyncio.create_task(guard())
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


# ---------- 지금 보고 있는 채팅방 ----------


def _online_key(channel: str, user_id: str) -> str:
    return f"ws:on:{channel}:{user_id}"


async def mark_online(channel: str, user_id: str) -> None:
    r = get_redis()
    key = _online_key(channel, user_id)
    await r.incr(key)
    await r.expire(key, ONLINE_TTL_S)


async def touch_online(channel: str, user_id: str) -> None:
    await get_redis().expire(_online_key(channel, user_id), ONLINE_TTL_S)


async def mark_offline(channel: str, user_id: str) -> None:
    r = get_redis()
    key = _online_key(channel, user_id)
    if await r.decr(key) <= 0:
        await r.delete(key)


async def _watching(channel: str, user_ids: set[str]) -> set[str]:
    r = get_redis()
    return {uid for uid in user_ids if int(await r.get(_online_key(channel, uid)) or 0) > 0}


# ---------- 보내기 ----------


async def _push(
    session: AsyncSession,
    user_ids: set[str],
    *,
    title: str,
    body: str,
    data: dict,
    thread_id: str | None = None,
    collapse_id: str | None = None,
) -> int:
    if not user_ids:
        return 0
    devices = (
        await session.execute(select(PushDevice).where(PushDevice.user_id.in_(user_ids)))
    ).scalars().all()
    aps: dict = {"alert": {"title": title, "body": body[:180]}, "sound": "default"}
    if thread_id:
        aps["thread-id"] = thread_id
    payload = {"aps": aps, **data}
    sent = 0
    for d in devices:
        res = await apns.send(d.token, d.env, payload, collapse_id)
        if res.ok:
            sent += 1
            if res.env != d.env:
                d.env = res.env
        elif res.dead:
            await session.delete(d)
    await session.commit()
    return sent


async def _room_members(session: AsyncSession, room_id: str) -> set[str]:
    rows = await session.execute(
        select(RoomMember.user_id)
        .join(User, User.id == RoomMember.user_id)
        .where(RoomMember.room_id == room_id, RoomMember.left_at.is_(None), User.status == UserStatus.ACTIVE)
    )
    return set(rows.scalars())


async def _topic_members(session: AsyncSession, topic_id: str) -> set[str]:
    rows = await session.execute(
        select(TopicMember.user_id)
        .join(User, User.id == TopicMember.user_id)
        .where(TopicMember.topic_id == topic_id, User.status == UserStatus.ACTIVE)
    )
    return set(rows.scalars())


async def _cooldown(key: str, seconds: int) -> bool:
    """처음이면 True. seconds 동안은 False."""
    if seconds <= 0:
        return True
    return bool(await get_redis().set(key, "1", ex=seconds, nx=True))


# ---------- 메시지 ----------


async def on_message(msg: dict) -> None:
    async with sessionmaker()() as session:
        if msg.get("topic_id"):
            if msg["type"] == MessageType.TEXT:
                await _topic_text(session, msg)
        elif msg["type"] == MessageType.TEXT:
            await _room_text(session, msg)
        elif msg["type"] == MessageType.TOPIC_CARD:
            await _topic_card(session, msg)


def _sender(msg: dict) -> tuple[str | None, str]:
    sender = msg.get("sender") or {}
    return sender.get("id"), sender.get("nickname") or "누군가"


async def _exclude_sender(session: AsyncSession, ids: set[str], sender_id: str | None) -> set[str]:
    if sender_id is None:
        return ids
    return ids - {sender_id} - await blocked_ids(session, sender_id)


async def _topic_text(session: AsyncSession, msg: dict) -> None:
    topic = await session.get(Topic, msg["topic_id"])
    if topic is None:
        return
    sender_id, nickname = _sender(msg)
    ids = await _exclude_sender(session, await _topic_members(session, topic.id), sender_id)
    ids -= await _watching(topic_channel(topic.id), ids)
    await _push(
        session,
        ids,
        title=topic.title,
        body=f"{nickname}: {msg['body']}",
        data={"type": "topic", "topic_id": topic.id, "room_id": topic.room_id},
        thread_id=f"topic-{topic.id}",
    )


async def _room_text(session: AsyncSession, msg: dict) -> None:
    room = await session.get(Room, msg["room_id"])
    if room is None or room.closed_at is not None:
        return
    sender_id, nickname = _sender(msg)
    ids = await _exclude_sender(session, await _room_members(session, room.id), sender_id)
    ids -= await _watching(room_channel(room.id), ids)
    await _push(
        session,
        ids,
        title=room.area_name,
        body=f"{nickname}: {msg['body']}",
        data={"type": "room", "room_id": room.id},
        thread_id=f"room-{room.id}",
    )


async def _topic_card(session: AsyncSession, msg: dict) -> None:
    room = await session.get(Room, msg["room_id"])
    meta = msg.get("meta") or {}
    if room is None or room.closed_at is not None or not meta.get("topic_id"):
        return
    ids = await _room_members(session, room.id)
    reminder = bool(meta.get("reminder"))
    if not reminder:
        # 처음 멤버는 on_topic_created로 따로 받는다
        ids -= await _topic_members(session, meta["topic_id"])
    ids -= await _watching(room_channel(room.id), ids)
    title = meta.get("title") or ""
    await _push(
        session,
        ids,
        title=room.area_name,
        body=f"지금 이야기 중인 토픽: {title}" if reminder else f"새 토픽이 생겼어요: {title}",
        data={"type": "room", "room_id": room.id},
        thread_id=f"room-{room.id}",
        collapse_id=f"card-{meta['topic_id']}",
    )


async def on_topic_created(topic_id: str) -> None:
    async with sessionmaker()() as session:
        topic = await session.get(Topic, topic_id)
        if topic is None:
            return
        ids = await _topic_members(session, topic.id)
        ids -= await _watching(room_channel(topic.room_id), ids)
        await _push(
            session,
            ids,
            title="나랑 같은 얘기를 하는 사람이 있어요",
            body=f"토픽 '{topic.title}'이 열렸어요. 들어가서 이어서 이야기해 보세요",
            data={"type": "topic", "topic_id": topic.id, "room_id": topic.room_id},
            thread_id=f"topic-{topic.id}",
        )


# ---------- 근처 사람 ----------


def _away_key(user_id: str) -> str:
    """레이더를 안 보고 있음 (앱을 내렸거나 다른 화면)."""
    return f"away:{user_id}"


def _inside_key(user_id: str) -> str:
    """user_id 기준으로 '반경 안에 들어와 있다'고 본 상대들."""
    return f"nearby:inside:{user_id}"


async def _candidates(user_id: str, lat: float, lng: float, within_m: float) -> dict[str, float]:
    """방금 위치를 보낸 사람 + 마지막 위치가 아직 유효한 사람 중 within_m 안. {user_id: 거리}"""
    s = get_settings()
    r = get_redis()
    out: dict[str, float] = {}
    for uid in await geo.nearby_user_ids(lat, lng, int(within_m) + 1):
        pos = await geo.last_position(uid)
        if pos is not None:
            out[uid] = geo.haversine_m(pos["lat"], pos["lng"], lat, lng)
    cutoff = time.time() - s.nearby_push_window_s
    for uid, dist in await r.geosearch(
        PUSHPOS, longitude=lng, latitude=lat, radius=within_m, unit="m", withdist=True
    ):
        if uid in out:
            continue
        ts = await r.zscore(PUSHPOS_TS, uid)
        if ts is not None and ts >= cutoff:
            out[uid] = float(dist)
    out.pop(user_id, None)
    return out


async def _push_nearby(session: AsyncSession, user_id: str, count: int) -> None:
    s = get_settings()
    body = (
        f"반경 {s.radius_m}m 안에 새로운 사람이 왔어요. 레이더에서 확인해 보세요"
        if count == 1
        else f"반경 {s.radius_m}m 안에 새로운 사람 {count}명이 왔어요. 레이더에서 확인해 보세요"
    )
    await _push(session, {user_id}, title="근처에 사람이 있어요", body=body, data={"type": "nearby"})


async def forget_position(user_id: str) -> None:
    r = get_redis()
    await r.zrem(PUSHPOS, user_id)
    await r.zrem(PUSHPOS_TS, user_id)
    await r.delete(_away_key(user_id), _inside_key(user_id))


async def on_presence(user_id: str, lat: float, lng: float, background: bool, on_radar: bool = True) -> None:
    s = get_settings()
    r = get_redis()
    now = time.time()
    await r.geoadd(PUSHPOS, [lng, lat, user_id])
    await r.zadd(PUSHPOS_TS, {user_id: now})
    for uid in await r.zrangebyscore(PUSHPOS_TS, 0, now - s.nearby_push_window_s):
        await r.zrem(PUSHPOS, uid)
        await r.zrem(PUSHPOS_TS, uid)
    if background or not on_radar:
        await r.set(_away_key(user_id), "1", ex=s.nearby_push_window_s)
    else:
        await r.delete(_away_key(user_id))

    leave_m = max(s.room_leave_m, s.radius_m)
    async with sessionmaker()() as session:
        hidden = await blocked_ids(session, user_id)
        near = {uid: d for uid, d in (await _candidates(user_id, lat, lng, leave_m)).items() if uid not in hidden}
        new_for_me = 0
        for other, dist in near.items():
            if dist > s.radius_m:
                continue  # 경계 구간: 들어옴/나감 상태를 그대로 둔다
            for me, them in ((user_id, other), (other, user_id)):
                if await r.sismember(_inside_key(me), them):
                    continue
                await r.sadd(_inside_key(me), them)
                await r.expire(_inside_key(me), s.nearby_push_window_s)
                if not await r.exists(_away_key(me)):
                    continue
                if not await _cooldown(f"pushcd:pair:{me}:{them}", s.nearby_pair_cooldown_s):
                    continue
                if me == user_id:
                    new_for_me += 1
                else:
                    await _push_nearby(session, me, 1)
        if new_for_me:
            await _push_nearby(session, user_id, new_for_me)

        # room_leave_m 밖으로 나간 상대는 '나감'
        for other in await r.smembers(_inside_key(user_id)):
            if other not in near:
                await r.srem(_inside_key(user_id), other)
                await r.srem(_inside_key(other), user_id)

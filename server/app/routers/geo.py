import asyncio
import logging
import time
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..db import get_session
from ..models import Room, RoomMember, User
from ..redis_client import get_redis
from ..schemas import NearbyOut, PresenceIn, PresenceOut, RoomOut
from ..security import active_user
from ..services import geo, notify
from ..services.chat import blocked_ids, publish, room_channel, room_out

router = APIRouter(tags=["geo"])
log = logging.getLogger("ripple.geo")

MAX_ACCURACY_M = 100


async def _in_range(session: AsyncSession, room: Room, user_id: str, lat: float, lng: float) -> bool:
    """방 중심이나, 위치가 살아 있는 다른 참여자 중 한 명이라도 room_leave_m 안이면 범위 안.
    방 중심은 격자로 반올림돼 있어서 중심만 보면 같이 서 있는데도 빠질 수 있다."""
    s = get_settings()
    if geo.haversine_m(room.center_lat, room.center_lng, lat, lng) <= s.room_leave_m:
        return True
    others = (
        await session.execute(
            select(RoomMember.user_id).where(
                RoomMember.room_id == room.id, RoomMember.left_at.is_(None), RoomMember.user_id != user_id
            )
        )
    ).scalars().all()
    for uid in others:
        pos = await geo.last_position(uid)
        if pos is not None and geo.haversine_m(pos["lat"], pos["lng"], lat, lng) <= s.room_leave_m:
            return True
    return False


def kicked_key(user_id: str, room_id: str) -> str:
    return f"kicked:{user_id}:{room_id}"


async def _auto_rejoin(session: AsyncSession, user: User, lat: float, lng: float) -> list[str]:
    """거리로 빠졌던 방에 다시 들어오면(방 중심이나 남은 참여자 중 한 명이 반경 안) 자동으로 다시 넣는다.
    지금 다른 방에 들어가 있으면 하지 않는다. 직접 '나가기'를 누른 방은 대상이 아니다."""
    s = get_settings()
    r = get_redis()
    active = (
        await session.execute(
            select(RoomMember.id).where(RoomMember.user_id == user.id, RoomMember.left_at.is_(None))
        )
    ).first()
    if active is not None:
        return []
    rooms = (
        await session.execute(
            select(Room)
            .join(RoomMember, RoomMember.room_id == Room.id)
            .where(RoomMember.user_id == user.id, Room.closed_at.is_(None))
            .order_by(RoomMember.left_at.desc())
        )
    ).scalars().unique().all()
    for room in rooms:
        if not await r.exists(kicked_key(user.id, room.id)):
            continue
        near = geo.haversine_m(room.center_lat, room.center_lng, lat, lng) <= s.radius_m
        if not near:
            others = (
                await session.execute(
                    select(RoomMember.user_id).where(RoomMember.room_id == room.id, RoomMember.left_at.is_(None))
                )
            ).scalars().all()
            for uid in others:
                pos = await geo.last_position(uid)
                if pos is not None and geo.haversine_m(pos["lat"], pos["lng"], lat, lng) <= s.radius_m:
                    near = True
                    break
        if not near:
            continue
        session.add(RoomMember(room_id=room.id, user_id=user.id))
        await session.commit()
        await r.delete(kicked_key(user.id, room.id))
        out = await room_out(session, room, user.id)
        await publish(room_channel(room.id), {"type": "members", "member_count": out.member_count, "avatars": out.avatars})
        return [room.id]
    return []


async def _check_out_of_range(session: AsyncSession, user: User, lat: float, lng: float) -> list[str]:
    """범위 밖에 room_leave_grace_s 넘게 있으면 방에서 내보낸다. 내보낸 방 id 목록."""
    s = get_settings()
    q = (
        select(RoomMember, Room)
        .join(Room, Room.id == RoomMember.room_id)
        .where(RoomMember.user_id == user.id, RoomMember.left_at.is_(None))
    )
    r = get_redis()
    left: list[str] = []
    for member, room in (await session.execute(q)).all():
        key = f"oor:{user.id}:{room.id}"
        if await _in_range(session, room, user.id, lat, lng):
            await r.delete(key)
            continue
        first = await r.get(key)
        if first is None:
            await r.set(key, str(time.time()), ex=max(s.room_leave_grace_s * 4, 10))
            continue
        if time.time() - float(first) >= s.room_leave_grace_s:
            member.left_at = datetime.now(timezone.utc)
            await session.commit()
            await r.delete(key)
            # 직접 나간 게 아니라 거리로 빠진 방. 다시 다가오면 자동으로 다시 넣는다
            await r.set(kicked_key(user.id, room.id), "1", ex=max(s.room_idle_close_s * 2, 600))
            left.append(room.id)
            await publish(room_channel(room.id), {"type": "out_of_range", "user_id": user.id})
            out = await room_out(session, room, user.id)
            await publish(
                room_channel(room.id),
                {"type": "members", "member_count": out.member_count, "avatars": out.avatars},
            )
    return left


@router.post("/presence", response_model=PresenceOut)
async def presence(
    body: PresenceIn,
    user: User = Depends(active_user),
    session: AsyncSession = Depends(get_session),
):
    if body.accuracy > MAX_ACCURACY_M:
        ok, reason = False, "low_accuracy"
    else:
        ok, reason = await geo.report_position(user.id, body.lat, body.lng)
    left: list[str] = []
    joined: list[str] = []
    if ok:
        left = await _check_out_of_range(session, user, body.lat, body.lng)
        if not left:
            joined = await _auto_rejoin(session, user, body.lat, body.lng)
        notify.spawn(notify.on_presence(user.id, body.lat, body.lng, body.background, body.on_radar))
    if get_settings().presence_log:
        await _log_presence(user, body, ok, reason, left, joined)
    return PresenceOut(ok=ok, reason=reason, left_rooms=left, joined_rooms=joined)


async def _log_presence(
    user: User, body: PresenceIn, ok: bool, reason: str | None, left: list[str], joined: list[str]
) -> None:
    r = get_redis()
    nearest = None
    for uid in await r.zrangebyscore(geo.PRESENCE_TS, time.time() - get_settings().presence_ttl_s, "+inf"):
        if uid == user.id:
            continue
        pos = await geo.last_position(uid)
        if pos is None:
            continue
        d = geo.haversine_m(pos["lat"], pos["lng"], body.lat, body.lng)
        if nearest is None or d < nearest[1]:
            nearest = (uid, d, time.time() - pos["ts"])
    near = f"{nearest[0][:6]} {nearest[1]:.1f}m age={nearest[2]:.0f}s" if nearest else "-"
    log.info(
        "presence u=%s(%s) acc=%.0f bg=%s ok=%s reason=%s nearest=%s left=%s joined=%s",
        user.id[:6], user.nickname, body.accuracy, body.background, ok, reason, near, left, joined,
    )


@router.get("/nearby", response_model=NearbyOut)
async def nearby(user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    s = get_settings()
    pos = await geo.last_position(user.id)
    if pos is None:
        return NearbyOut(count=0, avatars=[], radius_m=s.radius_m)
    ids = await geo.nearby_user_ids(pos["lat"], pos["lng"], s.radius_m)
    hidden = await blocked_ids(session, user.id) | {user.id}
    ids = [i for i in ids if i not in hidden]
    avatars: list[str | None] = []
    if ids:
        rows = (await session.execute(select(User).where(User.id.in_(ids[:20])))).scalars()
        avatars = [u.avatar_url for u in rows][:8]
    return NearbyOut(count=len(ids), avatars=avatars, radius_m=s.radius_m)


# 둘이 동시에 '채팅하기'를 눌러 방이 두 개 생기지 않게 (서버는 replicas 1)
_join_lock = asyncio.Lock()


@router.post("/rooms/join", response_model=RoomOut)
async def join_room(user: User = Depends(active_user), session: AsyncSession = Depends(get_session)):
    pos = await geo.last_position(user.id)
    if pos is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "no_fresh_location")
    async with _join_lock:
        return await _join(session, user, pos["lat"], pos["lng"])


async def _join(session: AsyncSession, user: User, lat: float, lng: float) -> RoomOut:
    """들어갈 방 고르기.

    1) 레이더에 잡힌 사람이 들어가 있는 방 (잡힌 사람이 가장 많은 방, 같으면 내가 있던 방)
    2) 내가 이미 들어가 있고 범위 안인 방
    3) 근처에 중심이 있는 열린 방
    4) 새 방
    방은 하나만 들어가 있게 하고, 나머지 방에서는 나간다.
    """
    s = get_settings()
    now = datetime.now(timezone.utc)
    current = [
        (member, room)
        for member, room in (
            await session.execute(
                select(RoomMember, Room)
                .join(Room, Room.id == RoomMember.room_id)
                .where(RoomMember.user_id == user.id, RoomMember.left_at.is_(None))
            )
        ).all()
    ]
    mine = {room.id for _, room in current if room.closed_at is None}

    room: Room | None = None
    hidden = await blocked_ids(session, user.id) | {user.id}
    near = [uid for uid in await geo.nearby_user_ids(lat, lng, s.radius_m) if uid not in hidden]
    if near:
        counts = dict(
            (
                await session.execute(
                    select(RoomMember.room_id, func.count())
                    .join(Room, Room.id == RoomMember.room_id)
                    .where(
                        RoomMember.user_id.in_(near),
                        RoomMember.left_at.is_(None),
                        Room.closed_at.is_(None),
                    )
                    .group_by(RoomMember.room_id)
                )
            ).all()
        )
        if counts:
            best = max(counts, key=lambda rid: (counts[rid], rid in mine))
            room = await session.get(Room, best)

    if room is None:
        for _, candidate in current:
            if candidate.closed_at is None and geo.haversine_m(
                candidate.center_lat, candidate.center_lng, lat, lng
            ) <= s.room_leave_m:
                room = candidate
                break

    if room is None:
        for rid in await geo.nearest_room_id(lat, lng, geo.room_search_m(s.radius_m)):
            candidate = await session.get(Room, rid)
            if candidate is not None and candidate.closed_at is None:
                room = candidate
                break
            await get_redis().zrem(geo.ROOMS_GEO, rid)

    if room is None:
        c_lat, c_lng = geo.snap_center(lat, lng, geo.room_grid_m(s.radius_m))
        room = Room(center_lat=c_lat, center_lng=c_lng, area_name=await geo.area_name(lat, lng))
        session.add(room)
        await session.flush()
        await get_redis().geoadd(geo.ROOMS_GEO, [c_lng, c_lat, room.id])

    left: list[Room] = []
    for member, old in current:
        if old.id != room.id:
            member.left_at = now
            left.append(old)
    await get_redis().delete(kicked_key(user.id, room.id))
    if room.id not in mine:
        session.add(RoomMember(room_id=room.id, user_id=user.id))
    await session.commit()

    for old in left:
        o = await room_out(session, old, user.id)
        await publish(room_channel(old.id), {"type": "members", "member_count": o.member_count, "avatars": o.avatars})
    out = await room_out(session, room, user.id)
    await publish(
        room_channel(room.id),
        {"type": "members", "member_count": out.member_count, "avatars": out.avatars},
    )
    return out

"""시연용 데모 봇 (DEMO_BOTS=N).

- 위치를 보내는 실제 사용자 주변(반경의 25~85%)에 봇을 띄운다. 사용자가 움직이면 따라간다.
- 실제 사용자가 들어간 방에 봇도 들어가고, 가끔 동네 이야기를 한다.
- 실제 사용자가 토픽이 될 말을 하면 봇 하나가 몇 초 뒤 같은 주제로 답해 토픽 카드가 뜨게 한다.

봇은 auth_identities.provider = "demo" 로 구분한다. 로그인 수단이 없어 앱으로는 접속할 수 없다.
"""

import asyncio
import hashlib
import json
import logging
import math
import random
import time
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw
from sqlalchemy import select

from ..config import get_settings
from ..db import sessionmaker
from ..models import AuthIdentity, Room, RoomMember, User, UserStatus
from ..redis_client import get_redis
from . import geo
from .chat import post_message, publish, room_channel, room_out
from .topics import JobOutcome, RuleClassifier

log = logging.getLogger("ripple.demo")

PROVIDER = "demo"
TICK_S = 5

NICKNAMES = [
    "산책하는고양이",
    "망원동주민",
    "커피두잔",
    "퇴근길",
    "오늘도맑음",
    "합정러",
    "빵순이",
    "자전거타는곰",
    "점심뭐먹지",
    "노을보러",
    "주말여행자",
    "동네친구",
]

# 아바타 배경색 (무채색 UI에서 튀지 않게 채도 낮은 톤)
PALETTE = [
    ((214, 222, 235), (120, 136, 168)),
    ((235, 222, 214), (168, 132, 112)),
    ((219, 233, 220), (112, 150, 118)),
    ((233, 219, 233), (150, 112, 150)),
    ((236, 232, 214), (160, 148, 100)),
    ((214, 232, 234), (100, 148, 156)),
]

AMBIENT = [
    "다들 이 근처 사세요? ㅎㅎ",
    "오늘 날씨 진짜 좋네요",
    "이 근처 점심 맛집 추천 좀 해주세요",
    "카페 자리 넉넉한 곳 아시는 분?",
    "오늘 한강 불꽃놀이 한다던데 맞나요?",
    "근처에 팝업스토어 새로 열었던데 가보신 분 있어요?",
    "주말에 플리마켓 열린대요",
    "왕과 사는 남자 보신 분? 평 좋던데",
    "퇴근하고 산책 중이에요",
    "여기 웨이팅 긴 집 하나 있던데 뭐 파는 데예요?",
]

GREETINGS = [
    "안녕하세요! 반가워요 ㅎㅎ",
    "오 안녕하세요~",
    "반갑습니다 근처시구나",
    "안녕하세요 ㅎㅎ 여기 사람 꽤 있네요",
]

# 토픽 카테고리별 답. 같은 카테고리 키워드가 들어가야 규칙 분류기가 같은 주제로 묶는다
REPLY_BY_CATEGORY = {
    "movie": "저도 그 영화 보려고 했어요! 결말 어때요?",
    "event": "오 저도 그 축제 가려고요 ㅎㅎ 같이 가실 분?",
    "shopping": "거기 할인 아직 해요? 저도 궁금했는데",
    "place": "거기 웨이팅 좀 있던데 지금은 어때요?",
    "food": "거기 맛집 맞아요 점심때만 사람 좀 많아요",
    "cafe": "그 카페 저도 가봤는데 자리 넉넉했어요",
    "exhibition": "그 전시회 저도 보고 싶었어요! 사람 많아요?",
}
REPLY_BY_ENTITY = [
    "{t} 저도 관심 있어요! 같이 얘기해요",
    "헐 {t} 저도 궁금했는데 ㅋㅋ",
    "{t} 얘기 나와서 반갑네요 ㅎㅎ",
]

_bot_ids: list[str] = []
_rule = RuleClassifier()
_tasks: set[asyncio.Task] = set()


def _offset(seed: str) -> tuple[float, float]:
    """봇마다 고정된 방향·거리(반경의 25~85%). 매번 바뀌면 레이더에서 튀어 보인다."""
    h = hashlib.sha256(seed.encode()).digest()
    bearing = h[0] / 255 * 2 * math.pi
    dist = get_settings().radius_m * (0.25 + h[1] / 255 * 0.6)
    return bearing, dist


def _move(lat: float, lng: float, bearing: float, dist_m: float) -> tuple[float, float]:
    dlat = dist_m * math.cos(bearing) / 111_320
    dlng = dist_m * math.sin(bearing) / (111_320 * max(math.cos(math.radians(lat)), 0.01))
    return lat + dlat, lng + dlng


def _avatar(index: int) -> str:
    s = get_settings()
    folder = Path(s.media_dir) / "avatars"
    folder.mkdir(parents=True, exist_ok=True)
    name = f"demo-{index:02d}.png"
    path = folder / name
    if not path.exists():
        bg, fg = PALETTE[index % len(PALETTE)]
        img = Image.new("RGB", (256, 256), bg)
        d = ImageDraw.Draw(img)
        d.ellipse((78, 40, 178, 140), fill=fg)  # 머리
        d.ellipse((38, 150, 218, 330), fill=fg)  # 어깨
        img.save(path, "PNG")
    return f"{s.public_base_url}/media/avatars/{name}"


async def ensure_bots() -> list[str]:
    global _bot_ids
    want = min(get_settings().demo_bots, len(NICKNAMES))
    if len(_bot_ids) == want:
        return _bot_ids
    async with sessionmaker()() as session:
        ids = []
        for i in range(want):
            uid = f"bot-{i:02d}"
            ident = (
                await session.execute(
                    select(AuthIdentity).where(AuthIdentity.provider == PROVIDER, AuthIdentity.provider_uid == uid)
                )
            ).scalar_one_or_none()
            if ident is None:
                nickname = NICKNAMES[i]
                taken = (await session.execute(select(User).where(User.nickname == nickname))).scalar_one_or_none()
                if taken is not None:
                    nickname = f"{nickname[:20]}{i:02d}"
                user = User(nickname=nickname, avatar_url=_avatar(i), status=UserStatus.ACTIVE)
                session.add(user)
                await session.flush()
                session.add(AuthIdentity(user_id=user.id, provider=PROVIDER, provider_uid=uid))
                await session.commit()
                ids.append(user.id)
            else:
                ids.append(ident.user_id)
        _bot_ids = ids
    log.info("demo bots ready: %d", len(_bot_ids))
    return _bot_ids


async def retire() -> int:
    """DEMO_BOTS=0으로 끈 뒤 봇이 남아 있던 방에서 봇을 내보낸다. 내보낸 방 수를 돌려준다."""
    now = datetime.now(timezone.utc)
    async with sessionmaker()() as session:
        rows = (
            await session.execute(
                select(RoomMember, Room)
                .join(Room, Room.id == RoomMember.room_id)
                .join(AuthIdentity, AuthIdentity.user_id == RoomMember.user_id)
                .where(AuthIdentity.provider == PROVIDER, RoomMember.left_at.is_(None))
            )
        ).all()
        rooms: dict[str, Room] = {}
        for member, room in rows:
            member.left_at = now
            rooms[room.id] = room
        if not rooms:
            return 0
        await session.commit()
        for room in rooms.values():
            out = await room_out(session, room, "")
            await publish(
                room_channel(room.id), {"type": "members", "member_count": out.member_count, "avatars": out.avatars}
            )
    log.info("demo bots retired from %d rooms", len(rooms))
    return len(rooms)


def is_bot(user_id: str | None) -> bool:
    return user_id is not None and user_id in _bot_ids


async def _anchors() -> list[tuple[str, float, float]]:
    """위치가 살아 있는 실제 사용자. 서로 반경의 3/4 안이면 한 곳으로 묶는다."""
    r = get_redis()
    cutoff = time.time() - get_settings().presence_ttl_s
    uids = await r.zrangebyscore(geo.PRESENCE_TS, cutoff, "+inf")
    out: list[tuple[str, float, float]] = []
    for uid in uids:
        if is_bot(uid):
            continue
        pos = await geo.last_position(uid)
        if pos is None:
            continue
        if any(geo.haversine_m(a[1], a[2], pos["lat"], pos["lng"]) < get_settings().radius_m * 0.75 for a in out):
            continue
        out.append((uid, pos["lat"], pos["lng"]))
    return out


async def _place(bot_id: str, lat: float, lng: float) -> None:
    r = get_redis()
    now = time.time()
    await r.set(
        f"presence:last:{bot_id}",
        json.dumps({"lat": lat, "lng": lng, "ts": now}),
        ex=get_settings().presence_ttl_s * 2,
    )
    await r.geoadd(geo.PRESENCE, [lng, lat, bot_id])
    await r.zadd(geo.PRESENCE_TS, {bot_id: now})


async def _sync_rooms(session, placed: dict[str, tuple[float, float]]) -> list[Room]:
    """실제 사용자가 있는 방에 근처 봇을 넣고, 멀어진 봇은 내보낸다. 실제 사용자가 있는 방 목록을 돌려준다."""
    s = get_settings()
    now = datetime.now(timezone.utc)
    rows = (
        await session.execute(
            select(RoomMember, Room)
            .join(Room, Room.id == RoomMember.room_id)
            .where(RoomMember.left_at.is_(None), Room.closed_at.is_(None))
        )
    ).all()
    members: dict[str, set[str]] = {}
    rooms: dict[str, Room] = {}
    bot_rows: dict[tuple[str, str], RoomMember] = {}
    for m, room in rows:
        members.setdefault(room.id, set()).add(m.user_id)
        rooms[room.id] = room
        if is_bot(m.user_id):
            bot_rows[(room.id, m.user_id)] = m

    live_rooms = [rooms[rid] for rid, uids in members.items() if any(not is_bot(u) for u in uids)]
    changed: set[str] = set()
    for room in live_rooms:
        for bot_id, (lat, lng) in placed.items():
            # 방 중심은 격자로 반올림돼 사용자와 최대 ~106m 어긋나서, 나가는 기준(300m)으로 본다
            near = geo.haversine_m(room.center_lat, room.center_lng, lat, lng) <= s.room_leave_m
            if near and bot_id not in members[room.id]:
                session.add(RoomMember(room_id=room.id, user_id=bot_id))
                changed.add(room.id)
    # 실제 사용자가 없는 방이나 멀어진 봇은 나간다
    for (rid, bot_id), m in bot_rows.items():
        room = rooms[rid]
        pos = placed.get(bot_id)
        alive = room in live_rooms and pos is not None
        if not alive or geo.haversine_m(room.center_lat, room.center_lng, pos[0], pos[1]) > s.room_leave_m:
            m.left_at = now
            changed.add(rid)
    if changed:
        await session.commit()
        for rid in changed:
            out = await room_out(session, rooms[rid], "")
            await publish(
                room_channel(rid), {"type": "members", "member_count": out.member_count, "avatars": out.avatars}
            )
    return live_rooms


async def _room_bots(session, room_id: str) -> list[User]:
    rows = (
        await session.execute(
            select(User)
            .join(RoomMember, RoomMember.user_id == User.id)
            .where(RoomMember.room_id == room_id, RoomMember.left_at.is_(None))
        )
    ).scalars().all()
    return [u for u in rows if is_bot(u.id)]


async def _ambient(session, live_rooms: list[Room]) -> None:
    """방마다 1~2분에 한 번 봇 한 명이 동네 이야기를 한다."""
    r = get_redis()
    for room in live_rooms:
        if not await r.set(f"demo:ambient:{room.id}", "1", ex=random.randint(60, 120), nx=True):
            continue
        bots = await _room_bots(session, room.id)
        if bots:
            await post_message(session, room_id=room.id, user=random.choice(bots), body=random.choice(AMBIENT))


async def tick() -> None:
    bots = await ensure_bots()
    if not bots:
        return
    anchors = await _anchors()
    placed: dict[str, tuple[float, float]] = {}
    if anchors:
        for i, bot_id in enumerate(bots):
            uid, lat, lng = anchors[i % len(anchors)]
            bearing, dist = _offset(bot_id)
            # 살짝 흔들어 살아 있는 것처럼
            jitter = get_settings().radius_m * 0.02
            b_lat, b_lng = _move(lat, lng, bearing + random.uniform(-0.05, 0.05), dist + random.uniform(-jitter, jitter))
            await _place(bot_id, b_lat, b_lng)
            placed[bot_id] = (b_lat, b_lng)
    async with sessionmaker()() as session:
        live_rooms = await _sync_rooms(session, placed)
        await _ambient(session, live_rooms)


def _reply_for(body: str, title: str) -> str | None:
    """분류된 주제 제목을 넣어 답한다. 제목이 그대로 들어가야 다음 분류에서 같은 주제로 묶인다."""
    if title and not title.endswith("이야기"):
        return random.choice(REPLY_BY_ENTITY).format(t=title)
    text = body.lower()
    for cat, words in _rule.keywords.items():
        if any(w.lower() in text for w in words):
            return REPLY_BY_CATEGORY.get(cat)
    return random.choice(REPLY_BY_ENTITY).format(t=title) if title else None


async def _reply_later(room_id: str, body: str, delay: float) -> None:
    await asyncio.sleep(delay)
    try:
        async with sessionmaker()() as session:
            room = await session.get(Room, room_id)
            if room is None or room.closed_at is not None:
                return
            bots = await _room_bots(session, room_id)
            if bots:
                await post_message(session, room_id=room_id, user=random.choice(bots), body=body)
    except Exception:
        log.exception("demo reply failed")


def on_room_message(job: dict, outcome: JobOutcome) -> None:
    """실제 사용자의 방 메시지에 봇이 반응한다. 토픽이 될 말이면 같은 주제로 답해 토픽을 확정시킨다."""
    if not _bot_ids or is_bot(job.get("user_id")):
        return
    body = job.get("body", "")
    reply = _reply_for(body, outcome.title) if outcome.status in ("candidate", "confirmed", "reminder") else None
    if reply is None:
        if outcome.status == "skip" or random.random() > 0.35:
            return
        reply = random.choice(GREETINGS)
    task = asyncio.create_task(_reply_later(job["room_id"], reply, random.uniform(3, 7)))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)

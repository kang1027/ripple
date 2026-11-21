"""시연용 데모 봇 (DEMO_BOTS=N).

- 위치를 보내는 실제 사용자 주변(반경의 25~85%)에 봇을 띄운다. 사용자가 움직이면 따라간다.
- 실제 사용자가 들어간 방에 봇도 들어가고, 가끔 동네 이야기를 한다.
- 실제 사용자가 토픽이 될 말을 하면 봇 하나가 몇 초 뒤 같은 주제로 답해 토픽 카드가 뜨게 한다.

DEMO_SCRIPT=true면 녹화용 대본 모드로 돈다 (아래 '대본 모드' 참고).

봇은 auth_identities.provider = "demo" 로 구분한다. 로그인 수단이 없어 앱으로는 접속할 수 없다.

재촬영 전 대본 방 지우기: python -m app.services.demo reset
"""

import asyncio
import hashlib
import json
import logging
import math
import random
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image, ImageDraw
from sqlalchemy import delete, select

from ..config import get_settings
from ..db import sessionmaker
from ..models import AuthIdentity, Message, MessageType, Room, RoomMember, Topic, TopicMember, User, UserStatus, new_id
from ..redis_client import get_redis
from ..schemas import AVATAR_OPTIONS
from . import geo
from .chat import post_message, publish, room_channel, room_out, topic_out
from .topics import JobOutcome, RuleClassifier, confirm_topic, same_topic

log = logging.getLogger("ripple.demo")

PROVIDER = "demo"
TICK_S = 5

NICKNAMES = [
    "산책하는고양이",
    "동네주민",
    "커피두잔",
    "퇴근길",
    "오늘도맑음",
    "골목탐험가",
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


def _character(index: int) -> dict:
    """봇마다 고정된 캐릭터. 저장해 두지 않으면 앱이 홈과 채팅에서 서로 다른 캐릭터를 그린다."""
    pick = {k: opts[(index * (n + 1) + n) % len(opts)] for n, (k, opts) in enumerate(AVATAR_OPTIONS.items())}
    pick["float_color"] = AVATAR_OPTIONS["float_color"][index % len(AVATAR_OPTIONS["float_color"])]
    pick["prop"] = "none" if index % 3 else AVATAR_OPTIONS["prop"][1 + index % 3]
    return pick


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
            nickname = NICKNAMES[i]
            taken = (await session.execute(select(User).where(User.nickname == nickname))).scalar_one_or_none()
            if ident is None:
                if taken is not None:
                    nickname = f"{nickname[:20]}{i:02d}"
                user = User(nickname=nickname, avatar_url=_avatar(i), avatar=_character(i), status=UserStatus.ACTIVE)
                session.add(user)
                await session.flush()
                session.add(AuthIdentity(user_id=user.id, provider=PROVIDER, provider_uid=uid))
                await session.commit()
                ids.append(user.id)
            else:
                # 예전에 만든 봇은 이름·캐릭터를 지금 목록에 맞춘다
                user = await session.get(User, ident.user_id)
                if user is not None:
                    if user.avatar is None:
                        user.avatar = _character(i)
                    if user.nickname != nickname and taken is None:
                        user.nickname = nickname
                    await session.commit()
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
    """실제 사용자가 있는 방에 근처 봇을 넣고, 멀어진 봇은 내보낸다. 실제 사용자가 있는 방 목록을 돌려준다.
    대본 모드에서는 대본 방만 살아 있는 방으로 보고, 봇은 거리와 상관없이 대본 방에 머문다."""
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

    scripted = script_on()
    if scripted:
        live_rooms = [rooms[rid] for rid in members if is_script_room(rid)]
    else:
        live_rooms = [rooms[rid] for rid, uids in members.items() if any(not is_bot(u) for u in uids)]
    changed: set[str] = set()
    for room in live_rooms:
        for bot_id, (lat, lng) in placed.items():
            # 방 중심은 격자로 반올림돼 사용자와 최대 ~106m 어긋나서, 나가는 기준(300m)으로 본다
            near = scripted or geo.haversine_m(room.center_lat, room.center_lng, lat, lng) <= s.room_leave_m
            if near and bot_id not in members[room.id]:
                session.add(RoomMember(room_id=room.id, user_id=bot_id))
                changed.add(room.id)
    # 실제 사용자가 없는 방이나 멀어진 봇은 나간다
    for (rid, bot_id), m in bot_rows.items():
        room = rooms[rid]
        if scripted and room in live_rooms:
            continue
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
        if script_on() and anchors:
            await _ensure_script_room(session, bots, anchors[0][1], anchors[0][2])
        live_rooms = await _sync_rooms(session, placed)
        if not script_on():
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


def _spawn(coro) -> None:
    task = asyncio.create_task(coro)
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


def on_room_message(job: dict, outcome: JobOutcome) -> None:
    """실제 사용자의 방 메시지에 봇이 반응한다. 토픽이 될 말이면 같은 주제로 답해 토픽을 확정시킨다."""
    if not _bot_ids or is_bot(job.get("user_id")):
        return
    if script_on() and is_script_room(job.get("room_id", "")):
        _spawn(_script_room_reply(job, outcome))
        return
    body = job.get("body", "")
    reply = _reply_for(body, outcome.title) if outcome.status in ("candidate", "confirmed", "reminder") else None
    if reply is None:
        if outcome.status == "skip" or random.random() > 0.35:
            return
        reply = random.choice(GREETINGS)
    _spawn(_reply_later(job["room_id"], reply, random.uniform(3, 7)))


# ---------- 대본 모드 (DEMO_SCRIPT=true) ----------
#
# 녹화용. 실제 사용자가 앱을 켜면 그 자리에 '이미 대화가 오가던' 동네방을 하나 만들어 둔다.
# 과거 대화와 토픽 두 개(대화 포함)가 미리 들어 있고, 사용자가 들어와 말하면 정해진 순서로 봇이 답한다.
#   1) 사용자의 첫 말 → 봇 둘이 인사, 이어서 한 명이 영화를 제안
#   2) 사용자가 영화 제목을 말함 → 제안한 봇이 같은 제목으로 맞장구 → 토픽 확정(카드)
#      → 다른 봇 하나가 "이번엔 바빠서 힘들다"고 빠짐
#   3) 토픽방에서 사용자가 말할 때마다 봇이 대본 순서대로 답함. 미리 만든 토픽에 참여하면 환영 인사
# 대본 대사는 토픽 분류에 넣지 않는다. 넣으면 봇 제안이 먼저 후보가 돼 토픽 제목이 엉뚱해진다.

SCRIPT_ROOM_PREFIX = "demo"
# 대본 대사 사이 간격에 곱한다 (테스트는 0)
DELAY_SCALE = 1.0

# 방에 미리 쌓아 둘 대화. (봇 번호, 대사, 몇 분 전) 또는 ("topic", 토픽 키, 몇 분 전)
SEED_ROOM: list[tuple] = [
    (0, "다들 이 근처 사세요? ㅎㅎ", 42),
    (2, "저는 회사가 바로 앞이에요", 41),
    (1, "저는 이 동네 산 지 3년째요", 40),
    (6, "혹시 근처에 소금빵 맛있는 빵집 있어요?", 38),
    (2, "골목 안쪽에 새로 생긴 빵집 소금빵 진짜 맛있어요", 37),
    ("topic", "bread", 37),
    (0, "오 거기 저도 가봤어요! 오후엔 금방 품절돼요", 36),
    (7, "오늘 저녁에 공원에서 러닝 하실 분 있어요?", 30),
    (3, "저요! 퇴근하고 뛰려고 했어요", 29),
    ("topic", "run", 29),
    (5, "오늘 하늘 진짜 맑네요", 21),
    (4, "이따 노을 예쁠 것 같아요 ㅎㅎ", 20),
    (1, "저녁 뭐 드실 거예요?", 12),
    (5, "저는 근처 국밥집 가려고요", 11),
    (4, "오늘 여기 사람 많네요 ㅎㅎ", 4),
]

SEED_TOPICS: dict[str, dict] = {
    "bread": {
        "title": "소금빵 맛집",
        "summary": "골목 안에 새로 생긴 빵집 소금빵 이야기",
        "category": "cafe",
        "members": [6, 2, 0],
        "messages": [
            (6, "위치 정확히 어디쯤이에요?", 36),
            (2, "편의점 끼고 골목으로 들어가면 바로 보여요", 35),
            (0, "오후 3시쯤 가면 갓 나온 거 살 수 있어요", 34),
            (6, "내일 바로 가봐야겠다 ㅎㅎ", 33),
        ],
        "welcome": (2, "어서 오세요! 여기 소금빵 얘기 중이에요 ㅎㅎ"),
        "lines": ["오후 3시쯤 가면 갓 나온 거 있어요!", "버터 소금빵이 제일 맛있어요", "다음에 같이 가요 ㅎㅎ"],
    },
    "run": {
        "title": "저녁 공원 러닝",
        "summary": "퇴근하고 근처 공원에서 같이 뛰기",
        "category": "sports",
        "members": [7, 3],
        "messages": [
            (7, "7시에 공원 입구에서 만날까요?", 28),
            (3, "좋아요! 5km 정도 가볍게 뛰어요", 27),
            (7, "저 주황색 바람막이 입고 갈게요", 26),
        ],
        "welcome": (7, "오 환영해요! 7시에 공원 입구에서 모여요"),
        "lines": ["페이스는 천천히 맞춰서 뛰어요 ㅎㅎ", "끝나고 편의점에서 음료 한 잔 해요", "그럼 이따 봬요!"],
    },
}

# 사용자가 들어와 처음 말했을 때. (봇 번호, 대사, 앞 대사 뒤 몇 초)
SCRIPT_GREETINGS = [(0, "안녕하세요! 반가워요 ㅎㅎ", 2.0), (1, "오 어서 오세요~", 2.5)]
PROPOSER = 4
PROPOSAL = ("다들 시간 괜찮으시면 영화 한 편 볼까요?", 5.5)
# 제목이 그대로 들어가야 분류기가 사용자 말과 같은 주제로 묶어 토픽을 확정한다
AGREE = ("오 {t} 좋아요! 저도 보고 싶었어요 ㅎㅎ", 3.0)
DECLINER = 3
DECLINE = ("저는 이번 주엔 바빠서 힘들 것 같아요 ㅠㅠ 재밌게 보세요!", 9.0)
# 맞장구 뒤 이만큼 기다려도 토픽이 안 생기면(분류기가 안 묶음) 직접 확정한다
CONFIRM_GRACE_S = 7.0
LIVE_TOPIC_LINES = {
    "movie": ["토요일 저녁 7시 어때요?", "좋아요! 근처 영화관으로 예매해 둘게요", "그럼 토요일에 봬요 ㅎㅎ"],
}
GENERIC_TOPIC_LINES = ["오 좋아요 ㅎㅎ", "그거 완전 공감이에요", "다음에 같이 해요!"]
REMINDER_REPLY = "그 얘기 토픽방에서 하고 있어요! 카드 눌러서 들어와 보세요 ㅎㅎ"


def script_on() -> bool:
    s = get_settings()
    return s.demo_script and s.demo_bots > 0


def is_script_room(room_id: str) -> bool:
    return room_id.startswith(SCRIPT_ROOM_PREFIX)


def _bot(bots: list[str], index: int) -> str:
    return bots[index % len(bots)]


async def purge_script_rooms(session, room_ids: list[str]) -> None:
    """대본 방을 대화·토픽까지 통째로 지운다. 재촬영 때 '참여한 방'에 지난 촬영이 남지 않게."""
    if not room_ids:
        return
    topic_ids = select(Topic.id).where(Topic.room_id.in_(room_ids))
    await session.execute(delete(TopicMember).where(TopicMember.topic_id.in_(topic_ids)))
    await session.execute(delete(Message).where(Message.room_id.in_(room_ids)))
    await session.execute(delete(Topic).where(Topic.room_id.in_(room_ids)))
    await session.execute(delete(RoomMember).where(RoomMember.room_id.in_(room_ids)))
    await session.execute(delete(Room).where(Room.id.in_(room_ids)))
    await session.commit()
    await get_redis().zrem(geo.ROOMS_GEO, *room_ids)


async def _ensure_script_room(session, bots: list[str], lat: float, lng: float) -> None:
    """열린 대본 방이 없으면 만든다. 서버가 재시작돼 봇 대사 순서를 잃은 방과 닫힌 방은 지운다."""
    r = get_redis()
    rows = (await session.execute(select(Room).where(Room.id.like(f"{SCRIPT_ROOM_PREFIX}%")))).scalars().all()
    keep = [room for room in rows if room.closed_at is None and await r.exists(f"demo:seeded:{room.id}")]
    if keep:
        return
    await purge_script_rooms(session, [room.id for room in rows])
    room = await _seed(session, bots, lat, lng)
    log.info("demo script room seeded: %s", room.id)


async def _seed(session, bots: list[str], lat: float, lng: float) -> Room:
    s = get_settings()
    r = get_redis()
    now = datetime.now(timezone.utc)

    def ago(minutes: float) -> datetime:
        return now - timedelta(minutes=minutes)

    c_lat, c_lng = geo.snap_center(lat, lng, geo.room_grid_m(s.radius_m))
    room = Room(
        id=SCRIPT_ROOM_PREFIX + new_id()[: 32 - len(SCRIPT_ROOM_PREFIX)],
        center_lat=c_lat,
        center_lng=c_lng,
        area_name=await geo.area_name(lat, lng),
        created_at=ago(45),
    )
    session.add(room)
    await session.flush()
    for bot_id in bots:
        session.add(RoomMember(room_id=room.id, user_id=bot_id, joined_at=ago(45)))

    for entry in SEED_ROOM:
        if entry[0] == "topic":
            spec = SEED_TOPICS[entry[1]]
            at = ago(entry[2])
            topic = Topic(
                room_id=room.id,
                title=spec["title"],
                summary=spec["summary"],
                category=spec["category"],
                created_at=at,
                last_message_at=at,
            )
            session.add(topic)
            await session.flush()
            for i in spec["members"]:
                session.add(TopicMember(topic_id=topic.id, user_id=_bot(bots, i), joined_at=at))
            await session.flush()
            card = (await topic_out(session, topic)).model_dump(mode="json") | {"topic_id": topic.id, "reminder": False}
            session.add(
                Message(
                    room_id=room.id, type=MessageType.TOPIC_CARD, body=f"새 토픽: {topic.title}", meta=card, created_at=at
                )
            )
            for i, body, minutes in spec["messages"]:
                session.add(
                    Message(room_id=room.id, topic_id=topic.id, user_id=_bot(bots, i), body=body, created_at=ago(minutes))
                )
                topic.last_message_at = ago(minutes)
            welcome_bot, welcome = spec["welcome"]
            await r.set(f"demo:welcome:{topic.id}", json.dumps([_bot(bots, welcome_bot), welcome], ensure_ascii=False))
            await r.delete(f"demo:lines:{topic.id}")
            await r.rpush(f"demo:lines:{topic.id}", *spec["lines"])
            await r.set(f"demo:init:{topic.id}", "1")
        else:
            i, body, minutes = entry
            session.add(Message(room_id=room.id, user_id=_bot(bots, i), body=body, created_at=ago(minutes)))
        # 메시지는 id 순서로 보이므로 하나씩 넣어 시간 순서와 맞춘다
        await session.flush()
    await session.commit()
    await r.geoadd(geo.ROOMS_GEO, [c_lng, c_lat, room.id])
    await r.set(f"demo:seeded:{room.id}", "1")
    return room


async def _say(
    room_id: str, bot_id: str, body: str, *, topic_id: str | None = None, classify: bool = False
) -> int | None:
    """봇 한 명이 말한다. 방이 닫혔거나 봇이 빠졌으면 말하지 않는다. 보낸 메시지 id."""
    async with sessionmaker()() as session:
        room = await session.get(Room, room_id)
        bot = await session.get(User, bot_id)
        if room is None or room.closed_at is not None or bot is None:
            return None
        out = await post_message(session, room_id=room_id, user=bot, body=body, topic_id=topic_id, classify=classify)
        return out.id


async def _pause(seconds: float) -> None:
    if seconds * DELAY_SCALE > 0:
        await asyncio.sleep(seconds * DELAY_SCALE)


async def _script_room_reply(job: dict, outcome: JobOutcome) -> None:
    try:
        await _script_room_step(job, outcome)
    except Exception:
        log.exception("demo script reply failed")


async def _script_room_step(job: dict, outcome: JobOutcome) -> None:
    room_id = job["room_id"]
    bots = _bot_ids
    r = get_redis()
    stage_key = f"demo:stage:{room_id}"
    stage = await r.get(stage_key)

    # 2) 영화 제목 → 맞장구로 토픽 확정, 한 명은 빠짐
    if stage != "topic" and outcome.status == "candidate" and outcome.title:
        await r.set(stage_key, "topic")
        text, wait = AGREE
        await _pause(wait)
        await _say(room_id, _bot(bots, PROPOSER), text.format(t=outcome.title), classify=True)
        await _pause(CONFIRM_GRACE_S)
        await _confirm_if_missing(room_id, job["user_id"], outcome.title)
        text, wait = DECLINE
        await _pause(max(wait - CONFIRM_GRACE_S, 0))
        await _say(room_id, _bot(bots, DECLINER), text)
        return

    # 1) 첫 말 → 인사 둘, 영화 제안
    if stage is None:
        await r.set(stage_key, "proposed")
        for i, text, wait in SCRIPT_GREETINGS:
            await _pause(wait)
            await _say(room_id, _bot(bots, i), text)
        text, wait = PROPOSAL
        await _pause(wait)
        await _say(room_id, _bot(bots, PROPOSER), text)
        return

    # 대본 밖: 다른 주제를 말하면 평소처럼 봇이 같은 주제로 받아 준다
    if outcome.status == "candidate" and outcome.title:
        await _pause(3)
        others = [b for b in bots if b != _bot(bots, PROPOSER)] or bots
        await _say(room_id, random.choice(others), random.choice(REPLY_BY_ENTITY).format(t=outcome.title), classify=True)
    elif outcome.status == "reminder":
        await _pause(3)
        await _say(room_id, random.choice(bots), REMINDER_REPLY)


async def _confirm_if_missing(room_id: str, user_id: str, title: str) -> None:
    """맞장구를 쳤는데도 분류기가 같은 주제로 안 묶었으면 사용자의 후보로 토픽을 직접 확정한다."""
    r = get_redis()
    async with sessionmaker()() as session:
        room = await session.get(Room, room_id)
        if room is None or room.closed_at is not None:
            return
        topics = (await session.execute(select(Topic).where(Topic.room_id == room_id))).scalars().all()
        if any(same_topic(t.title, title) for t in topics):
            return
        key = f"topic_cand:{room_id}"
        for cid, raw in (await r.hgetall(key)).items():
            cand = json.loads(raw)
            if cand["user_id"] != user_id or not same_topic(cand["title"], title):
                continue
            await r.hdel(key, cid)
            await confirm_topic(
                session,
                room,
                title=cand["title"],
                summary=cand.get("summary") or "",
                category=cand.get("category") or "etc",
                user_ids={user_id, _bot(_bot_ids, PROPOSER)},
            )
            log.info("demo script confirmed topic directly: %s", cand["title"])
            return


def on_demo_job(job: dict) -> None:
    """토픽방 메시지·참여에 봇이 반응한다 (대본 모드에서만)."""
    if not _bot_ids or not script_on() or is_bot(job.get("user_id")):
        return
    _spawn(_topic_reply(job))


async def _topic_reply(job: dict) -> None:
    try:
        await _topic_step(job)
    except Exception:
        log.exception("demo topic reply failed")


async def _topic_step(job: dict) -> None:
    topic_id = job["topic_id"]
    r = get_redis()
    async with sessionmaker()() as session:
        topic = await session.get(Topic, topic_id)
        if topic is None or not is_script_room(topic.room_id):
            return
        members = (
            await session.execute(select(TopicMember.user_id).where(TopicMember.topic_id == topic_id))
        ).scalars().all()
        room_id, category = topic.room_id, topic.category
    bot_members = [m for m in members if is_bot(m)]
    if not bot_members:
        return

    if job["kind"] == "topic_join":
        raw = await r.get(f"demo:welcome:{topic_id}")
        if raw:
            bot_id, text = json.loads(raw)
            await _pause(2.5)
            await _say(room_id, bot_id if bot_id in bot_members else bot_members[0], text, topic_id=topic_id)
        return

    if await r.set(f"demo:init:{topic_id}", "1", nx=True):
        # 사용자가 연 토픽(영화 등)은 카테고리에 맞는 대사를 쓴다
        await r.rpush(f"demo:lines:{topic_id}", *LIVE_TOPIC_LINES.get(category, GENERIC_TOPIC_LINES))
    line = await r.lpop(f"demo:lines:{topic_id}")
    if line is None:
        return
    await _pause(random.uniform(2.5, 4.0))
    await _say(room_id, random.choice(bot_members), line, topic_id=topic_id)


async def reset() -> int:
    """대본 방을 전부 지운다. 서버는 다음 tick(5초)에 새 대본 방을 만든다. 지운 방 수."""
    async with sessionmaker()() as session:
        ids = (
            await session.execute(select(Room.id).where(Room.id.like(f"{SCRIPT_ROOM_PREFIX}%")))
        ).scalars().all()
        await purge_script_rooms(session, list(ids))
    return len(ids)


if __name__ == "__main__":
    if sys.argv[1:] == ["reset"]:
        print(f"대본 방 {asyncio.run(reset())}개를 지웠어요. 5초 안에 새로 만들어져요")
    else:
        print("사용법: python -m app.services.demo reset")

"""백그라운드 작업: 토픽 분류 큐, presence 정리, 방 종료, 메시지 만료.

단독 실행: python -m app.worker
개발 중에는 RUN_WORKER_INLINE=true 로 api 프로세스 안에서 같이 돈다.
"""

import asyncio
import json
import logging
import time
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, func, select, update

from .config import get_settings
from .db import create_all, sessionmaker
from .models import Message, Room, RoomMember
from .redis_client import get_redis
from .services import demo, geo
from .services.chat import DEMO_JOBS, TOPIC_JOBS, forget_replies_to
from .services.topics import process_job

log = logging.getLogger("ripple.worker")


async def cleanup_presence() -> int:
    r = get_redis()
    cutoff = time.time() - get_settings().presence_ttl_s
    stale = await r.zrangebyscore(geo.PRESENCE_TS, 0, cutoff)
    for uid in stale:
        await r.zrem(geo.PRESENCE, uid)
        await r.zrem(geo.PRESENCE_TS, uid)
    return len(stale)


async def close_idle_rooms() -> int:
    s = get_settings()
    r = get_redis()
    cutoff_ts = time.time() - s.presence_ttl_s
    idle_before = datetime.now(timezone.utc) - timedelta(seconds=s.room_idle_close_s)
    closed = 0
    async with sessionmaker()() as session:
        rooms = (await session.execute(select(Room).where(Room.closed_at.is_(None)))).scalars().all()
        for room in rooms:
            member_ids = (
                await session.execute(
                    select(RoomMember.user_id).where(RoomMember.room_id == room.id, RoomMember.left_at.is_(None))
                )
            ).scalars().all()
            online = False
            for uid in member_ids:
                ts = await r.zscore(geo.PRESENCE_TS, uid)
                if ts is not None and ts >= cutoff_ts:
                    online = True
                    break
            if online:
                continue
            last_msg = (
                await session.execute(select(func.max(Message.created_at)).where(Message.room_id == room.id))
            ).scalar_one()
            last = last_msg or room.created_at
            if last.tzinfo is None:
                last = last.replace(tzinfo=timezone.utc)
            if last > idle_before:
                continue
            room.closed_at = datetime.now(timezone.utc)
            await session.execute(
                update(RoomMember)
                .where(RoomMember.room_id == room.id, RoomMember.left_at.is_(None))
                .values(left_at=room.closed_at)
            )
            await r.zrem(geo.ROOMS_GEO, room.id)
            closed += 1
        await session.commit()
    return closed


async def expire_messages() -> None:
    cutoff = datetime.now(timezone.utc) - timedelta(hours=get_settings().message_retention_h)
    async with sessionmaker()() as session:
        await forget_replies_to(session, Message.created_at < cutoff)
        await session.execute(delete(Message).where(Message.created_at < cutoff))
        await session.commit()


async def run(stop: asyncio.Event | None = None) -> None:
    r = get_redis()
    last_maint = 0.0
    last_expire = 0.0
    last_demo = 0.0
    demo_on = get_settings().demo_bots > 0
    if not demo_on:
        try:
            await demo.retire()
        except Exception:
            log.exception("demo retire failed")
    while stop is None or not stop.is_set():
        try:
            item = await r.blpop([TOPIC_JOBS, DEMO_JOBS], timeout=1)
            if item and item[0] == DEMO_JOBS:
                if demo_on:
                    demo.on_demo_job(json.loads(item[1]))
            elif item:
                job = json.loads(item[1])
                async with sessionmaker()() as session:
                    outcome = await process_job(session, job)
                log.info("topic job %s -> %s %s", job.get("message_id"), outcome.status, outcome.title)
                if demo_on:
                    demo.on_room_message(job, outcome)
            now = time.time()
            if demo_on and now - last_demo > demo.TICK_S:
                last_demo = now
                await demo.tick()
            if now - last_maint > 10:
                last_maint = now
                await cleanup_presence()
                await close_idle_rooms()
            if now - last_expire > 3600:
                last_expire = now
                await expire_messages()
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("worker loop error")
            await asyncio.sleep(1)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)

    async def main() -> None:
        await create_all()
        await run()

    asyncio.run(main())

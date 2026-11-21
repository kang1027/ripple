"""실시간 채팅. 방·토픽마다 Redis Pub/Sub 채널 하나.

클라이언트 → 서버: {"type":"send","body":"...","client_id":"..."} | {"type":"ping"}
서버 → 클라이언트: message | members | topic_created | out_of_range | pong | error
"""

import asyncio
import json
import logging
import time

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect

from ..db import sessionmaker
from ..models import Topic, User
from ..redis_client import get_redis
from ..security import load_user
from ..services import notify
from ..services.chat import (
    active_membership,
    blocked_ids,
    is_topic_member,
    post_message,
    room_channel,
    topic_channel,
)

router = APIRouter()
log = logging.getLogger("ripple.ws")
MEMBERSHIP_CHECK_S = 10


async def _authorize(kind: str, target_id: str, token: str) -> tuple[User, str, str | None] | None:
    """(user, room_id, topic_id) 또는 None."""
    async with sessionmaker()() as session:
        try:
            user = await load_user(token, session)
        except HTTPException:
            return None
        if kind == "room":
            if await active_membership(session, target_id, user.id) is None:
                return None
            return user, target_id, None
        topic = await session.get(Topic, target_id)
        if topic is None or not await is_topic_member(session, target_id, user.id):
            return None
        return user, topic.room_id, topic.id


async def _serve(ws: WebSocket, kind: str, target_id: str, token: str) -> None:
    auth = await _authorize(kind, target_id, token)
    if auth is None:
        await ws.close(code=4403)
        return
    user, room_id, topic_id = auth
    await ws.accept()

    channel = topic_channel(topic_id) if topic_id else room_channel(room_id)
    async with sessionmaker()() as session:
        hidden = await blocked_ids(session, user.id)

    pubsub = get_redis().pubsub()
    await pubsub.subscribe(channel)
    await notify.mark_online(channel, user.id)

    async def still_member() -> bool:
        async with sessionmaker()() as session:
            return await active_membership(session, room_id, user.id) is not None

    async def pump() -> None:
        last_check = time.monotonic()
        while True:
            # 방에서 빠진 뒤(범위 이탈·나가기·다른 방으로 이동)에는 이 소켓으로 더 보내지 않는다
            if time.monotonic() - last_check >= MEMBERSHIP_CHECK_S:
                last_check = time.monotonic()
                if not await still_member():
                    await ws.close(code=4403)
                    return
            msg = await pubsub.get_message(ignore_subscribe_messages=True, timeout=1.0)
            if msg is None:
                continue
            data = msg["data"]
            try:
                event = json.loads(data)
            except (TypeError, ValueError):
                continue
            if event.get("type") == "out_of_range" and event.get("user_id") == user.id:
                await ws.send_text(data if isinstance(data, str) else data.decode())
                await ws.close(code=4403)
                return
            sender = (event.get("message") or {}).get("sender") or {}
            if sender.get("id") in hidden:
                continue
            await ws.send_text(data if isinstance(data, str) else data.decode())

    pump_task = asyncio.create_task(pump())
    try:
        while True:
            data = await ws.receive_json()
            await notify.touch_online(channel, user.id)
            kind_ = data.get("type")
            if kind_ == "ping":
                await ws.send_json({"type": "pong"})
            elif kind_ == "send":
                body = str(data.get("body", "")).strip()
                if not body:
                    continue
                async with sessionmaker()() as session:
                    if await active_membership(session, room_id, user.id) is None:
                        await ws.send_json({"type": "error", "code": "read_only"})
                        continue
                    if topic_id and not await is_topic_member(session, topic_id, user.id):
                        await ws.send_json({"type": "error", "code": "not_in_topic"})
                        continue
                    member = await session.get(User, user.id)
                    await post_message(
                        session,
                        room_id=room_id,
                        topic_id=topic_id,
                        user=member,
                        body=body,
                        client_id=data.get("client_id"),
                    )
    except WebSocketDisconnect:
        pass
    except Exception:
        log.exception("ws error")
    finally:
        pump_task.cancel()
        try:
            await notify.mark_offline(channel, user.id)
        except Exception:
            pass
        try:
            await pubsub.unsubscribe(channel)
            await pubsub.aclose()
        except Exception:
            pass


@router.websocket("/ws/rooms/{room_id}")
async def ws_room(ws: WebSocket, room_id: str, token: str = ""):
    await _serve(ws, "room", room_id, token)


@router.websocket("/ws/topics/{topic_id}")
async def ws_topic(ws: WebSocket, topic_id: str, token: str = ""):
    await _serve(ws, "topic", topic_id, token)

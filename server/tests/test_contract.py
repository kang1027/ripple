"""디자인 개편(답장·토픽 유지·알림 끄기·캐릭터)용 서버 계약."""

import asyncio
import json

import pytest

from app.config import get_settings
from app.db import sessionmaker
from app.services import apns, notify
from app.services.topics import RuleClassifier, process_job

from .conftest import auth, onboard
from .test_flow import LAT, LNG, _phone, _uniq

AVATAR = {
    "hair": "curly", "hair_color": "cocoa", "skin": "warm", "eyewear": "snorkel", "eyes": "dot", "nose": "button",
    "mouth": "smile", "body": "round", "outfit": "rashguard", "clothes": "blue", "float": "ring",
    "float_color": "blue", "prop": "none",
}


def _at(client, t, lat, lng=LNG):
    r = client.post("/presence", json={"lat": lat, "lng": lng, "accuracy": 5}, headers=auth(t))
    assert r.json()["ok"], r.text
    return r.json()


def _pair_in_room(client, lat):
    a = onboard(client, _uniq("ca"), _phone())
    b = onboard(client, _uniq("cb"), _phone())
    _at(client, a, lat)
    _at(client, b, lat + 0.00002)
    room = client.post("/rooms/join", headers=auth(a)).json()["id"]
    assert client.post("/rooms/join", headers=auth(b)).json()["id"] == room
    return a, b, room


def _drain_topics(client):
    async def run():
        from app.redis_client import get_redis

        r = get_redis()
        out = []
        while (item := await r.lpop("topic_jobs")) is not None:
            async with sessionmaker()() as session:
                out.append((await process_job(session, json.loads(item), RuleClassifier())).status)
        return out

    return client.portal.call(run)


def test_reply_in_room_and_topic_card(client):
    a, b, room = _pair_in_room(client, LAT + 0.21)
    with client.websocket_connect(f"/ws/rooms/{room}?token={a}") as wa:
        wa.send_json({"type": "send", "body": "오늘 불꽃놀이 보러 갈 사람?"})
        first = wa.receive_json()["message"]
        wa.send_json({"type": "send", "body": "아니면 내일도 괜찮아요", "reply_to": first["id"]})
        reply = wa.receive_json()["message"]
        assert reply["reply"] == {"id": first["id"], "sender_id": first["sender"]["id"],
                                  "nickname": first["sender"]["nickname"], "body": first["body"][:80]}
        # 다른 방 메시지에는 답장이 붙지 않는다
        wa.send_json({"type": "send", "body": "그냥 메시지예요", "reply_to": 999999})
        assert wa.receive_json()["message"]["reply"] is None

    with client.websocket_connect(f"/ws/rooms/{room}?token={b}") as wb:
        wb.send_json({"type": "send", "body": "저도 불꽃놀이 갈래요!"})
        trigger = wb.receive_json()["message"]
    _drain_topics(client)
    msgs = client.get(f"/rooms/{room}/messages", headers=auth(a)).json()
    card = [m for m in msgs if m["type"] == "topic_card"][-1]
    assert card["reply"]["id"] == trigger["id"]


def test_topic_survives_leaving_room_and_mute_leave(client, monkeypatch, sent_pushes):
    s = get_settings()
    monkeypatch.setattr(s, "radius_m", 10)
    monkeypatch.setattr(s, "room_leave_m", 10)
    monkeypatch.setattr(s, "room_leave_grace_s", 0)
    lat = LAT + 0.23
    a, b, room = _pair_in_room(client, lat)
    for t, body in ((a, "오늘 불꽃놀이 보러 갈 사람?"), (b, "저도 불꽃놀이 갈래요!")):
        with client.websocket_connect(f"/ws/rooms/{room}?token={t}") as w:
            w.send_json({"type": "send", "body": body})
            w.receive_json()
    _drain_topics(client)
    topics = client.get("/me/chats", headers=auth(a)).json()["topics"]
    topic = topics[0]
    assert topic["place_name"] and topic["created_at"] and topic["muted"] is False
    assert topic["cover_url"].endswith(f"/static/topics/bg/{topic['category']}.jpg")
    assert client.get(f"/static/topics/bg/{topic['category']}.jpg").status_code == 200

    # a가 동네방 범위를 벗어나 빠져도 토픽은 목록에 남고, 토픽방에서 계속 말할 수 있다
    m = 1 / 111_320
    _at(client, a, lat + 40 * m)
    assert _at(client, a, lat + 41 * m)["left_rooms"] == [room]
    assert client.get("/me/chats", headers=auth(a)).json()["topics"][0]["id"] == topic["id"]
    assert client.get(f"/topics/{topic['id']}/messages", headers=auth(a)).status_code == 200
    with client.websocket_connect(f"/ws/topics/{topic['id']}?token={a}") as wt:
        wt.send_json({"type": "send", "body": "저 먼저 가 있을게요"})
        assert wt.receive_json()["type"] == "message"

    # 알림 끄면 토픽 메시지 푸시가 안 간다
    client.post("/push/devices", json={"token": "f" * 64}, headers=auth(b))
    assert client.patch(f"/topics/{topic['id']}", json={"muted": True}, headers=auth(b)).json()["muted"] is True
    sent_pushes.clear()
    with client.websocket_connect(f"/ws/topics/{topic['id']}?token={a}") as wt:
        wt.send_json({"type": "send", "body": "다들 어디쯤이에요"})
        wt.receive_json()
    _drain(client)
    assert [c for c in sent_pushes if c["payload"].get("type") == "topic"] == []

    # 토픽 나가기
    assert client.post(f"/topics/{topic['id']}/leave", headers=auth(b)).status_code == 200
    assert all(t["id"] != topic["id"] for t in client.get("/me/chats", headers=auth(b)).json()["topics"])
    assert client.patch(f"/topics/{topic['id']}", json={"muted": False}, headers=auth(b)).status_code == 403


def test_avatar_patch_and_nearby_characters(client):
    a = onboard(client, _uniq("av"), _phone())
    b = onboard(client, _uniq("aw"), _phone())
    assert client.patch("/me", json={"avatar": AVATAR}, headers=auth(a)).json()["avatar"] == AVATAR
    bad = dict(AVATAR, hair="mohawk")
    assert client.patch("/me", json={"avatar": bad}, headers=auth(a)).status_code == 422
    assert client.patch("/me", json={}, headers=auth(a)).status_code == 422
    lat = LAT + 0.25
    _at(client, a, lat)
    _at(client, b, lat + 0.00002)
    near = client.get("/nearby", headers=auth(b)).json()
    assert near["count"] == 1 and near["characters"] == [AVATAR] and len(near["avatars"]) == 1


def test_add_missing_columns_on_old_table():
    from sqlalchemy import create_engine, inspect, text

    from app.db import _add_missing_columns

    eng = create_engine("sqlite://")
    with eng.begin() as conn:
        conn.execute(text("CREATE TABLE topic_members (id INTEGER PRIMARY KEY, topic_id VARCHAR(32), user_id VARCHAR(32), joined_at DATETIME)"))
        conn.execute(text("INSERT INTO topic_members (id, topic_id, user_id) VALUES (1, 't', 'u')"))
        _add_missing_columns(conn)
        cols = {c["name"] for c in inspect(conn).get_columns("topic_members")}
        assert "muted" in cols
        assert conn.execute(text("SELECT muted FROM topic_members")).scalar_one() in (0, False)


def _drain(client):
    async def wait():
        while notify._tasks:
            await asyncio.gather(*list(notify._tasks))

    client.portal.call(wait)


@pytest.fixture()
def sent_pushes(monkeypatch):
    calls: list[dict] = []

    async def fake_send(token, env, payload, collapse_id=None):
        calls.append({"token": token, "payload": payload})
        return apns.SendResult(True, env)

    monkeypatch.setattr(apns, "send", fake_send)
    return calls


def test_reply_preview_hidden_for_block_and_gone_after_delete(client):
    a, b, room = _pair_in_room(client, LAT + 0.27)
    c = onboard(client, _uniq("cc"), _phone())
    _at(client, c, LAT + 0.27 + 0.00001)
    assert client.post("/rooms/join", headers=auth(c)).json()["id"] == room
    with client.websocket_connect(f"/ws/rooms/{room}?token={a}") as wa:
        wa.send_json({"type": "send", "body": "a가 처음 한 말이에요"})
        original = wa.receive_json()["message"]
    with client.websocket_connect(f"/ws/rooms/{room}?token={b}") as wb:
        wb.send_json({"type": "send", "body": "b의 답장이에요", "reply_to": original["id"]})
        wb.receive_json()

    def last_reply(token):
        return client.get(f"/rooms/{room}/messages", headers=auth(token)).json()[-1]["reply"]

    assert last_reply(c)["id"] == original["id"]
    # c가 a를 차단하면 b 답장의 미리보기(a의 말)가 안 보인다
    a_id = client.get("/me", headers=auth(a)).json()["id"]
    client.post("/blocks", json={"user_id": a_id}, headers=auth(c))
    assert last_reply(c) is None
    # a가 탈퇴하면 미리보기가 모두에게서 사라진다
    assert last_reply(b)["id"] == original["id"]
    client.delete("/me", headers=auth(a))
    assert last_reply(b) is None

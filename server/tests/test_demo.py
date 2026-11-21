import json

from app.config import get_settings
from app.db import sessionmaker
from app.services import demo
from app.services.topics import RuleClassifier, process_job

from .conftest import auth, onboard
from .test_flow import LAT, LNG, _phone, _uniq


def test_demo_bots_follow_user_and_join_room(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "demo_bots", 4)
    monkeypatch.setattr(demo, "_bot_ids", [])
    t = onboard(client, _uniq("real"), _phone())
    assert client.post("/presence", json={"lat": LAT, "lng": LNG, "accuracy": 10}, headers=auth(t)).json()["ok"]

    client.portal.call(demo.tick)
    near = client.get("/nearby", headers=auth(t)).json()
    assert near["count"] == 4 and len(near["avatars"]) == 4

    room = client.post("/rooms/join", headers=auth(t)).json()
    client.portal.call(demo.tick)
    assert client.get(f"/rooms/{room['id']}", headers=auth(t)).json()["member_count"] == 5

    # 사용자가 토픽 될 말을 하면 봇이 같은 주제로 답해 토픽이 확정된다
    async def flow():
        from app.redis_client import get_redis
        from app.services.chat import post_message
        from app.models import User

        r = get_redis()
        await r.delete("topic_jobs")
        async with sessionmaker()() as session:
            me = (await session.execute(__import__("sqlalchemy").select(User).where(User.nickname.like("real%")))).scalars().all()[-1]
            await post_message(session, room_id=room["id"], user=me, body="오늘 불꽃놀이 보러 갈 사람?")
        outcomes = []
        item = await r.lpop("topic_jobs")
        job = json.loads(item)
        async with sessionmaker()() as session:
            outcomes.append(await process_job(session, job, RuleClassifier()))
        reply = demo._reply_for(job["body"], outcomes[0].title)
        await demo._reply_later(room["id"], reply, 0)
        item = await r.lpop("topic_jobs")
        bot_job = json.loads(item)
        assert demo.is_bot(bot_job["user_id"])
        async with sessionmaker()() as session:
            outcomes.append(await process_job(session, bot_job, RuleClassifier()))
        return outcomes

    assert [o.status for o in client.portal.call(flow)] == ["candidate", "confirmed"]
    topics = client.get(f"/rooms/{room['id']}/topics", headers=auth(t)).json()
    assert topics and topics[0]["title"] == "불꽃놀이"


def test_demo_bots_leave_without_user(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "demo_bots", 2)
    monkeypatch.setattr(demo, "_bot_ids", [])
    client.portal.call(demo.ensure_bots)
    # 위치를 보내는 실제 사용자가 없으면 봇도 위치를 갱신하지 않는다
    client.portal.call(demo.tick)

    async def fresh():
        from app.redis_client import get_redis

        return [b for b in demo._bot_ids if await get_redis().get(f"presence:last:{b}")]

    assert client.portal.call(fresh) == []


def test_small_radius_same_room_and_bots_inside(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "radius_m", 10)
    monkeypatch.setattr(get_settings(), "demo_bots", 3)
    monkeypatch.setattr(demo, "_bot_ids", [])
    a = onboard(client, _uniq("ra"), _phone())
    b = onboard(client, _uniq("rb"), _phone())
    # 다른 테스트 방과 겹치지 않는 곳, 두 사람은 약 6m 떨어짐
    lat, lng = 37.5700, 126.9800
    client.post("/presence", json={"lat": lat, "lng": lng, "accuracy": 5}, headers=auth(a))
    client.post("/presence", json={"lat": lat + 6 / 111_320, "lng": lng, "accuracy": 5}, headers=auth(b))
    ra = client.post("/rooms/join", headers=auth(a)).json()
    rb = client.post("/rooms/join", headers=auth(b)).json()
    assert ra["id"] == rb["id"]

    client.portal.call(demo.tick)

    async def bot_dists():
        from app.services import geo

        out = []
        for bid in demo._bot_ids:
            pos = await geo.last_position(bid)
            out.append(geo.haversine_m(lat, lng, pos["lat"], pos["lng"]))
        return out

    assert all(d <= 10 for d in client.portal.call(bot_dists))
    assert client.get("/nearby", headers=auth(a)).json()["radius_m"] == 10


def test_retire_bots_when_disabled(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "demo_bots", 2)
    monkeypatch.setattr(demo, "_bot_ids", [])
    t = onboard(client, _uniq("ret"), _phone())
    lat, lng = LAT + 0.08, LNG + 0.08
    assert client.post("/presence", json={"lat": lat, "lng": lng, "accuracy": 10}, headers=auth(t)).json()["ok"]
    room = client.post("/rooms/join", headers=auth(t)).json()
    client.portal.call(demo.tick)
    assert client.get(f"/rooms/{room['id']}", headers=auth(t)).json()["member_count"] == 3

    monkeypatch.setattr(get_settings(), "demo_bots", 0)
    assert client.portal.call(demo.retire) >= 1
    assert client.get(f"/rooms/{room['id']}", headers=auth(t)).json()["member_count"] == 1

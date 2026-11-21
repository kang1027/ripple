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


class _MovieClassifier:
    """'폭설'이 들어간 말만 영화 토픽으로 본다 (실제 운영은 Claude)."""

    async def classify(self, message, recent, known_titles):
        from app.services.topics import TopicResult

        if "폭설" in message:
            return TopicResult(True, "movie", "폭설", "영화 폭설 같이 보기")
        return TopicResult(False)


def _script_mode(monkeypatch):
    monkeypatch.setattr(get_settings(), "demo_bots", 8)
    monkeypatch.setattr(get_settings(), "demo_script", True)
    monkeypatch.setattr(demo, "_bot_ids", [])
    monkeypatch.setattr(demo, "DELAY_SCALE", 0)


async def _user(nickname_prefix: str):
    from sqlalchemy import select

    from app.models import User

    async with sessionmaker()() as session:
        return (await session.execute(select(User).where(User.nickname.like(f"{nickname_prefix}%")))).scalars().all()[-1]


def test_script_room_is_ready_with_history(client, monkeypatch):
    _script_mode(monkeypatch)
    client.portal.call(demo.reset)
    t = onboard(client, _uniq("scr"), _phone())
    lat, lng = 37.6100, 127.0500
    assert client.post("/presence", json={"lat": lat, "lng": lng, "accuracy": 10}, headers=auth(t)).json()["ok"]
    client.portal.call(demo.tick)

    assert client.get("/nearby", headers=auth(t)).json()["count"] == 8
    room = client.post("/rooms/join", headers=auth(t)).json()
    assert demo.is_script_room(room["id"]) and room["member_count"] == 9

    msgs = client.get(f"/rooms/{room['id']}/messages", headers=auth(t)).json()
    texts = [m for m in msgs if m["type"] == "text"]
    cards = [m for m in msgs if m["type"] == "topic_card"]
    assert len(texts) == len([e for e in demo.SEED_ROOM if e[0] != "topic"]) and len(cards) == 2
    assert msgs == sorted(msgs, key=lambda m: m["created_at"])
    topics = client.get(f"/rooms/{room['id']}/topics", headers=auth(t)).json()
    assert {x["title"] for x in topics} == {"소금빵 맛집", "저녁 공원 러닝"}

    # 봇은 앱이 같은 캐릭터를 그리도록 캐릭터 값을 갖고 있다
    from app.schemas import valid_avatar

    assert all(m["sender"]["avatar"] and valid_avatar(m["sender"]["avatar"]) for m in texts)

    # 다음 tick에 다시 만들지 않는다
    client.portal.call(demo.tick)
    assert client.post("/rooms/join", headers=auth(t)).json()["id"] == room["id"]


def test_script_flow_topic_and_replies(client, monkeypatch):
    _script_mode(monkeypatch)
    client.portal.call(demo.reset)
    name = _uniq("flow")
    t = onboard(client, name, _phone())
    lat, lng = 37.6200, 127.0600
    client.post("/presence", json={"lat": lat, "lng": lng, "accuracy": 10}, headers=auth(t))
    client.portal.call(demo.tick)
    room = client.post("/rooms/join", headers=auth(t)).json()
    rid = room["id"]

    async def say(body: str):
        """사용자가 말하고, 워커처럼 분류한 뒤 대본 봇을 돌린다."""
        from app.redis_client import get_redis
        from app.services.chat import post_message

        r = get_redis()
        await r.delete("topic_jobs")
        me = await _user(name)
        async with sessionmaker()() as session:
            await post_message(session, room_id=rid, user=me, body=body)
        job = json.loads(await r.lpop("topic_jobs"))
        async with sessionmaker()() as session:
            outcome = await process_job(session, job, _MovieClassifier())
        await demo._script_room_step(job, outcome)
        # 봇 대사 중 분류에 들어간 것(맞장구)만 남는다
        return [json.loads(x) for x in await r.lrange("topic_jobs", 0, -1)], outcome

    def last_texts(n: int) -> list[str]:
        msgs = client.get(f"/rooms/{rid}/messages", headers=auth(t)).json()
        return [m["body"] for m in msgs if m["type"] == "text"][-n:]

    jobs, outcome = client.portal.call(say, "안녕하세요! 저도 이 근처에서 일해요")
    assert outcome.status == "none" and jobs == []
    assert last_texts(3) == [g[1] for g in demo.SCRIPT_GREETINGS] + [demo.PROPOSAL[0]]

    jobs, outcome = client.portal.call(say, "좋아요! 이번에 폭설 인기 많던데 같이 봐요")
    assert outcome.status == "candidate"
    assert last_texts(2) == [demo.AGREE[0].format(t="폭설"), demo.DECLINE[0]]
    # 분류기보다 대본이 먼저 끝나도 토픽은 하나만 생긴다
    topics = [x for x in client.get(f"/rooms/{rid}/topics", headers=auth(t)).json() if x["title"] == "폭설"]
    assert len(topics) == 1 and topics[0]["is_member"]

    async def process_bot_reply():
        async with sessionmaker()() as session:
            return await process_job(session, jobs[0], _MovieClassifier())

    assert len(jobs) == 1 and client.portal.call(process_bot_reply).status in ("none", "reminder")
    assert len([x for x in client.get(f"/rooms/{rid}/topics", headers=auth(t)).json() if x["title"] == "폭설"]) == 1

    # 토픽방에서 말하면 봇이 대본 순서대로 답한다
    topic_id = topics[0]["id"]

    async def topic_say(body: str):
        from app.redis_client import get_redis
        from app.services.chat import DEMO_JOBS, post_message

        r = get_redis()
        me = await _user(name)
        async with sessionmaker()() as session:
            await post_message(session, room_id=rid, topic_id=topic_id, user=me, body=body)
        await demo._topic_step(json.loads(await r.lpop(DEMO_JOBS)))
        # 봇 대사는 봇 반응을 다시 부르지 않는다
        bot_job = json.loads(await r.lpop(DEMO_JOBS))
        assert demo.is_bot(bot_job["user_id"])

    client.portal.call(topic_say, "주말에 같이 보러 가실래요?")
    msgs = client.get(f"/topics/{topic_id}/messages", headers=auth(t)).json()
    assert msgs[-1]["body"] == demo.LIVE_TOPIC_LINES["movie"][0] and demo.is_bot(msgs[-1]["sender"]["id"])

    # 미리 만든 토픽에 참여하면 환영 인사
    seeded = next(x for x in client.get(f"/rooms/{rid}/topics", headers=auth(t)).json() if x["title"] == "소금빵 맛집")

    async def join_seeded():
        from app.redis_client import get_redis
        from app.services.chat import DEMO_JOBS

        await demo._topic_step(json.loads(await get_redis().lpop(DEMO_JOBS)))

    assert client.post(f"/topics/{seeded['id']}/join", headers=auth(t)).status_code == 200
    client.portal.call(join_seeded)
    msgs = client.get(f"/topics/{seeded['id']}/messages", headers=auth(t)).json()
    assert msgs[-1]["body"] == demo.SEED_TOPICS["bread"]["welcome"][1]


def test_script_reset_wipes_and_reseeds(client, monkeypatch):
    _script_mode(monkeypatch)
    t = onboard(client, _uniq("rst"), _phone())
    lat, lng = 37.6300, 127.0700
    client.post("/presence", json={"lat": lat, "lng": lng, "accuracy": 10}, headers=auth(t))
    client.portal.call(demo.tick)
    first = client.post("/rooms/join", headers=auth(t)).json()["id"]

    assert client.portal.call(demo.reset) >= 1
    assert client.get(f"/rooms/{first}", headers=auth(t)).status_code == 404
    client.portal.call(demo.tick)
    second = client.post("/rooms/join", headers=auth(t)).json()["id"]
    assert demo.is_script_room(second) and second != first

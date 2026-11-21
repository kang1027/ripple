import io
import uuid

from PIL import Image

from app.db import sessionmaker
from app.services.topics import RuleClassifier, process_job, same_topic

from .conftest import auth, onboard

# 망원동 근처 좌표
LAT, LNG = 37.5556, 126.9019


def _uniq(prefix: str) -> str:
    return f"{prefix}{uuid.uuid4().hex[:6]}"


def _phone() -> str:
    return "010" + str(uuid.uuid4().int)[:8]


def test_onboarding_and_profile(client):
    token = onboard(client, _uniq("가"), _phone())
    me = client.get("/me", headers=auth(token)).json()
    assert me["status"] == "active"

    # 프로필 사진: EXIF 제거 + 512px
    buf = io.BytesIO()
    Image.new("RGB", (1200, 800), "gray").save(buf, "JPEG")
    r = client.post(
        "/me/avatar",
        files={"file": ("a.jpg", buf.getvalue(), "image/jpeg")},
        headers=auth(token),
    )
    assert r.status_code == 200, r.text
    assert r.json()["avatar_url"].endswith(".jpg")


def test_phone_rules(client):
    r = client.post("/auth/dev", json={"name": _uniq("p")})
    token = r.json()["access_token"]
    # 온보딩 전에는 위치 API 막힘
    assert client.post("/presence", json={"lat": LAT, "lng": LNG}, headers=auth(token)).status_code == 403
    # 데모 번호는 고정 코드
    assert client.post("/auth/phone/request", json={"phone": "01000000000"}, headers=auth(token)).status_code == 200
    bad = client.post("/auth/phone/verify", json={"phone": "01000000000", "code": "999999"}, headers=auth(token))
    assert bad.json()["detail"] == "otp_wrong_code"
    ok = client.post("/auth/phone/verify", json={"phone": "01000000000", "code": "123456"}, headers=auth(token))
    assert ok.status_code == 200
    # 재요청 쿨다운
    again = client.post("/auth/phone/request", json={"phone": "01000000000"}, headers=auth(token))
    assert again.status_code == 429


def test_nickname_unique(client):
    name = _uniq("닉")
    onboard(client, name, _phone())
    r = client.post("/auth/dev", json={"name": _uniq("x")})
    token = r.json()["access_token"]
    phone = _phone()
    client.post("/auth/phone/request", json={"phone": phone}, headers=auth(token))
    from app.services.sms import ConsoleSender

    code = ConsoleSender.sent[-1][1].split("인증번호 ")[1][:6]
    client.post("/auth/phone/verify", json={"phone": phone, "code": code}, headers=auth(token))
    assert client.patch("/me", json={"nickname": name}, headers=auth(token)).status_code == 409


def test_radar_room_chat_topic(client):
    a = onboard(client, _uniq("에이"), _phone())
    b = onboard(client, _uniq("비"), _phone())
    far = onboard(client, _uniq("먼"), _phone())

    for t, (lat, lng) in ((a, (LAT, LNG)), (b, (LAT + 0.0005, LNG)), (far, (LAT + 0.02, LNG))):
        r = client.post("/presence", json={"lat": lat, "lng": lng, "accuracy": 10}, headers=auth(t))
        assert r.json()["ok"] is True

    # 레이더: a 기준 200m 안에는 b만
    near = client.get("/nearby", headers=auth(a)).json()
    assert near["count"] == 1 and near["radius_m"] == 200

    # 정확도 낮으면 무시
    low = client.post("/presence", json={"lat": LAT, "lng": LNG, "accuracy": 500}, headers=auth(a)).json()
    assert low["ok"] is False and low["reason"] == "low_accuracy"

    # 방 배정: a가 만들고 b는 같은 방, far는 다른 방
    ra = client.post("/rooms/join", headers=auth(a)).json()
    rb = client.post("/rooms/join", headers=auth(b)).json()
    rf = client.post("/rooms/join", headers=auth(far)).json()
    assert ra["id"] == rb["id"] != rf["id"]
    assert rb["member_count"] == 2

    room = ra["id"]
    with client.websocket_connect(f"/ws/rooms/{room}?token={a}") as wa, client.websocket_connect(
        f"/ws/rooms/{room}?token={b}"
    ) as wb:
        wa.send_json({"type": "send", "body": "오늘 군체 보신 분? 010-1234-5678", "client_id": "c1"})
        got_a = wa.receive_json()
        got_b = wb.receive_json()
        assert got_a["type"] == "message" and got_a["message"]["client_id"] == "c1"
        assert "010-1234-5678" not in got_b["message"]["body"]  # 전화번호 마스킹

        wb.send_json({"type": "send", "body": "저요! 군체 결말 뭐죠"})
        wa.receive_json()
        wb.receive_json()

        # 다른 방 사람은 이 방 소켓에 못 붙음
        try:
            with client.websocket_connect(f"/ws/rooms/{room}?token={far}") as wf:
                wf.receive_json()
            raise AssertionError("should be rejected")
        except Exception as e:
            assert "4403" in str(e) or "WebSocketDisconnect" in type(e).__name__

        # 토픽 작업 처리 (워커 대신 직접)
        async def drain():
            from app.redis_client import get_redis
            import json

            r = get_redis()
            outcomes = []
            while True:
                item = await r.lpop("topic_jobs")
                if item is None:
                    break
                async with sessionmaker()() as session:
                    outcomes.append((await process_job(session, json.loads(item), RuleClassifier())).status)
            return outcomes

        outcomes = client.portal.call(drain)
        assert outcomes == ["candidate", "confirmed"]

        card = wa.receive_json()
        assert card["type"] == "message" and card["message"]["type"] == "topic_card"
        assert card["message"]["meta"]["title"] == "군체"
        assert wa.receive_json()["type"] == "topic_created"

    topics = client.get(f"/rooms/{room}/topics", headers=auth(a)).json()
    assert len(topics) == 1 and topics[0]["member_count"] == 2 and topics[0]["is_member"]
    assert topics[0]["category"] == "movie" and topics[0]["image_url"].endswith("/static/topics/movie.jpg")
    assert client.get("/static/topics/movie.jpg").headers["content-type"] == "image/jpeg"
    topic_id = topics[0]["id"]

    with client.websocket_connect(f"/ws/topics/{topic_id}?token={b}") as tb:
        tb.send_json({"type": "send", "body": "엔딩 크레딧 뒤에 쿠키 있어요"})
        assert tb.receive_json()["message"]["topic_id"] == topic_id

    msgs = client.get(f"/topics/{topic_id}/messages", headers=auth(a)).json()
    assert len(msgs) == 1
    room_msgs = client.get(f"/rooms/{room}/messages", headers=auth(a)).json()
    assert [m["type"] for m in room_msgs] == ["text", "text", "topic_card"]

    # 차단하면 상대 메시지가 안 보임
    b_id = room_msgs[1]["sender"]["id"]
    client.post("/blocks", json={"user_id": b_id}, headers=auth(a))
    filtered = client.get(f"/rooms/{room}/messages", headers=auth(a)).json()
    assert all((m["sender"] or {}).get("id") != b_id for m in filtered)

    # 신고
    assert client.post("/reports", json={"message_id": room_msgs[0]["id"], "reason": "test"}, headers=auth(b)).status_code == 200


def test_same_topic():
    assert same_topic("군체", "영화 군체")
    assert same_topic("영화 이야기", "영화 이야기")
    assert not same_topic("군체", "불꽃놀이")


def test_delete_account(client):
    token = onboard(client, _uniq("탈"), _phone())
    assert client.delete("/me", headers=auth(token)).status_code == 200
    assert client.get("/me", headers=auth(token)).status_code == 401


def test_my_chats(client):
    token = onboard(client, _uniq("챗"), _phone())
    empty = client.get("/me/chats", headers=auth(token)).json()
    assert empty == {"room": None, "topics": []}

    client.post("/presence", json={"lat": LAT, "lng": LNG, "accuracy": 10}, headers=auth(token))
    room = client.post("/rooms/join", headers=auth(token)).json()
    chats = client.get("/me/chats", headers=auth(token)).json()
    assert chats["room"]["id"] == room["id"]

    client.post(f"/rooms/{room['id']}/leave", headers=auth(token))
    assert client.get("/me/chats", headers=auth(token)).json()["room"] is None


def test_delete_me(client):
    token = onboard(client, _uniq("탈"), _phone())
    assert client.delete("/me", headers=auth(token)).json() == {"ok": True}
    # 탈퇴한 계정 토큰은 더 못 씀
    assert client.get("/me/chats", headers=auth(token)).status_code in (401, 403)


def test_join_follows_nearby_users_room(client, monkeypatch):
    """먼저 들어간 사람이 방 중심에서 멀어져도, 옆에 잡힌 사람은 그 방으로 합류한다."""
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "radius_m", 10)
    a = onboard(client, _uniq("ja"), _phone())
    b = onboard(client, _uniq("jb"), _phone())
    lat, lng = LAT - 0.09, LNG + 0.09
    step = 40 / 111_320  # 40m 북쪽

    def at(t, la):
        assert client.post("/presence", json={"lat": la, "lng": lng, "accuracy": 5}, headers=auth(t)).json()["ok"]

    at(a, lat)
    ra = client.post("/rooms/join", headers=auth(a)).json()
    at(a, lat + step)  # 방 중심에서 40m, 나가는 기준(300m) 안이라 방에 그대로 있음
    at(b, lat + step)
    rb = client.post("/rooms/join", headers=auth(b)).json()
    assert rb["id"] == ra["id"] and rb["member_count"] == 2

    # a가 다시 눌러도 같은 방
    assert client.post("/rooms/join", headers=auth(a)).json()["id"] == ra["id"]


def test_leave_and_rejoin_same_room(client, monkeypatch):
    """셋이 같은 방 → 한 명이 멀어지면 빠지고 → 돌아와서 누르면 같은 방으로 다시 들어간다."""
    from app.config import get_settings

    s = get_settings()
    monkeypatch.setattr(s, "radius_m", 10)
    monkeypatch.setattr(s, "room_leave_m", 10)
    monkeypatch.setattr(s, "room_leave_grace_s", 0)
    users = [onboard(client, _uniq(f"lv{i}"), _phone()) for i in range(3)]
    lat, lng = LAT + 0.11, LNG - 0.11
    step = 1 / 111_320  # 1m

    def at(t, la):
        r = client.post("/presence", json={"lat": la, "lng": lng, "accuracy": 5}, headers=auth(t))
        assert r.json()["ok"], r.text
        return r.json()

    for i, t in enumerate(users):
        at(t, lat + i * 2 * step)
    rooms = {client.post("/rooms/join", headers=auth(t)).json()["id"] for t in users}
    assert len(rooms) == 1
    room = rooms.pop()
    walker = users[2]

    # 40m 북쪽으로: 처음 보고는 유예 시작, 다음 보고에서 빠짐
    assert at(walker, lat + 40 * step)["left_rooms"] == []
    assert at(walker, lat + 41 * step)["left_rooms"] == [room]
    assert client.get(f"/rooms/{room}", headers=auth(users[0])).json()["member_count"] == 2
    assert client.get(f"/rooms/{room}", headers=auth(walker)).json()["read_only"] is True

    # 빠진 동안 내 채팅 목록에서 방이 사라진다
    assert client.get("/me/chats", headers=auth(walker)).json()["room"] is None

    # 다시 다가오면 버튼 없이 자동으로 같은 방에 다시 들어간다
    assert at(walker, lat + 20 * step)["joined_rooms"] == []
    assert at(walker, lat + 3 * step)["joined_rooms"] == [room]
    assert client.get("/me/chats", headers=auth(walker)).json()["room"]["id"] == room
    back = client.post("/rooms/join", headers=auth(walker)).json()
    assert back["id"] == room and back["member_count"] == 3 and back["read_only"] is False

    # 직접 '나가기'를 누른 방은 다가와도 자동으로 안 들어간다
    client.post(f"/rooms/{room}/leave", headers=auth(walker))
    assert at(walker, lat + 2 * step)["joined_rooms"] == []


def test_dev_login_blocked_in_prod(client, monkeypatch):
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "env", "prod")
    assert client.post("/auth/dev", json={"name": "x"}).status_code == 404


def test_former_member_cannot_read_room(client, monkeypatch):
    from app.config import get_settings

    a = onboard(client, _uniq("ra"), _phone())
    lat = LAT - 0.13
    assert client.post("/presence", json={"lat": lat, "lng": LNG, "accuracy": 5}, headers=auth(a)).json()["ok"]
    room = client.post("/rooms/join", headers=auth(a)).json()["id"]
    assert client.get(f"/rooms/{room}/messages", headers=auth(a)).status_code == 200
    client.post(f"/rooms/{room}/leave", headers=auth(a))
    assert client.get(f"/rooms/{room}/messages", headers=auth(a)).status_code == 403
    assert client.get(f"/rooms/{room}", headers=auth(a)).json()["read_only"] is True

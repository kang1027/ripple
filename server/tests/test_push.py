import asyncio

import pytest

from app.config import get_settings
from app.services import apns, notify

from .conftest import auth, onboard
from .test_flow import LAT, LNG, _phone, _uniq


@pytest.fixture()
def sent(monkeypatch):
    calls: list[dict] = []

    async def fake_send(token, env, payload, collapse_id=None):
        calls.append({"token": token, "env": env, "payload": payload})
        return apns.SendResult(True, env)

    monkeypatch.setattr(apns, "send", fake_send)
    return calls


def _drain(client):
    async def wait():
        while notify._tasks:
            await asyncio.gather(*list(notify._tasks))

    client.portal.call(wait)


def _device(client, token: str, hex_token: str, env: str = "production"):
    r = client.post("/push/devices", json={"token": hex_token, "env": env}, headers=auth(token))
    assert r.status_code == 200, r.text


def _at(client, token: str, lat: float, lng: float, background: bool = False):
    body = {"lat": lat, "lng": lng, "accuracy": 10, "background": background}
    assert client.post("/presence", json=body, headers=auth(token)).json()["ok"]


def test_room_message_push_every_message_except_watchers(client, sent):
    a = onboard(client, _uniq("pa"), _phone())
    b = onboard(client, _uniq("pb"), _phone())
    _device(client, b, "b" * 64)
    _at(client, a, LAT, LNG)
    _at(client, b, LAT + 0.0003, LNG)
    _drain(client)
    sent.clear()
    room = client.post("/rooms/join", headers=auth(a)).json()["id"]
    assert client.post("/rooms/join", headers=auth(b)).json()["id"] == room

    def room_pushes():
        return [c for c in sent if c["payload"].get("type") == "room"]

    with client.websocket_connect(f"/ws/rooms/{room}?token={a}") as wa:
        for text in ("안녕하세요 다들 뭐 해요", "두 번째 메시지예요"):
            wa.send_json({"type": "send", "body": text})
            wa.receive_json()
            _drain(client)
        # 쿨다운 없이 메시지마다, 보낸 사람은 빼고
        assert len(room_pushes()) == 2 and {c["token"] for c in room_pushes()} == {"b" * 64}
        assert room_pushes()[0]["payload"]["room_id"] == room

        # 그 방 화면을 보고 있는 사람은 받지 않는다
        with client.websocket_connect(f"/ws/rooms/{room}?token={b}"):
            sent.clear()
            wa.send_json({"type": "send", "body": "세 번째 메시지예요"})
            wa.receive_json()
            _drain(client)
            assert room_pushes() == []

        # 화면을 나가면(소켓 닫힘) 바로 다시 받는다
        sent.clear()
        wa.send_json({"type": "send", "body": "네 번째 메시지예요"})
        wa.receive_json()
        _drain(client)
        assert len(room_pushes()) == 1


def _nearby(sent, token=None):
    return [c for c in sent if c["payload"].get("type") == "nearby" and (token is None or c["token"] == token)]


def test_nearby_push_per_pair(client, sent, monkeypatch):
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "radius_m", 25)
    monkeypatch.setattr(get_settings(), "room_leave_m", 40)
    a = onboard(client, _uniq("na"), _phone())
    b = onboard(client, _uniq("nb"), _phone())
    c = onboard(client, _uniq("nc"), _phone())
    _device(client, b, "c" * 64)
    lat, lng = LAT + 0.05, LNG + 0.05  # 다른 테스트 사용자와 떨어진 곳
    m = 1 / 111_320

    # B는 앱을 내려 둠
    _at(client, b, lat, lng, background=True)
    _drain(client)
    assert sent == []

    # A가 걸어와 25m 안으로 → B에게 한 번
    _at(client, a, lat + 60 * m, lng)
    _at(client, a, lat + 30 * m, lng)
    _at(client, a, lat + 10 * m, lng)
    _drain(client)
    assert len(_nearby(sent, "c" * 64)) == 1

    # 경계(25~40m)에서 흔들려도 다시 안 보냄
    _at(client, a, lat + 30 * m, lng)
    _at(client, a, lat + 12 * m, lng)
    _drain(client)
    assert len(_nearby(sent, "c" * 64)) == 1

    # 새로운 C가 들어오면 A와 상관없이 바로
    _at(client, c, lat + 70 * m, lng)
    _at(client, c, lat + 35 * m, lng)
    _at(client, c, lat + 8 * m, lng)
    _drain(client)
    assert len(_nearby(sent, "c" * 64)) == 2


def test_nearby_push_on_other_screen_not_on_radar(client, sent):
    a = onboard(client, _uniq("fa"), _phone())
    b = onboard(client, _uniq("fb"), _phone())
    _device(client, b, "d" * 64)
    lat, lng = LAT - 0.05, LNG - 0.05

    def at(t, la, on_radar):
        body = {"lat": la, "lng": lng, "accuracy": 10, "on_radar": on_radar}
        assert client.post("/presence", json=body, headers=auth(t)).json()["ok"]

    # 레이더를 보고 있으면 알림 없음 (화면에 바로 보이니까)
    at(b, lat, True)
    at(a, lat + 0.00005, True)
    _drain(client)
    assert _nearby(sent) == []

    # 다른 화면(채팅 탭 등)에 있을 때 새 사람이 오면 알림
    c = onboard(client, _uniq("fc"), _phone())
    at(b, lat, False)
    at(c, lat - 0.00005, True)
    _drain(client)
    assert len(_nearby(sent, "d" * 64)) == 1


def test_device_moves_to_new_account(client):
    a = onboard(client, _uniq("da"), _phone())
    b = onboard(client, _uniq("db"), _phone())
    _device(client, a, "e" * 64)
    _device(client, b, "E" * 64, env="sandbox")

    async def owner():
        from sqlalchemy import select

        from app.db import sessionmaker
        from app.models import PushDevice

        async with sessionmaker()() as session:
            rows = (await session.execute(select(PushDevice).where(PushDevice.token == "e" * 64))).scalars().all()
            return [(d.user_id, d.env) for d in rows]

    me_b = client.get("/me", headers=auth(b)).json()["id"]
    assert client.portal.call(owner) == [(me_b, "sandbox")]
    assert client.delete(f"/push/devices/{'e' * 64}", headers=auth(a)).status_code == 200
    assert client.portal.call(owner) == [(me_b, "sandbox")]
    client.delete(f"/push/devices/{'e' * 64}", headers=auth(b))
    assert client.portal.call(owner) == []

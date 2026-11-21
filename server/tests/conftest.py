import os
import tempfile

_tmp = tempfile.mkdtemp()
os.environ.update(
    {
        "DATABASE_URL": f"sqlite+aiosqlite:///{_tmp}/test.db",
        "MEDIA_DIR": f"{_tmp}/media",
        "RUN_WORKER_INLINE": "false",
        "ALLOW_DEV_LOGIN": "true",
        "DEMO_PHONE": "010-0000-0000",
        "DEMO_CODE": "123456",
        "JWT_SECRET": "test",
        # .env에 sendon이 켜져 있어도 테스트는 절대 실제 문자를 보내지 않음
        "SMS_PROVIDER": "console",
        # .env가 claude여도 테스트는 실제 API를 부르지 않음
        "TOPIC_CLASSIFIER": "rule",
        "ANTHROPIC_API_KEY": "test-not-a-key",
    }
)

import fakeredis  # noqa: E402
import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.redis_client import set_redis  # noqa: E402


@pytest.fixture()
def client():
    set_redis(fakeredis.FakeAsyncRedis(decode_responses=True))
    from app.main import app

    with TestClient(app) as c:
        yield c


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def onboard(client: TestClient, name: str, phone: str) -> str:
    """dev 로그인 → 번호인증(console SMS) → 닉네임 → active 토큰."""
    from app.services.sms import ConsoleSender

    r = client.post("/auth/dev", json={"name": name})
    assert r.status_code == 200, r.text
    token = r.json()["access_token"]
    assert r.json()["status"] == "pending_phone"

    r = client.post("/auth/phone/request", json={"phone": phone}, headers=auth(token))
    assert r.status_code == 200, r.text
    code = ConsoleSender.sent[-1][1].split("인증번호 ")[1][:6]
    r = client.post("/auth/phone/verify", json={"phone": phone, "code": code}, headers=auth(token))
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "pending_profile"

    r = client.patch("/me", json={"nickname": name}, headers=auth(token))
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "active"
    return token

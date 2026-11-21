"""APNs HTTP/2 클라이언트 (토큰 인증, .p8 키).

TestFlight·App Store 빌드는 production, Xcode에서 바로 깐 Debug 빌드는 sandbox 토큰을 준다.
기기가 알려 준 환경으로 먼저 보내고, BadDeviceToken이면 반대 환경으로 한 번 더 보내 저장값을 고친다.
"""

import logging
import time
from dataclasses import dataclass
from pathlib import Path

import httpx
import jwt

from ..config import get_settings

log = logging.getLogger("ripple.apns")

HOSTS = {
    "production": "https://api.push.apple.com",
    "sandbox": "https://api.sandbox.push.apple.com",
}
# 기기 토큰이 더는 유효하지 않다는 응답
DEAD_REASONS = {"Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"}
JWT_TTL_S = 40 * 60  # 애플은 20~60분 사이 재발급을 권장

_client: httpx.AsyncClient | None = None
_jwt: tuple[str, float] | None = None


@dataclass
class SendResult:
    ok: bool
    env: str
    reason: str | None = None

    @property
    def dead(self) -> bool:
        return not self.ok and self.reason in DEAD_REASONS


def _private_key() -> str | None:
    s = get_settings()
    if s.apns_private_key:
        return s.apns_private_key.replace("\\n", "\n")
    if s.apns_key_path:
        path = Path(s.apns_key_path).expanduser()
        if path.exists():
            return path.read_text()
    return None


def enabled() -> bool:
    s = get_settings()
    return bool(s.apns_key_id and s.apple_team_id and _private_key())


def _token() -> str:
    global _jwt
    now = time.time()
    if _jwt and now - _jwt[1] < JWT_TTL_S:
        return _jwt[0]
    s = get_settings()
    token = jwt.encode(
        {"iss": s.apple_team_id, "iat": int(now)},
        _private_key(),
        algorithm="ES256",
        headers={"kid": s.apns_key_id},
    )
    _jwt = (token, now)
    return token


def _http() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(http2=True, timeout=10)
    return _client


async def _post(env: str, device_token: str, payload: dict, collapse_id: str | None) -> SendResult:
    headers = {
        "authorization": f"bearer {_token()}",
        "apns-topic": get_settings().apple_bundle_id,
        "apns-push-type": "alert",
        "apns-priority": "10",
        # 기기가 꺼져 있으면 하루까지만 보관
        "apns-expiration": str(int(time.time()) + 24 * 3600),
    }
    if collapse_id:
        headers["apns-collapse-id"] = collapse_id[:64]
    try:
        r = await _http().post(f"{HOSTS[env]}/3/device/{device_token}", json=payload, headers=headers)
    except httpx.HTTPError as e:
        return SendResult(False, env, f"network:{type(e).__name__}")
    if r.status_code == 200:
        return SendResult(True, env)
    try:
        reason = r.json().get("reason")
    except ValueError:
        reason = f"http_{r.status_code}"
    if r.status_code == 403 and reason == "ExpiredProviderToken":
        global _jwt
        _jwt = None
    return SendResult(False, env, reason)


async def send(device_token: str, env: str, payload: dict, collapse_id: str | None = None) -> SendResult:
    if not enabled():
        log.info("apns disabled, skip push: %s", payload.get("aps", {}).get("alert"))
        return SendResult(False, env, "disabled")
    env = env if env in HOSTS else "production"
    result = await _post(env, device_token, payload, collapse_id)
    if result.reason == "BadDeviceToken":
        other = "sandbox" if env == "production" else "production"
        retry = await _post(other, device_token, payload, collapse_id)
        if retry.ok or retry.reason != "BadDeviceToken":
            return retry
    if not result.ok:
        log.warning("apns push failed (%s): %s", env, result.reason)
    return result

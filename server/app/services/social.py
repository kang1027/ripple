"""Kakao · Apple 토큰 검증.

앱은 소셜 SDK에서 받은 토큰을 서버로 넘기고, 검증은 전부 여기서 한다.
"""

import time

import httpx
import jwt
from fastapi import HTTPException, status

from ..config import get_settings
from ..security import sha256_hex

KAKAO_TOKEN_INFO = "https://kapi.kakao.com/v1/user/access_token_info"
APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS = "https://appleid.apple.com/auth/keys"
APPLE_TOKEN = "https://appleid.apple.com/auth/token"
APPLE_REVOKE = "https://appleid.apple.com/auth/revoke"

_apple_jwks: jwt.PyJWKClient | None = None


async def verify_kakao(access_token: str) -> str:
    """카카오 액세스 토큰 → 카카오 회원번호. 다른 앱의 토큰이면 거부."""
    async with httpx.AsyncClient(timeout=5) as client:
        r = await client.get(KAKAO_TOKEN_INFO, headers={"Authorization": f"Bearer {access_token}"})
    if r.status_code != 200:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "kakao_token_invalid")
    info = r.json()
    app_id = get_settings().kakao_app_id
    if app_id is not None and info.get("app_id") != app_id:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "kakao_app_mismatch")
    return str(info["id"])


def _jwks() -> jwt.PyJWKClient:
    global _apple_jwks
    if _apple_jwks is None:
        _apple_jwks = jwt.PyJWKClient(APPLE_KEYS, cache_keys=True, lifespan=3600)
    return _apple_jwks


def verify_apple(identity_token: str, raw_nonce: str) -> str:
    """Apple identityToken(JWT) 검증 → Apple 사용자 ID(sub)."""
    s = get_settings()
    try:
        key = _jwks().get_signing_key_from_jwt(identity_token)
        claims = jwt.decode(
            identity_token,
            key.key,
            algorithms=["RS256"],
            audience=s.apple_bundle_id,
            issuer=APPLE_ISSUER,
        )
    except jwt.PyJWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "apple_token_invalid")
    if claims.get("nonce") != sha256_hex(raw_nonce):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "apple_nonce_mismatch")
    return claims["sub"]


def _apple_client_secret() -> str | None:
    s = get_settings()
    if not (s.apple_team_id and s.apple_key_id and s.apple_private_key):
        return None
    now = int(time.time())
    payload = {
        "iss": s.apple_team_id,
        "iat": now,
        "exp": now + 300,
        "aud": APPLE_ISSUER,
        "sub": s.apple_bundle_id,
    }
    key = s.apple_private_key.replace("\\n", "\n")
    return jwt.encode(payload, key, algorithm="ES256", headers={"kid": s.apple_key_id})


async def apple_exchange_code(code: str) -> str | None:
    """최초 로그인 시 authorizationCode → refresh_token (탈퇴 때 해지용)."""
    secret = _apple_client_secret()
    if secret is None:
        return None
    data = {
        "client_id": get_settings().apple_bundle_id,
        "client_secret": secret,
        "code": code,
        "grant_type": "authorization_code",
    }
    async with httpx.AsyncClient(timeout=5) as client:
        r = await client.post(APPLE_TOKEN, data=data)
    if r.status_code != 200:
        return None
    return r.json().get("refresh_token")


async def apple_revoke(refresh_token: str) -> bool:
    secret = _apple_client_secret()
    if secret is None:
        return False
    data = {
        "client_id": get_settings().apple_bundle_id,
        "client_secret": secret,
        "token": refresh_token,
        "token_type_hint": "refresh_token",
    }
    async with httpx.AsyncClient(timeout=5) as client:
        r = await client.post(APPLE_REVOKE, data=data)
    return r.status_code == 200

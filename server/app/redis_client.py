from redis.asyncio import Redis

from .config import get_settings

_redis: Redis | None = None


def set_redis(client: Redis) -> None:
    """테스트에서 fakeredis를 끼워 넣을 때 사용."""
    global _redis
    _redis = client


def get_redis() -> Redis:
    global _redis
    if _redis is None:
        url = get_settings().redis_url
        if url.startswith("fake"):
            # Redis 없이 로컬에서 바로 띄울 때 (REDIS_URL=fake://)
            import fakeredis

            _redis = fakeredis.FakeAsyncRedis(decode_responses=True)
        else:
            _redis = Redis.from_url(url, decode_responses=True)
    return _redis

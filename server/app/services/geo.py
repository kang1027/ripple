import json
import math
import time

import httpx

from ..config import get_settings
from ..redis_client import get_redis

PRESENCE = "presence"
PRESENCE_TS = "presence:ts"
ROOMS_GEO = "rooms:geo"
MAX_SPEED_MPS = 50
KAKAO_REGION = "https://dapi.kakao.com/v2/local/geo/coord2regioncode.json"


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def snap_center(lat: float, lng: float, grid_m: float = 150.0) -> tuple[float, float]:
    """방 중심을 약 150m 격자 중심으로 반올림. 방을 만든 사람의 정확한 위치를 숨긴다."""
    lat_step = grid_m / 111_320
    lng_step = grid_m / (111_320 * max(math.cos(math.radians(lat)), 0.01))
    return (
        (math.floor(lat / lat_step) + 0.5) * lat_step,
        (math.floor(lng / lng_step) + 0.5) * lng_step,
    )


async def last_position(user_id: str) -> dict | None:
    raw = await get_redis().get(f"presence:last:{user_id}")
    if raw is None:
        return None
    pos = json.loads(raw)
    if time.time() - pos["ts"] > get_settings().presence_ttl_s:
        return None
    return pos


async def report_position(user_id: str, lat: float, lng: float) -> tuple[bool, str | None]:
    r = get_redis()
    now = time.time()
    prev_raw = await r.get(f"presence:last:{user_id}")
    if prev_raw:
        prev = json.loads(prev_raw)
        dt = max(now - prev["ts"], 1.0)
        if haversine_m(prev["lat"], prev["lng"], lat, lng) / dt > MAX_SPEED_MPS:
            return False, "implausible_jump"
    await r.set(
        f"presence:last:{user_id}",
        json.dumps({"lat": lat, "lng": lng, "ts": now}),
        ex=get_settings().presence_ttl_s * 2,
    )
    await r.geoadd(PRESENCE, [lng, lat, user_id])
    await r.zadd(PRESENCE_TS, {user_id: now})
    return True, None


async def nearby_user_ids(lat: float, lng: float, radius_m: int) -> list[str]:
    r = get_redis()
    ids = await r.geosearch(PRESENCE, longitude=lng, latitude=lat, radius=radius_m, unit="m")
    if not ids:
        return []
    cutoff = time.time() - get_settings().presence_ttl_s
    fresh = []
    for uid in ids:
        ts = await r.zscore(PRESENCE_TS, uid)
        if ts is not None and ts >= cutoff:
            fresh.append(uid)
    return fresh


def room_grid_m(radius_m: int) -> float:
    """방 중심 격자. 반경보다 크면 좁은 반경(시연용 10m 등)에서 사람마다 방이 따로 생긴다."""
    return min(150.0, float(radius_m))


def room_search_m(radius_m: int) -> float:
    """방 중심이 격자로 반올림돼 최대 격자 반쪽 대각선만큼 어긋나므로 그만큼 넓혀 찾는다."""
    return radius_m + room_grid_m(radius_m) * 0.71


async def nearest_room_id(lat: float, lng: float, radius_m: float) -> list[str]:
    return await get_redis().geosearch(
        ROOMS_GEO, longitude=lng, latitude=lat, radius=radius_m, unit="m", sort="ASC"
    )


async def area_name(lat: float, lng: float) -> str:
    """좌표 → 행정동 이름. 키가 없거나 실패하면 기본 문구."""
    key = get_settings().kakao_rest_api_key
    if not key:
        return "이 근처"
    try:
        async with httpx.AsyncClient(timeout=3) as client:
            r = await client.get(
                KAKAO_REGION,
                params={"x": lng, "y": lat},
                headers={"Authorization": f"KakaoAK {key}"},
            )
        docs = r.json().get("documents", [])
        for d in docs:
            if d.get("region_type") == "H":
                return f"{d.get('region_3depth_name') or d.get('region_2depth_name')} 근처"
    except Exception:
        pass
    return "이 근처"


KAKAO_ADDRESS = "https://dapi.kakao.com/v2/local/geo/coord2address.json"
PLACE_CACHE_S = 30 * 60


async def place_name(lat: float, lng: float) -> str | None:
    """레이더에 보여 줄 지금 위치 이름. 건물 이름이 있으면 건물, 없으면 행정동 이름.
    레이더가 2초마다 부르니 약 11m 격자로 30분 캐시한다. 키가 없거나 실패하면 None."""
    key = get_settings().kakao_rest_api_key
    if not key:
        return None
    r = get_redis()
    cache_key = f"place:{round(lat, 4)}:{round(lng, 4)}"
    cached = await r.get(cache_key)
    if cached is not None:
        return cached or None
    name = ""
    try:
        async with httpx.AsyncClient(timeout=3) as client:
            headers = {"Authorization": f"KakaoAK {key}"}
            res = await client.get(KAKAO_ADDRESS, params={"x": lng, "y": lat}, headers=headers)
            for d in res.json().get("documents", []):
                building = ((d.get("road_address") or {}).get("building_name") or "").strip()
                if building:
                    name = building
                    break
            if not name:
                res = await client.get(KAKAO_REGION, params={"x": lng, "y": lat}, headers=headers)
                for d in res.json().get("documents", []):
                    if d.get("region_type") == "H":
                        name = d.get("region_3depth_name") or d.get("region_2depth_name") or ""
                        break
    except Exception:
        return None
    await r.set(cache_key, name, ex=PLACE_CACHE_S)
    return name or None

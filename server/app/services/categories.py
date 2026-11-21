"""토픽 카테고리와 카테고리별 기본 이미지."""

from ..config import get_settings

# 토픽 분류 체계. 키는 DB(String(16))와 iOS TopicCategory, 이미지 파일 이름(app/static/topics/<키>.jpg)에 같이 쓴다
CATEGORIES: dict[str, tuple[str, str]] = {
    "movie": ("영화", "영화·드라마·OTT 작품, 극장, 상영"),
    "show": ("공연", "콘서트, 뮤지컬, 연극, 버스킹, 팬미팅"),
    "event": ("축제·행사", "축제, 불꽃놀이, 플리마켓, 지역 행사, 마라톤 같은 이벤트"),
    "exhibition": ("전시", "전시회, 미술관, 박물관, 사진전"),
    "shopping": ("쇼핑·팝업", "팝업스토어, 세일, 굿즈, 오픈런, 매장"),
    "food": ("맛집", "식당, 음식, 웨이팅 맛집, 배달, 디저트 가게"),
    "cafe": ("카페", "카페, 커피, 베이커리, 자리 찾기"),
    "place": ("장소", "공원, 한강, 명소, 줄 선 곳, 길, 역 등 특정 장소"),
    "sports": ("스포츠", "경기 관람, 응원, 러닝, 운동, 헬스"),
    "nature": ("날씨·풍경", "날씨, 노을, 벚꽃·단풍, 비·눈, 하늘"),
    "news": ("동네 소식", "사고, 공사, 정전, 교통 통제, 분실물, 새로 생긴 가게"),
    "pet": ("반려동물", "강아지, 고양이, 산책하는 동물"),
    "game": ("게임", "게임, e스포츠, 보드게임, 오락실"),
    "etc": ("이야기", "위 어디에도 안 맞는 구체적인 주제"),
}
CATEGORY_LABEL = {k: v[0] for k, v in CATEGORIES.items()}


def category_image_url(category: str) -> str:
    key = category if category in CATEGORIES else "etc"
    return f"{get_settings().public_base_url}/static/topics/{key}.jpg"

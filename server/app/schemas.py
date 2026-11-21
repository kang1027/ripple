from datetime import datetime

from pydantic import BaseModel, Field


class TokenOut(BaseModel):
    access_token: str
    refresh_token: str
    status: str
    is_new: bool = False


class KakaoLoginIn(BaseModel):
    access_token: str


class AppleLoginIn(BaseModel):
    identity_token: str
    raw_nonce: str = Field(min_length=16, max_length=128)  # 앱이 만든 원본 nonce. 토큰의 nonce는 이 값의 sha256
    authorization_code: str | None = None


class DevLoginIn(BaseModel):
    name: str = Field(min_length=1, max_length=32)


class RefreshIn(BaseModel):
    refresh_token: str


class PhoneRequestIn(BaseModel):
    phone: str


class PhoneVerifyIn(BaseModel):
    phone: str
    code: str


class UserOut(BaseModel):
    id: str
    nickname: str | None
    avatar_url: str | None
    status: str
    avatar: dict | None = None  # 캐릭터 꾸미기 값 (snake_case 키)


# iOS DesignSystem/Avatar.swift의 Options와 같은 선택지
AVATAR_OPTIONS: dict[str, tuple[str, ...]] = {
    "hair": ("short", "bob", "curly", "bun", "none"),
    "hair_color": ("ink", "cocoa", "gold", "blue", "rose"),
    "skin": ("porcelain", "peach", "warm", "tan", "deep", "espresso"),
    "eyewear": ("none", "snorkel", "sun", "round", "square"),
    "eyes": ("dot", "oval", "happy", "sleepy"),
    "nose": ("button", "round", "triangle"),
    "mouth": ("smile", "grin", "small", "surprised"),
    "body": ("round", "slim", "broad"),
    "outfit": ("rashguard", "onepiece", "shorts"),
    "clothes": ("blue", "mint", "lemon", "rose", "ink"),
    "float": ("none", "ring", "flamingo", "dolphin"),
    "float_color": (
        "blue", "mint", "lemon", "rose", "coral", "lilac", "aqua", "tangerine", "cherry", "lime", "lavender", "ice",
    ),
    "prop": ("none", "cocktail", "juice", "watergun"),
}


def valid_avatar(value: dict) -> bool:
    return set(value) == set(AVATAR_OPTIONS) and all(value[k] in opts for k, opts in AVATAR_OPTIONS.items())


class ProfilePatchIn(BaseModel):
    nickname: str | None = None
    avatar: dict | None = None


class PresenceIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    accuracy: float = Field(default=10, ge=0)
    # 앱이 백그라운드에서 보낸 위치. 근처 사람 알림에만 쓰인다
    background: bool = False
    # 지금 레이더 화면을 보고 있는지. 아니면 근처 사람 알림을 보낸다 (예전 앱은 안 보내서 기본 True)
    on_radar: bool = True


class PresenceOut(BaseModel):
    ok: bool
    reason: str | None = None
    # 이번 위치로 범위를 벗어나 빠진 방. 앱은 그 방 화면을 닫는다
    left_rooms: list[str] = []
    # 거리로 빠졌던 방에 다시 다가와 자동으로 다시 들어간 방
    joined_rooms: list[str] = []


class NearbyOut(BaseModel):
    count: int
    avatars: list[str | None]
    radius_m: int
    characters: list[dict | None] = []  # avatars와 같은 순서의 캐릭터 값
    area_name: str | None = None  # 지금 위치 이름. 건물 이름이 있으면 건물, 없으면 동네


class MemberBrief(BaseModel):
    id: str
    nickname: str | None
    avatar_url: str | None
    avatar: dict | None = None


class ReplyRef(BaseModel):
    id: int
    sender_id: str | None
    nickname: str | None
    body: str  # 앞 80자


class RoomOut(BaseModel):
    id: str
    area_name: str
    member_count: int
    avatars: list[str | None]
    is_member: bool
    read_only: bool = False


class MessageOut(BaseModel):
    id: int
    room_id: str
    topic_id: str | None
    type: str
    body: str
    meta: dict | None
    sender: MemberBrief | None
    created_at: datetime
    client_id: str | None = None
    reply: ReplyRef | None = None


class TopicOut(BaseModel):
    id: str
    room_id: str
    title: str
    summary: str
    category: str
    image_url: str | None
    member_count: int
    last_message_at: datetime
    is_member: bool = False
    place_name: str | None = None  # 토픽이 생긴 동네방 이름
    created_at: datetime | None = None
    muted: bool = False  # 나 기준 알림 끄기


class TopicPatchIn(BaseModel):
    muted: bool


class ChatsOut(BaseModel):
    """채팅 탭: 지금 들어가 있는 방 + 참여한 토픽"""

    room: RoomOut | None
    topics: list[TopicOut]


class ReportIn(BaseModel):
    message_id: int
    reason: str = Field(default="", max_length=200)


class BlockIn(BaseModel):
    user_id: str


class PushDeviceIn(BaseModel):
    token: str = Field(min_length=32, max_length=200, pattern=r"^[0-9a-fA-F]+$")
    env: str = Field(default="production", pattern=r"^(sandbox|production)$")

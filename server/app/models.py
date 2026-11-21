import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base


def now() -> datetime:
    return datetime.now(timezone.utc)


def new_id() -> str:
    return uuid.uuid4().hex


class UserStatus:
    PENDING_PHONE = "pending_phone"
    PENDING_PROFILE = "pending_profile"
    ACTIVE = "active"
    DELETED = "deleted"


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    nickname: Mapped[str | None] = mapped_column(String(24), unique=True)
    avatar_url: Mapped[str | None] = mapped_column(String(512))
    phone_hmac: Mapped[str | None] = mapped_column(String(64), unique=True)
    # 캐릭터 꾸미기 값 (iOS Avatar, snake_case 키). 없으면 앱이 id로 정한 기본 캐릭터
    avatar: Mapped[dict | None] = mapped_column(JSON)
    status: Mapped[str] = mapped_column(String(24), default=UserStatus.PENDING_PHONE)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AuthIdentity(Base):
    __tablename__ = "auth_identities"
    __table_args__ = (UniqueConstraint("provider", "provider_uid"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    provider: Mapped[str] = mapped_column(String(16))  # kakao | apple | dev
    provider_uid: Mapped[str] = mapped_column(String(128))
    apple_refresh_token: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class PushDevice(Base):
    __tablename__ = "push_devices"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token: Mapped[str] = mapped_column(String(200), unique=True)
    env: Mapped[str] = mapped_column(String(16), default="production")  # sandbox | production
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Room(Base):
    __tablename__ = "rooms"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    center_lat: Mapped[float] = mapped_column(Float)
    center_lng: Mapped[float] = mapped_column(Float)
    area_name: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class RoomMember(Base):
    __tablename__ = "room_members"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    room_id: Mapped[str] = mapped_column(ForeignKey("rooms.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    left_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Topic(Base):
    __tablename__ = "topics"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    room_id: Mapped[str] = mapped_column(ForeignKey("rooms.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(64))
    summary: Mapped[str] = mapped_column(String(200), default="")
    category: Mapped[str] = mapped_column(String(16), default="etc")
    image_url: Mapped[str | None] = mapped_column(String(512))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    last_message_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class TopicMember(Base):
    __tablename__ = "topic_members"
    __table_args__ = (UniqueConstraint("topic_id", "user_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    topic_id: Mapped[str] = mapped_column(ForeignKey("topics.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    # 이 토픽 알림 끄기 (나 기준)
    muted: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")


class MessageType:
    TEXT = "text"
    SYSTEM = "system"
    TOPIC_CARD = "topic_card"


class Message(Base):
    __tablename__ = "messages"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    room_id: Mapped[str] = mapped_column(ForeignKey("rooms.id", ondelete="CASCADE"), index=True)
    topic_id: Mapped[str | None] = mapped_column(
        ForeignKey("topics.id", ondelete="CASCADE"), index=True
    )
    user_id: Mapped[str | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    type: Mapped[str] = mapped_column(String(16), default=MessageType.TEXT)
    body: Mapped[str] = mapped_column(Text, default="")
    meta: Mapped[dict | None] = mapped_column(JSON)
    # 답장: 원본 메시지와, 원본이 지워져도 보이도록 그때의 요약 {id, sender_id, nickname, body}
    reply_to_id: Mapped[int | None] = mapped_column(ForeignKey("messages.id", ondelete="SET NULL"))
    reply_snapshot: Mapped[dict | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, index=True)


class Report(Base):
    __tablename__ = "reports"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    reporter_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id", ondelete="CASCADE"))
    reason: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Block(Base):
    __tablename__ = "blocks"
    __table_args__ = (UniqueConstraint("user_id", "blocked_user_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    blocked_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)

"""간단한 안전 필터: 개인정보 마스킹 + 금칙어."""

import re

PHONE_RE = re.compile(r"01[016789][-\s.]?\d{3,4}[-\s.]?\d{4}")
ACCOUNT_RE = re.compile(r"\d{2,6}-\d{2,6}-\d{2,8}")
EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")

# 실제 운영 시 목록을 파일로 분리
BANNED_WORDS = {"시발", "씨발", "병신", "좆", "개새끼"}
BANNED_NICK = BANNED_WORDS | {"관리자", "운영자", "admin", "ripple"}


def mask_pii(text: str) -> str:
    text = PHONE_RE.sub("***-****-****", text)
    text = ACCOUNT_RE.sub("***", text)
    return EMAIL_RE.sub("***@***", text)


def mask_banned(text: str) -> str:
    for w in BANNED_WORDS:
        text = text.replace(w, "*" * len(w))
    return text


def clean_message(text: str) -> str:
    return mask_banned(mask_pii(text.strip()))[:1000]


def nickname_ok(nick: str) -> bool:
    lowered = nick.lower()
    return not any(w in lowered for w in BANNED_NICK)

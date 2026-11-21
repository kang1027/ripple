"""문자 발송. 개발 중에는 console, 실제 발송은 센드온(sendon).

센드온 v2 SMS API(POST /v2/messages/sms, Basic 인증)를 쓴다.
Basic 인증(아이디:API 키) + POST /v2/messages/sms, 응답 본문 code가 200이고 data.groupId가 있어야 성공.
센드온 콘솔의 허용 IP에 이 서버의 공인 IP가 등록돼 있어야 한다.
"""

import logging
import re
from typing import Protocol

import httpx

from ..config import get_settings

log = logging.getLogger("ripple.sms")

SMS_MAX_BYTES = 90
LMS_TITLE_MAX = 30


class SmsSender(Protocol):
    async def send(self, to: str, text: str) -> None: ...


class ConsoleSender:
    sent: list[tuple[str, str]] = []

    async def send(self, to: str, text: str) -> None:
        self.sent.append((to, text))
        log.warning("[SMS:console] to=%s text=%s", to, text)


def sms_bytes(text: str) -> int:
    return sum(1 if ord(ch) <= 0x7F else 2 for ch in text)


def mask_phone(phone: str) -> str:
    return phone[:3] + "****" + phone[-4:] if len(phone) >= 8 else "****"


class SendonSender:
    async def send(self, to: str, text: str) -> None:
        s = get_settings()
        sender = re.sub(r"\D", "", s.sendon_sender or "")
        if not (s.sendon_user_id and s.sendon_api_key and sender):
            raise RuntimeError("sendon credentials missing")

        long = sms_bytes(text) > SMS_MAX_BYTES
        body: dict = {
            "type": "LMS" if long else "SMS",
            "from": sender,
            "to": [to],
            "message": text,
            "isAd": False,
            "useCredit": True,
        }
        if long:
            body["title"] = text.split("\n")[0][:LMS_TITLE_MAX]

        async with httpx.AsyncClient(
            base_url=s.sendon_base_url.rstrip("/"), timeout=10, proxy=s.sendon_proxy
        ) as client:
            r = await client.post(
                "/v2/messages/sms",
                json=body,
                auth=(s.sendon_user_id, s.sendon_api_key),
                headers={"Accept": "application/json"},
            )
        try:
            out = r.json()
        except ValueError:
            out = {}
        code = out.get("code", r.status_code)
        group_id = (out.get("data") or {}).get("groupId")
        if code != 200 or not group_id:
            log.error("sendon failed: to=%s code=%s message=%s", mask_phone(to), code, out.get("message"))
            raise RuntimeError("sms_send_failed")
        log.info("sendon sent: to=%s group=%s", mask_phone(to), group_id)


_console = ConsoleSender()


def get_sender() -> SmsSender:
    return SendonSender() if get_settings().sms_provider == "sendon" else _console

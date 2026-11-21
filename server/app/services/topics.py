"""AI 토픽 봇.

1) 분류기(TopicClassifier)가 메시지마다 주제를 뽑는다 (규칙 기반, Claude API, OpenAI 호환 LLM).
2) A가 꺼낸 주제(후보)에 A가 아닌 사람이 10분 안에 같은 주제로 말하면 토픽 확정.
3) 확정되면 토픽 방을 만들고 부모 방에 토픽 카드를 보낸다.
"""

import json
import logging
import re
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal, Protocol

import anthropic
import httpx
from anthropic import AsyncAnthropic
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..models import Message, MessageType, Room, Topic, TopicMember, User
from ..redis_client import get_redis
from . import notify
from .categories import CATEGORIES, CATEGORY_LABEL
from .chat import post_message, publish, room_channel, topic_out

log = logging.getLogger("ripple.topics")

@dataclass
class TopicResult:
    has_topic: bool
    category: str = "etc"
    title: str = ""
    summary: str = ""


class TopicClassifier(Protocol):
    async def classify(self, message: str, recent: list[str], known_titles: list[str]) -> TopicResult: ...


# ---------- 규칙 기반 (기본값, 모델 없이 전체 흐름을 돌리기 위함) ----------

SEED_PATH = Path(__file__).resolve().parent.parent / "topics_seed.json"


def _load_seed() -> dict:
    try:
        return json.loads(SEED_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"entities": {}, "keywords": {}}


class RuleClassifier:
    def __init__(self, seed: dict | None = None) -> None:
        seed = seed or _load_seed()
        self.entities: dict[str, str] = seed.get("entities", {})
        self.keywords: dict[str, list[str]] = seed.get("keywords", {})

    async def classify(self, message: str, recent: list[str], known_titles: list[str]) -> TopicResult:
        text = message.lower()
        for name, cat in sorted(self.entities.items(), key=lambda kv: -len(kv[0])):
            if name.lower() in text:
                label = CATEGORY_LABEL.get(cat, "")
                return TopicResult(True, cat, name, f"{name} {label} 이야기를 나누는 방".strip())
        for cat, words in self.keywords.items():
            if any(w.lower() in text for w in words):
                label = CATEGORY_LABEL.get(cat, "이야기")
                return TopicResult(True, cat, f"{label} 이야기", f"근처에서 {label} 얘기를 나누는 방")
        return TopicResult(False)


# ---------- Claude API ----------

_CATEGORY_GUIDE = "\n".join(f"- {k}: {label} ({desc})" for k, (label, desc) in CATEGORIES.items())

CLAUDE_SYSTEM = f"""너는 위치 기반 동네 단톡방(반경 200m 안 사람들)에 붙은 토픽 봇이다.
새 메시지가 '근처 사람들이 같이 이야기할 만한 구체적인 주제'를 꺼내는지 판단한다.

has_topic=true: 영화, 공연, 축제, 팝업, 맛집, 특정 장소, 경기, 동네 소식처럼 구체적인 대상이 있는 말.
has_topic=false: 인사, 맞장구, 감탄, 대상 없는 질문("뭐 하세요?"), 개인 신상, 욕설·광고.
앞 대화를 받는 짧은 말("저도요! 거기 줄 길어요?")은 앞 대화의 주제를 이어받은 것으로 본다.

known_topics에 같은 대상을 말하는 제목이 있으면 title을 그 제목과 글자 하나 다르지 않게 똑같이 써라.
없으면 새 제목을 만든다: 고유명사가 있으면 고유명사 그대로(예: "왕과 사는 남자", "성수 디올 팝업"), 없으면 짧은 명사구(예: "한강 불꽃놀이").
title은 12자 이내, summary는 이 토픽방을 소개하는 30자 이내 한 줄(해요체). 둘 다 따옴표·괄호·마크다운 없는 평문.

category는 아래 중 하나:
{_CATEGORY_GUIDE}"""


class _ClaudeTopic(BaseModel):
    has_topic: bool
    category: Literal[tuple(CATEGORIES)]  # type: ignore[valid-type]
    title: str
    summary: str


def _clean(text: str) -> str:
    """모델이 가끔 붙이는 따옴표·마크다운 꼬리와 HTML 태그(</br> 등)를 떼어 낸다."""
    text = re.sub(r"<[^>]*>", " ", text)
    text = re.sub(r"\]\([^)]*\)", "", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip().strip("\"'“”‘’`[]()*").strip()


class ClaudeClassifier:
    def __init__(self, fallback: TopicClassifier | None = None) -> None:
        self.fallback = fallback or RuleClassifier()
        s = get_settings()
        self.model = s.claude_model
        # 재시도하면 워커가 그만큼 더 멈춘다. 실패하면 규칙 분류로 넘어간다
        self.client = AsyncAnthropic(api_key=s.anthropic_api_key, timeout=s.claude_timeout_s, max_retries=1)

    async def classify(self, message: str, recent: list[str], known_titles: list[str]) -> TopicResult:
        user = json.dumps(
            {"recent_messages": recent[-10:], "known_topics": known_titles, "message": message},
            ensure_ascii=False,
        )
        started = time.monotonic()
        try:
            resp = await self.client.messages.parse(
                model=self.model,
                max_tokens=1024,
                system=CLAUDE_SYSTEM,
                messages=[{"role": "user", "content": user}],
                output_config={"effort": "low"},
                output_format=_ClaudeTopic,
            )
        except anthropic.APIError as e:
            log.warning("claude classify failed, fallback to rules: %s", e)
            return await self.fallback.classify(message, recent, known_titles)
        except Exception:  # 응답 파싱 실패 등. 분류가 안 돼도 채팅은 계속
            log.exception("claude classify error, fallback to rules")
            return await self.fallback.classify(message, recent, known_titles)
        data = resp.parsed_output
        if resp.stop_reason != "end_turn" or data is None:
            log.warning("claude classify stop=%s, fallback to rules", resp.stop_reason)
            return await self.fallback.classify(message, recent, known_titles)
        log.info(
            "claude classify %.2fs in=%d out=%d -> %s %s",
            time.monotonic() - started,
            resp.usage.input_tokens,
            resp.usage.output_tokens,
            data.category if data.has_topic else "-",
            data.title if data.has_topic else "",
        )
        return TopicResult(data.has_topic, data.category, _clean(data.title)[:24], _clean(data.summary)[:60])


# ---------- LLM (OpenAI 호환: Ollama, vLLM) ----------

SYSTEM_PROMPT = """너는 근처 사람들의 단톡방에서 '같이 이야기할 만한 구체적인 주제'를 찾는 분류기다.
주제는 사람들이 같은 장소에서 함께 경험한 것: 영화, 공연·축제·전시 같은 행사, 쇼핑·팝업, 특정 장소(카페, 줄, 공원) 등.
인사, 잡담, 질문만 있는 메시지는 has_topic=false.
known_topics와 같은 주제면 title을 그 제목과 똑같이 써라.
반드시 JSON 한 개만 출력: {"has_topic": bool, "category": "%s", "title": "12자 이내 명사구", "summary": "30자 이내 한 줄 설명"}""" % "|".join(
    CATEGORIES
)


class LLMClassifier:
    def __init__(self, fallback: TopicClassifier | None = None) -> None:
        self.fallback = fallback or RuleClassifier()

    async def classify(self, message: str, recent: list[str], known_titles: list[str]) -> TopicResult:
        s = get_settings()
        user = json.dumps(
            {"recent_messages": recent[-10:], "known_topics": known_titles, "message": message},
            ensure_ascii=False,
        )
        try:
            async with httpx.AsyncClient(base_url=s.llm_base_url, timeout=20) as client:
                r = await client.post(
                    "/chat/completions",
                    headers={"Authorization": f"Bearer {s.llm_api_key}"},
                    json={
                        "model": s.llm_model,
                        "temperature": 0,
                        "response_format": {"type": "json_object"},
                        "messages": [
                            {"role": "system", "content": SYSTEM_PROMPT},
                            {"role": "user", "content": user},
                        ],
                    },
                )
            r.raise_for_status()
            content = r.json()["choices"][0]["message"]["content"]
            data = json.loads(content)
            cat = data.get("category") if data.get("category") in CATEGORIES else "etc"
            return TopicResult(
                bool(data.get("has_topic")),
                cat,
                _clean(str(data.get("title", "")))[:24],
                _clean(str(data.get("summary", "")))[:60],
            )
        except Exception as e:  # 모델이 죽어도 채팅은 계속
            log.warning("llm classify failed, fallback to rules: %s", e)
            return await self.fallback.classify(message, recent, known_titles)


_classifier: TopicClassifier | None = None


def get_classifier() -> TopicClassifier:
    global _classifier
    if _classifier is None:
        kind = get_settings().topic_classifier
        if kind == "claude" and get_settings().anthropic_api_key:
            _classifier = ClaudeClassifier()
        elif kind == "llm":
            _classifier = LLMClassifier()
        else:
            _classifier = RuleClassifier()
    return _classifier


# ---------- 같은 주제 판단 ----------


def _norm(s: str) -> str:
    return re.sub(r"[^0-9a-z가-힣]", "", s.lower())


def _bigrams(s: str) -> set[str]:
    return {s[i : i + 2] for i in range(len(s) - 1)} or {s}


def same_topic(a: str, b: str) -> bool:
    na, nb = _norm(a), _norm(b)
    if not na or not nb:
        return False
    if na == nb or (min(len(na), len(nb)) >= 2 and (na in nb or nb in na)):
        return True
    ba, bb = _bigrams(na), _bigrams(nb)
    return len(ba & bb) / len(ba | bb) >= 0.5


def _meaningful(text: str) -> bool:
    letters = re.findall(r"[0-9A-Za-z가-힣]", text)
    return len(letters) >= 4


# ---------- 처리 ----------


async def _post_card(session: AsyncSession, topic: Topic, reminder: bool) -> None:
    out = await topic_out(session, topic)
    meta = out.model_dump(mode="json") | {"topic_id": topic.id, "reminder": reminder}
    body = f"진행 중인 토픽: {topic.title}" if reminder else f"새 토픽: {topic.title}"
    await post_message(session, room_id=topic.room_id, user=None, body=body, type=MessageType.TOPIC_CARD, meta=meta)
    if not reminder:
        await publish(room_channel(topic.room_id), {"type": "topic_created", "topic": out.model_dump(mode="json")})


@dataclass
class JobOutcome:
    """status는 테스트·로그용: skip | none | reminder | candidate | confirmed. title은 분류된 주제."""

    status: str
    title: str = ""


async def process_job(session: AsyncSession, job: dict, classifier: TopicClassifier | None = None) -> JobOutcome:
    s = get_settings()
    if not _meaningful(job["body"]):
        return JobOutcome("skip")
    room = await session.get(Room, job["room_id"])
    if room is None or room.closed_at is not None:
        return JobOutcome("skip")

    recent_rows = (
        await session.execute(
            select(Message.body)
            .where(Message.room_id == room.id, Message.topic_id.is_(None), Message.type == MessageType.TEXT)
            .order_by(Message.id.desc())
            .limit(10)
        )
    ).scalars().all()
    since = datetime.now(timezone.utc) - timedelta(hours=24)
    topics = (
        await session.execute(select(Topic).where(Topic.room_id == room.id, Topic.created_at >= since))
    ).scalars().all()

    r = get_redis()
    key = f"topic_cand:{room.id}"
    now = time.time()
    cands: dict[str, dict] = {}
    for cid, raw in (await r.hgetall(key)).items():
        cand = json.loads(raw)
        if now - cand["ts"] > s.topic_candidate_ttl_s:
            await r.hdel(key, cid)
        else:
            cands[cid] = cand

    # 진행 중인 토픽과 후보 제목을 같이 넘겨서, 같은 대상이면 분류기가 제목을 그대로 쓰게 한다
    known = [t.title for t in topics] + [c["title"] for c in cands.values()]
    classifier = classifier or get_classifier()
    result = await classifier.classify(job["body"], list(reversed(recent_rows)), list(dict.fromkeys(known)))
    if not result.has_topic or not result.title:
        return JobOutcome("none")

    for t in topics:
        if same_topic(t.title, result.title):
            if await r.set(f"topic_remind:{t.id}", "1", ex=s.topic_reminder_s, nx=True):
                await _post_card(session, t, reminder=True)
                return JobOutcome("reminder", t.title)
            return JobOutcome("none", t.title)

    for cid, cand in cands.items():
        if not same_topic(cand["title"], result.title):
            continue
        if cand["user_id"] == job["user_id"]:
            cand["ts"] = now
            await r.hset(key, cid, json.dumps(cand, ensure_ascii=False))
            return JobOutcome("candidate", cand["title"])
        # 다른 사람이 같은 주제로 반응 → 확정
        await r.hdel(key, cid)
        topic = Topic(
            room_id=room.id,
            title=cand["title"],
            summary=cand["summary"] or result.summary,
            category=cand["category"],
        )
        session.add(topic)
        await session.flush()
        for uid in {cand["user_id"], job["user_id"]}:
            if await session.get(User, uid):
                session.add(TopicMember(topic_id=topic.id, user_id=uid))
        await session.commit()
        # 확정 직후 이어지는 대화가 곧바로 리마인드 카드를 띄우지 않게 한다
        await r.set(f"topic_remind:{topic.id}", "1", ex=s.topic_reminder_s)
        await _post_card(session, topic, reminder=False)
        notify.spawn(notify.on_topic_created(topic.id))
        return JobOutcome("confirmed", topic.title)

    cand = asdict(result) | {"user_id": job["user_id"], "ts": now}
    await r.hset(key, str(job["message_id"]), json.dumps(cand, ensure_ascii=False))
    await r.expire(key, s.topic_candidate_ttl_s)
    return JobOutcome("candidate", result.title)

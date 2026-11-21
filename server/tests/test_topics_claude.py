"""ClaudeClassifier: 실제 API는 부르지 않고 SDK 응답 모양만 흉내 낸다."""

import asyncio
from types import SimpleNamespace

import anthropic
import httpx

from app.services.categories import CATEGORIES
from app.services.topics import ClaudeClassifier, _clean, _ClaudeTopic


def _resp(parsed, stop="end_turn"):
    return SimpleNamespace(
        parsed_output=parsed, stop_reason=stop, usage=SimpleNamespace(input_tokens=10, output_tokens=5)
    )


def _classifier(monkeypatch, fake):
    c = ClaudeClassifier()
    monkeypatch.setattr(c.client.messages, "parse", fake)
    return c


def test_claude_passes_known_titles_and_parses(monkeypatch):
    seen = {}

    async def fake(**kw):
        seen.update(kw)
        return _resp(_ClaudeTopic(has_topic=True, category="shopping", title="성수 디올 팝업", summary="팝업 얘기해요"))

    c = _classifier(monkeypatch, fake)
    r = asyncio.run(c.classify("거기 줄 길어요?", ["성수 디올 팝업 가보신 분"], ["성수 디올 팝업"]))
    assert (r.has_topic, r.category, r.title) == (True, "shopping", "성수 디올 팝업")
    assert seen["model"] == "claude-haiku-5-5"
    assert "성수 디올 팝업" in seen["messages"][0]["content"]
    assert "temperature" not in seen


def test_claude_falls_back_to_rules(monkeypatch):
    async def down(**kw):
        raise anthropic.APIConnectionError(request=httpx.Request("POST", "https://api.anthropic.com"))

    c = _classifier(monkeypatch, down)
    r = asyncio.run(c.classify("오늘 불꽃놀이 보러 갈 사람?", [], []))
    assert r.has_topic and r.title == "불꽃놀이"

    async def refused(**kw):
        return _resp(None, stop="refusal")

    c = _classifier(monkeypatch, refused)
    assert not asyncio.run(c.classify("안녕하세요", [], [])).has_topic


def test_category_images_exist():
    from pathlib import Path

    folder = Path(__file__).resolve().parent.parent / "app" / "static" / "topics"
    assert all((folder / f"{k}.jpg").exists() for k in CATEGORIES)


def test_clean_strips_html_tags():
    assert _clean("같이 치킨을 시킬 사람을 모으는 이야기방이에요.</br>") == "같이 치킨을 시킬 사람을 모으는 이야기방이에요."
    assert _clean("한강<br/>불꽃놀이") == "한강 불꽃놀이"
    assert _clean('"성수 디올 팝업"') == "성수 디올 팝업"

import asyncio
import logging
import re
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from . import worker
from .config import get_settings
from .db import create_all
from .routers import auth, chat, geo, push, safety, users, ws

logging.basicConfig(level=logging.INFO)


class _RedactToken(logging.Filter):
    """웹소켓은 ?token= 으로 인증해서 접근 로그에 액세스 토큰이 그대로 남는다."""

    _pattern = re.compile(r"(token=)[^&\s\"]+")

    def filter(self, record: logging.LogRecord) -> bool:
        if record.args:
            record.args = tuple(self._pattern.sub(r"\1***", a) if isinstance(a, str) else a for a in record.args)
        if isinstance(record.msg, str):
            record.msg = self._pattern.sub(r"\1***", record.msg)
        return True


for _name in ("uvicorn.access", "uvicorn.error"):
    logging.getLogger(_name).addFilter(_RedactToken())


@asynccontextmanager
async def lifespan(app: FastAPI):
    await create_all()
    stop = asyncio.Event()
    task = None
    if get_settings().run_worker_inline:
        task = asyncio.create_task(worker.run(stop))
    yield
    stop.set()
    if task:
        task.cancel()


def create_app() -> FastAPI:
    s = get_settings()
    app = FastAPI(title="Ripple API", version="0.1.0", lifespan=lifespan)
    for r in (auth.router, users.router, geo.router, chat.router, safety.router, push.router, ws.router):
        app.include_router(r)
    media = Path(s.media_dir)
    media.mkdir(parents=True, exist_ok=True)
    app.mount("/media", StaticFiles(directory=media), name="media")
    # 이미지에 같이 들어가는 고정 이미지(토픽 카테고리 등). media는 운영에서 PVC라 이미지 안 파일을 가리므로 따로 둔다
    app.mount("/static", StaticFiles(directory=Path(__file__).resolve().parent / "static"), name="static")

    @app.get("/health")
    async def health():
        return {"ok": True}

    return app


app = create_app()
